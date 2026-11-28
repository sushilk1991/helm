import Foundation

/// Antigravity CLI (`agy`) provider using non-interactive print mode (`agy --print ... --output-format json`).
public struct AgyCLIProvider: LLMProvider, Sendable {
    public let kind: LLMBackendKind = .agyCLI
    public let customExecutablePath: String?

    public init(executablePath: String? = nil) {
        self.customExecutablePath = executablePath
    }

    public static func resolveExecutablePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["HELM_AGY_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "\(NSHomeDirectory())/.gemini/antigravity-cli/bin/agy",
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

        let resolvedPath = customExecutablePath ?? Self.resolveExecutablePath()
        var args: [String] = []
        let execURL: URL
        if resolvedPath == "/usr/bin/env" {
            execURL = URL(fileURLWithPath: "/usr/bin/env")
            args.append("agy")
        } else {
            guard FileManager.default.isExecutableFile(atPath: resolvedPath) else {
                throw LLMProviderError.modelUnavailable("Antigravity CLI (agy) not found at \(resolvedPath)")
            }
            execURL = URL(fileURLWithPath: resolvedPath)
        }

        args.append(contentsOf: [
            "--print", combinedPrompt,
            "--output-format", "json",
            "--disable-slash-commands",
            "--print-timeout", "0s",
        ])
        let modelToUse = request.model ?? ProcessInfo.processInfo.environment["HELM_AGY_MODEL"]
        if let model = modelToUse?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }

        var processEnv = ProcessInfo.processInfo.environment
        processEnv["PATH"] = CLIAuthService.augmentedPATH(from: processEnv["PATH"])

        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(
                executableURL: execURL,
                arguments: args,
                currentDirectoryURL: request.validatedWorkingDirectory,
                environment: processEnv,
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
        return try Self.parseAgyOutput(output.stdout, hasTools: !request.tools.isEmpty, latencyMs: elapsedMs)
    }

    public static func parseAgyOutput(_ rawOutput: String, hasTools: Bool, latencyMs: Double = 0) throws -> LLMResponse {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMProviderError.invalidResponse("Antigravity CLI (agy) returned empty output")
        }

        var resultText: String?
        var usage: LLMUsage?

        // Try whole-payload JSON first (agy --output-format json)
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let isError = obj["is_error"] as? Bool, isError {
                let errText = (obj["result"] as? String) ?? (obj["error"] as? String) ?? "agy CLI returned error"
                throw LLMProviderError.processFailed(exitCode: 1, stderr: errText)
            }
            resultText = (obj["result"] as? String)
                ?? (obj["response"] as? String)
                ?? (obj["text"] as? String)
                ?? (obj["content"] as? String)
            if let usageObj = obj["usage"] as? [String: Any] {
                let input = (usageObj["input_tokens"] as? Int) ?? (usageObj["prompt_tokens"] as? Int) ?? 0
                let output = (usageObj["output_tokens"] as? Int) ?? (usageObj["completion_tokens"] as? Int) ?? 0
                let cached = (usageObj["cache_read_input_tokens"] as? Int) ?? (usageObj["cached_tokens"] as? Int) ?? 0
                let cost = obj["total_cost_usd"] as? Double
                usage = LLMUsage(inputTokens: input, outputTokens: output, cachedTokens: cached, costUSD: cost)
            }
        }

        // Fallback: NDJSON / stream-json lines or plain text
        if resultText == nil {
            for rawLine in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                if let r = (obj["result"] as? String) ?? (obj["text"] as? String) ?? (obj["response"] as? String), !r.isEmpty {
                    resultText = r
                }
            }
        }

        let finalText = resultText ?? trimmed
        let toolCalls = hasTools ? LLMToolPromptCodec.parseEnvelope(from: finalText).toolCalls : []
        return LLMResponse(
            text: finalText,
            toolCalls: toolCalls,
            usage: usage,
            stopReason: "end_turn",
            latencyMs: latencyMs
        )
    }
}
