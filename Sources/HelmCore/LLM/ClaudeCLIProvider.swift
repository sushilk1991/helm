import Foundation

public struct ClaudeCLIProvider: LLMProvider, Sendable {
    public let kind: LLMBackendKind = .claudeCLI
    public let executablePath: String

    public init(executablePath: String = ClaudeCLIProvider.resolveExecutablePath()) {
        self.executablePath = executablePath
    }

    public static func resolveExecutablePath() -> String {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
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

        var args: [String] = []
        let execURL: URL
        if executablePath == "/usr/bin/env" {
            execURL = URL(fileURLWithPath: "/usr/bin/env")
            args.append("claude")
        } else {
            guard FileManager.default.isExecutableFile(atPath: executablePath) else {
                throw LLMProviderError.modelUnavailable("claude CLI not found at \(executablePath)")
            }
            execURL = URL(fileURLWithPath: executablePath)
        }

        // CRITICAL: Never pass --bare (which disables Keychain/OAuth auth).
        args.append(contentsOf: [
            "-p", request.userPrompt,
            "--output-format", "json",
            "--no-session-persistence",
            "--tools", "",
            "--system-prompt", systemPrompt,
        ])
        if let model = request.model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }

        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(
                executableURL: execURL,
                arguments: args,
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
        return try Self.parseClaudeJSON(output.stdoutData, hasTools: !request.tools.isEmpty, latencyMs: elapsedMs)
    }

    public static func parseClaudeJSON(_ data: Data, hasTools: Bool, latencyMs: Double = 0) throws -> LLMResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMProviderError.invalidResponse("Claude output was not valid JSON")
        }
        if let isError = obj["is_error"] as? Bool, isError {
            let errText = (obj["result"] as? String) ?? "Claude CLI returned is_error=true"
            throw LLMProviderError.processFailed(exitCode: 1, stderr: errText)
        }
        guard let resultText = obj["result"] as? String else {
            throw LLMProviderError.invalidResponse("Missing 'result' field in Claude JSON")
        }

        var usage: LLMUsage?
        if let usageObj = obj["usage"] as? [String: Any] {
            let input = usageObj["input_tokens"] as? Int ?? 0
            let output = usageObj["output_tokens"] as? Int ?? 0
            let cached = (usageObj["cache_read_input_tokens"] as? Int ?? 0)
                + (usageObj["cache_creation_input_tokens"] as? Int ?? 0)
            let cost = obj["total_cost_usd"] as? Double
            usage = LLMUsage(inputTokens: input, outputTokens: output, cachedTokens: cached, costUSD: cost)
        }

        let stopReason = (obj["stop_reason"] as? String) ?? "end_turn"
        let toolCalls = hasTools ? LLMToolPromptCodec.parseEnvelope(from: resultText).toolCalls : []
        return LLMResponse(
            text: resultText,
            toolCalls: toolCalls,
            usage: usage,
            stopReason: stopReason,
            latencyMs: latencyMs
        )
    }
}
