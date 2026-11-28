import Foundation

public struct CodexCLIProvider: LLMProvider, Sendable {
    public let kind: LLMBackendKind = .codexCLI
    public let executablePath: String

    public init(executablePath: String = CodexCLIProvider.resolveExecutablePath()) {
        self.executablePath = executablePath
    }

    public static func resolveExecutablePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["HELM_CODEX_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
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

        let effectivePath = ProcessInfo.processInfo.environment["HELM_CODEX_PATH"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? executablePath
        var args: [String] = []
        let execURL: URL
        if effectivePath == "/usr/bin/env" {
            execURL = URL(fileURLWithPath: "/usr/bin/env")
            args.append("codex")
        } else {
            guard FileManager.default.isExecutableFile(atPath: effectivePath) else {
                throw LLMProviderError.modelUnavailable("codex CLI not found at \(effectivePath)")
            }
            execURL = URL(fileURLWithPath: effectivePath)
        }

        args.append(contentsOf: [
            "exec", "-",
            "--json",
            "--ephemeral",
            "--skip-git-repo-check",
            "-s", "read-only",
        ])
        if let model = request.model, !model.isEmpty {
            args.append(contentsOf: ["-m", model])
        }

        var processEnv = ProcessInfo.processInfo.environment
        processEnv["PATH"] = CLIAuthService.augmentedPATH(from: processEnv["PATH"])
        if processEnv["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let helmDir = processEnv["HELM_CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !helmDir.isEmpty {
            processEnv["CODEX_HOME"] = helmDir
        }

        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(
                executableURL: execURL,
                arguments: args,
                currentDirectoryURL: request.validatedWorkingDirectory,
                environment: processEnv,
                stdinData: Data(combinedPrompt.utf8),
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
        return try Self.parseCodexJSONL(output.stdout, hasTools: !request.tools.isEmpty, latencyMs: elapsedMs)
    }

    public static func parseCodexJSONL(_ jsonl: String, hasTools: Bool, latencyMs: Double = 0) throws -> LLMResponse {
        var lastAgentMessage: String?
        var usage: LLMUsage?

        for rawLine in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else {
                continue
            }

            if type == "turn.failed" || type == "error" {
                let errMsg = (obj["message"] as? String)
                    ?? ((obj["error"] as? [String: Any])?["message"] as? String)
                    ?? "Codex turn failed"
                throw LLMProviderError.processFailed(exitCode: 1, stderr: errMsg)
            }

            if type == "item.completed",
               let item = obj["item"] as? [String: Any],
               (item["type"] as? String) == "agent_message",
               let text = item["text"] as? String {
                lastAgentMessage = text
            }

            if type == "turn.completed", let usageObj = obj["usage"] as? [String: Any] {
                let input = usageObj["input_tokens"] as? Int ?? 0
                let output = usageObj["output_tokens"] as? Int ?? 0
                let cached = usageObj["cached_input_tokens"] as? Int ?? 0
                usage = LLMUsage(inputTokens: input, outputTokens: output, cachedTokens: cached, costUSD: nil)
            }
        }

        guard let message = lastAgentMessage else {
            throw LLMProviderError.invalidResponse("Codex JSONL stream produced no agent_message")
        }

        let toolCalls = hasTools ? LLMToolPromptCodec.parseEnvelope(from: message).toolCalls : []
        return LLMResponse(
            text: message,
            toolCalls: toolCalls,
            usage: usage,
            stopReason: "end_turn",
            latencyMs: latencyMs
        )
    }
}
