import Foundation

/// Pi Coding Agent CLI provider (`pi` / `pycli`) supporting non-interactive print mode (`pi -p --no-session --mode json`).
public struct PiCLIProvider: LLMProvider, Sendable {
    public let kind: LLMBackendKind = .piCLI
    public let executablePath: String

    public init(executablePath: String = PiCLIProvider.resolveExecutablePath()) {
        self.executablePath = executablePath
    }

    public static func resolveExecutablePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["HELM_PI_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = [
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
            "\(NSHomeDirectory())/.local/bin/pi",
            "\(NSHomeDirectory())/.npm-global/bin/pi",
            "\(NSHomeDirectory())/.bun/bin/pi",
            "/opt/homebrew/bin/pycli",
            "/usr/local/bin/pycli",
            "\(NSHomeDirectory())/.local/bin/pycli",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/env"
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let start = CFAbsoluteTimeGetCurrent()
        let systemPrompt = LLMToolPromptCodec.buildSystemPrompt(
            baseSystemPrompt: request.systemPrompt,
            tools: request.tools
        )
        let combinedPrompt = """
        [SYSTEM INSTRUCTIONS]
        \(systemPrompt)

        [TASK PROMPT]
        \(request.userPrompt)
        """

        var args: [String] = []
        let execURL: URL
        if executablePath == "/usr/bin/env" {
            execURL = URL(fileURLWithPath: "/usr/bin/env")
            args.append("pi")
        } else {
            guard FileManager.default.isExecutableFile(atPath: executablePath) else {
                throw LLMProviderError.modelUnavailable("pi CLI not found at \(executablePath)")
            }
            execURL = URL(fileURLWithPath: executablePath)
        }

        args.append(contentsOf: [
            "-p",
            "--no-session",
            "--mode", "json",
        ])
        if let model = request.model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        args.append(combinedPrompt)

        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(
                executableURL: execURL,
                arguments: args,
                stdinData: nil,
                timeoutSeconds: request.timeoutSeconds
            )
        } catch let err as ProcessRunnerError {
            if case .timedOut(let sec) = err {
                throw LLMProviderError.timeout(sec)
            }
            throw LLMProviderError.processFailed(exitCode: -1, stderr: err.localizedDescription)
        }

        guard output.exitCode == 0 else {
            throw LLMProviderError.processFailed(exitCode: output.exitCode, stderr: output.stderr)
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        return try Self.parsePiOutput(output.stdout, hasTools: !request.tools.isEmpty, latencyMs: elapsedMs)
    }

    public static func parsePiOutput(_ rawOutput: String, hasTools: Bool, latencyMs: Double = 0) throws -> LLMResponse {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMProviderError.invalidResponse("Pi CLI produced empty output")
        }

        var lastAssistantText: String?
        var streamedDeltas = ""
        var usage: LLMUsage?
        var parsedAnyJSON = false

        for rawLine in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            parsedAnyJSON = true

            if let type = obj["type"] as? String {
                if type == "error", let msg = (obj["message"] as? String) ?? (obj["error"] as? String) {
                    throw LLMProviderError.processFailed(exitCode: 1, stderr: msg)
                }

                if type == "message_update",
                   let event = obj["assistantMessageEvent"] as? [String: Any],
                   (event["type"] as? String) == "text_delta",
                   let delta = event["delta"] as? String {
                    streamedDeltas.append(delta)
                }

                if (type == "message_end" || type == "message"),
                   let message = obj["message"] as? [String: Any],
                   (message["role"] as? String) == "assistant" {
                    if let extracted = extractText(fromMessage: message) {
                        lastAssistantText = extracted
                    }
                    if let u = extractUsage(from: message["usage"] as? [String: Any]) {
                        usage = u
                    }
                }

                if type == "agent_end",
                   let messages = obj["messages"] as? [[String: Any]] {
                    for msg in messages.reversed() where (msg["role"] as? String) == "assistant" {
                        if let extracted = extractText(fromMessage: msg) {
                            lastAssistantText = extracted
                        }
                        if let u = extractUsage(from: msg["usage"] as? [String: Any]) {
                            usage = u
                        }
                        break
                    }
                }
            } else if let result = obj["result"] as? String {
                lastAssistantText = result
            } else if let text = obj["text"] as? String {
                lastAssistantText = text
            }
        }

        let finalText: String
        if let lastAssistantText, !lastAssistantText.isEmpty {
            finalText = lastAssistantText
        } else if !streamedDeltas.isEmpty {
            finalText = streamedDeltas
        } else if !parsedAnyJSON {
            finalText = trimmed
        } else {
            throw LLMProviderError.invalidResponse("Pi CLI JSON stream contained no assistant message")
        }

        let toolCalls = hasTools ? LLMToolPromptCodec.parseEnvelope(from: finalText).toolCalls : []
        return LLMResponse(
            text: finalText,
            toolCalls: toolCalls,
            usage: usage,
            stopReason: "end_turn",
            latencyMs: latencyMs
        )
    }

    private static func extractText(fromMessage message: [String: Any]) -> String? {
        if let str = message["content"] as? String, !str.isEmpty {
            return str
        }
        if let blocks = message["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            let joined = texts.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func extractUsage(from obj: [String: Any]?) -> LLMUsage? {
        guard let obj else { return nil }
        let input = (obj["input"] as? Int) ?? (obj["input_tokens"] as? Int) ?? 0
        let output = (obj["output"] as? Int) ?? (obj["output_tokens"] as? Int) ?? 0
        let cached = (obj["cacheRead"] as? Int) ?? (obj["cached_input_tokens"] as? Int) ?? 0
        let cost = (obj["cost"] as? [String: Any])?["total"] as? Double
        return LLMUsage(inputTokens: input, outputTokens: output, cachedTokens: cached, costUSD: cost)
    }
}
