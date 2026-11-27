import Foundation

public enum DirectHTTPDialect: String, Codable, Sendable {
    case openAICompatible
    case anthropic
}

public struct DirectHTTPProvider: LLMProvider, Sendable {
    public let kind: LLMBackendKind = .directHTTP
    public let dialect: DirectHTTPDialect
    public let endpointURL: URL
    public let defaultModel: String
    private let apiKeyProvider: @Sendable () -> String?
    private let session: URLSession

    public init(
        dialect: DirectHTTPDialect = .openAICompatible,
        endpointURL: URL? = nil,
        defaultModel: String = "gpt-4o-mini",
        apiKeyProvider: @escaping @Sendable () -> String? = {
            ProcessInfo.processInfo.environment["HELM_LLM_API_KEY"]
                ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
                ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        },
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.dialect = dialect
        if let endpointURL {
            self.endpointURL = endpointURL
        } else if let envURL = Self.resolveEndpointURL(from: environment) {
            self.endpointURL = envURL
        } else {
            self.endpointURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        }
        self.defaultModel = defaultModel
        self.apiKeyProvider = apiKeyProvider
        self.session = session
    }

    private static func resolveEndpointURL(from environment: [String: String]) -> URL? {
        if let direct = [environment["HELM_DIRECT_HTTP_URL"], environment["HELM_HTTP_ENDPOINT"]]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
            .flatMap(validatedHTTPURL) {
            return direct
        }
        if let baseRaw = environment["HELM_LLM_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !baseRaw.isEmpty,
           var url = validatedHTTPURL(baseRaw) {
            let path = url.path
            if path.isEmpty || path == "/" {
                url.append(path: "v1/chat/completions")
            } else if path == "/v1" || path == "/v1/" {
                url.append(path: "chat/completions")
            }
            return url
        }
        return nil
    }

    private static func validatedHTTPURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let start = CFAbsoluteTimeGetCurrent()
        let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = endpointURL.host?.lowercased()
        let isLoopback = (host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]")
        if !isLoopback && apiKey.isEmpty {
            throw LLMProviderError.missingCredential("No API key provided for \(endpointURL.absoluteString)")
        }

        let systemPrompt = LLMToolPromptCodec.buildSystemPrompt(
            baseSystemPrompt: request.systemPrompt,
            tools: request.tools
        )
        let model = request.model ?? defaultModel

        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any]
        switch dialect {
        case .openAICompatible:
            if !apiKey.isEmpty {
                urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            var body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": request.userPrompt],
                ],
            ]
            if let maxTokens = request.maxTokens {
                body["max_tokens"] = maxTokens
            }
            payload = body

        case .anthropic:
            if !apiKey.isEmpty {
                urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            payload = [
                "model": model,
                "max_tokens": request.maxTokens ?? 2048,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": request.userPrompt],
                ],
            ]
        }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let urlErr as URLError where urlErr.code == .timedOut {
            throw LLMProviderError.timeout(request.timeoutSeconds)
        } catch {
            throw LLMProviderError.networkFailure(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyPreview = String(data: data.prefix(512), encoding: .utf8) ?? ""
            throw LLMProviderError.networkFailure("HTTP \(http.statusCode): \(bodyPreview)")
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMProviderError.invalidResponse("HTTP endpoint returned non-JSON body")
        }

        let text: String
        var usage: LLMUsage?

        switch dialect {
        case .openAICompatible:
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw LLMProviderError.invalidResponse("Missing OpenAI choices[0].message.content")
            }
            text = content
            if let u = json["usage"] as? [String: Any] {
                usage = LLMUsage(
                    inputTokens: u["prompt_tokens"] as? Int ?? 0,
                    outputTokens: u["completion_tokens"] as? Int ?? 0
                )
            }
        case .anthropic:
            guard let contentArr = json["content"] as? [[String: Any]],
                  let firstText = contentArr.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String else {
                throw LLMProviderError.invalidResponse("Missing Anthropic content[0].text")
            }
            text = firstText
            if let u = json["usage"] as? [String: Any] {
                usage = LLMUsage(
                    inputTokens: u["input_tokens"] as? Int ?? 0,
                    outputTokens: u["output_tokens"] as? Int ?? 0
                )
            }
        }

        let toolCalls = !request.tools.isEmpty ? LLMToolPromptCodec.parseEnvelope(from: text).toolCalls : []
        return LLMResponse(
            text: text,
            toolCalls: toolCalls,
            usage: usage,
            stopReason: "end_turn",
            latencyMs: elapsedMs
        )
    }
}
