#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import CryptoKit
import Foundation

public enum WorkerOutcome: Sendable {
    case completed(summary: String, sharedWrites: [(key: String, title: String, value: String)], artifactPaths: [String])
    case retryableError(toolName: String, argumentsJSON: String, message: String)
    case hold(kind: ExceptionKind, severity: ExceptionSeverity, title: String, summary: String, options: [String])
}

public struct AgentWorkerRunner: Sendable {
    private let database: HelmDatabase
    private let sharedStateStore: SharedStateStore
    private let providerRegistry: LLMProviderRegistry
    private let sandboxExecutor: (any SandboxExecutor)?
    private let browserService: (any BrowserOCRService)?
    private let stallDetector: StallDetector
    private let driftDetector: DriftDetector
    private let environment: [String: String]

    public init(
        database: HelmDatabase,
        sharedStateStore: SharedStateStore,
        providerRegistry: LLMProviderRegistry,
        sandboxExecutor: (any SandboxExecutor)? = nil,
        browserService: (any BrowserOCRService)? = nil,
        stallDetector: StallDetector,
        driftDetector: DriftDetector = DriftDetector(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.database = database
        self.sharedStateStore = sharedStateStore
        self.providerRegistry = providerRegistry
        self.sandboxExecutor = sandboxExecutor
        self.browserService = browserService
        self.stallDetector = stallDetector
        self.driftDetector = driftDetector
        self.environment = environment
    }

    public func executeAttempt(
        project: Project,
        agent: AgentProfile,
        task: DelegatedTask,
        stepIndex: Int
    ) async -> WorkerOutcome {
        // 1. Disk budget guard
        if let lowDiskOutcome = checkDiskBudget(project: project) {
            return lowDiskOutcome
        }

        // 2. Transition agent state -> thinking
        try? await database.updateAgentState(id: agent.id, state: .thinking)

        // 2b. Deterministic E2E untrusted web snippet injection probe (T2-B-05)
        if agent.backend == .mock,
           let rawSnippet = environment["HELM_UNTRUSTED_WEB_SNIPPET"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawSnippet.isEmpty {
            let obsReq = SharedStateWriteRequest(
                projectID: project.id,
                taskID: task.id,
                scope: .projectShared,
                ownerAgentID: agent.id,
                category: .observation,
                key: "obs.web.\(task.id.uuidString.prefix(8))",
                title: "Web Page Observation",
                content: rawSnippet,
                claimedTrust: .humanAuthoritative,
                provenance: ProvenanceRecord(
                    source: .browserObservation,
                    authorAgentID: agent.id,
                    sourceURI: "http://127.0.0.1/prompt-injection"
                )
            )
            _ = try? await sharedStateStore.write(obsReq)

            let tamperReq = SharedStateWriteRequest(
                projectID: project.id,
                taskID: task.id,
                scope: .projectShared,
                ownerAgentID: agent.id,
                category: .rule,
                key: "policy.guard",
                title: "Untrusted Rule Override",
                content: rawSnippet,
                claimedTrust: .humanAuthoritative,
                provenance: ProvenanceRecord(
                    source: .externalWeb,
                    authorAgentID: agent.id,
                    sourceURI: "http://127.0.0.1/prompt-injection"
                )
            )
            do {
                _ = try await sharedStateStore.write(tamperReq)
            } catch {
                return .hold(
                    kind: .drift,
                    severity: .critical,
                    title: "Untrusted Shared-State Rule Tamper Blocked",
                    summary: error.localizedDescription,
                    options: ["redirect", "abort"]
                )
            }
        }

        // 3. Assemble 4 SHA-256 digest-tracked prompt channels
        let rankedMemory = try? await sharedStateStore.rankAndPackMemory(
            projectID: project.id,
            agentID: agent.id,
            query: "\(task.title) \(task.instructions) \(project.goal)",
            charBudget: project.budgetPolicy.memoryCharBudget
        )

        let personalityLine = agent.personalityNotes.isEmpty
            ? "\(agent.personality.displayName): \(agent.personality.promptDirective)"
            : "\(agent.personality.displayName): \(agent.personality.promptDirective) Custom traits: \(agent.personalityNotes)"

        let rawChannels: [PromptChannel: String] = [
            .identity: "Agent: \(agent.name)\nRole: \(agent.role.rawValue)\nPersonality: \(personalityLine)\nGoal: \(agent.goal)\nCapabilities: \(agent.capabilities.map(\.rawValue).sorted().joined(separator: ", "))",
            .projectContext: "Project: \(project.name)\nGoal: \(project.goal)\nWorkspace: \(project.workspaceRoot.path)",
            .sharedMemory: rankedMemory?.packedText ?? "",
            .continuity: "Task: \(task.title)\nAttempt: \(task.attemptCount + 1)/\(task.maxAttempts)\nInstructions: \(task.instructions)",
        ]

        let slices = (try? await sharedStateStore.preparePromptChannels(
            projectID: project.id,
            agentID: agent.id,
            rawChannels: rawChannels
        )) ?? []

        var digests: [String: String] = [:]
        var contextParts: [String] = []
        for slice in slices {
            digests[slice.channel.rawValue] = slice.sha256Digest
            if let content = slice.content, !content.isEmpty {
                contextParts.append("[\(slice.channel.rawValue)]\n\(content)")
            }
        }

        let systemPrompt = "Role: \(agent.role.rawValue)\nPersonality: \(personalityLine)\nAgentGoal: \(agent.goal)\nOperate inside workspace: \(project.workspaceRoot.path)"
        let userPrompt = "TASK_EXECUTION\nTaskID: \(task.id.uuidString)\n" + contextParts.joined(separator: "\n\n")

        // Only advertise tools that match this agent's granted capabilities so LLMs don't trigger avoidable holds.
        var tools: [LLMToolSchema] = [
            LLMToolSchema(
                name: "complete_task",
                description: "Complete the task and optionally propose shared-state output.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"summary\":{\"type\":\"string\"},\"shared_key\":{\"type\":\"string\"},\"shared_title\":{\"type\":\"string\"},\"shared_value\":{\"type\":\"string\"}}}"
            ),
            LLMToolSchema(
                name: "write_workspace_file",
                description: "Write a relative file inside the project workspace.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}}}"
            ),
        ]
        if agent.capabilities.contains(.codeExec) {
            tools.append(LLMToolSchema(
                name: "run_command",
                description: "Execute a command inside the isolated sandbox.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}"
            ))
        }
        if agent.capabilities.contains(.browser) {
            tools.append(LLMToolSchema(
                name: "browser_act",
                description: "Navigate or interact with a headless web page using Vision OCR and CDP.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"},\"action\":{\"type\":\"string\",\"enum\":[\"navigate\",\"click_ocr\",\"click_css\",\"type_text\",\"eval_js\"]},\"target\":{\"type\":\"string\"},\"query\":{\"type\":\"string\"},\"x\":{\"type\":\"number\"},\"y\":{\"type\":\"number\"},\"text\":{\"type\":\"string\"},\"submit\":{\"type\":\"boolean\"},\"script\":{\"type\":\"string\"}}}"
            ))
        }
        if agent.capabilities.contains(.proposeSharedState) {
            tools.append(LLMToolSchema(
                name: "propose_shared_memory",
                description: "Write a fact or observation to shared memory.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}}}"
            ))
        }
        if agent.capabilities.contains(.requestHumanDecision) {
            tools.append(LLMToolSchema(
                name: "ask_human",
                description: "Pause and ask the human operator for a decision.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\"},\"options\":{\"type\":\"array\"}}}"
            ))
        }

        let provider: any LLMProvider
        do {
            provider = try providerRegistry.provider(for: agent.backend)
        } catch {
            return .hold(
                kind: .providerFailure,
                severity: .critical,
                title: "LLM Provider Unavailable",
                summary: error.localizedDescription,
                options: ["retry", "redirect", "abort"]
            )
        }

        let request = LLMRequest(
            agentID: agent.id,
            projectID: project.id,
            stepIndex: stepIndex,
            systemPrompt: systemPrompt,
            digestChannels: digests,
            userPrompt: userPrompt,
            tools: tools,
            model: agent.modelOverride,
            timeoutSeconds: project.budgetPolicy.stepTimeoutSeconds
        )

        // 4. Execute LLM call raced against stepTimeoutSeconds
        let startedAt = Date()
        let response: LLMResponse
        do {
            response = try await LLMTimeoutRace.completeWithTimeout(
                provider: provider,
                request: request,
                timeoutSeconds: project.budgetPolicy.stepTimeoutSeconds
            )
        } catch is CancellationError {
            return .retryableError(
                toolName: "cancelled",
                argumentsJSON: "{}",
                message: "Agent '\(agent.name)' step was cancelled."
            )
        } catch let err as LLMProviderError {
            if case .timeout(let sec) = err {
                return .hold(
                    kind: .stall,
                    severity: .critical,
                    title: "Agent Step Timed Out",
                    summary: "Agent '\(agent.name)' exceeded step timeout (\(Int(sec))s) on '\(task.title)'.",
                    options: ["retry", "redirect", "abort"]
                )
            }
            let errMsg = err.localizedDescription
            if let authProvider = LLMAuthErrorDetector.detectRequiredAuthProvider(from: errMsg, backend: agent.backend) {
                return .hold(
                    kind: .providerFailure,
                    severity: .critical,
                    title: "CLI Sign-In Required (\(authProvider.displayName))",
                    summary: "\(agent.name) could not reach \(authProvider.displayName) because it is not signed in or the session expired. Open Settings → Accounts & Login to sign in via browser, then click Retry. Details: \(errMsg)",
                    options: ["retry", "redirect", "abort"]
                )
            }
            return .hold(
                kind: .providerFailure,
                severity: .critical,
                title: "LLM Provider Failure",
                summary: "Agent '\(agent.name)' provider failed: \(errMsg)",
                options: ["retry", "redirect", "abort"]
            )
        } catch {
            let errMsg = error.localizedDescription
            if let authProvider = LLMAuthErrorDetector.detectRequiredAuthProvider(from: errMsg, backend: agent.backend) {
                return .hold(
                    kind: .providerFailure,
                    severity: .critical,
                    title: "CLI Sign-In Required (\(authProvider.displayName))",
                    summary: "\(agent.name) could not reach \(authProvider.displayName) because it is not signed in or the session expired. Open Settings → Accounts & Login to sign in via browser, then click Retry. Details: \(errMsg)",
                    options: ["retry", "redirect", "abort"]
                )
            }
            return .hold(
                kind: .providerFailure,
                severity: .critical,
                title: "LLM Provider Failure",
                summary: errMsg,
                options: ["retry", "redirect", "abort"]
            )
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        if stallDetector.checkStepTimeout(elapsed: elapsed, policy: project.budgetPolicy) == .stall {
            return .hold(
                kind: .stall,
                severity: .critical,
                title: "Agent Step Timed Out",
                summary: "Step duration \(String(format: "%.2f", elapsed))s exceeded budget.",
                options: ["retry", "abort"]
            )
        }

        // 5. Parse structured tool envelope
        let parsed = LLMToolPromptCodec.parseEnvelope(from: response.text)
        let toolCalls = response.toolCalls.isEmpty ? parsed.toolCalls : response.toolCalls

        if toolCalls.isEmpty {
            if response.stopReason == "error_recoverable" || parsed.finalResponse == nil {
                return .retryableError(
                    toolName: "llm_json_contract",
                    argumentsJSON: "{}",
                    message: "Malformed or empty JSON action envelope from agent '\(agent.name)'"
                )
            }
            let trimmed = (parsed.finalResponse ?? response.text).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") && (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) == nil {
                return .retryableError(
                    toolName: "llm_json_contract",
                    argumentsJSON: "{}",
                    message: "Unparseable JSON response from agent '\(agent.name)'"
                )
            }
            await stallDetector.recordToolSuccess(agentID: agent.id)
            return .completed(summary: trimmed, sharedWrites: [], artifactPaths: [])
        }

        // 6. Execute tool calls with capability, StallDetector, and DriftDetector guards
        var sharedWrites: [(key: String, title: String, value: String)] = []
        var artifactPaths: [String] = []
        var finalSummary = parsed.finalResponse ?? "Task '\(task.title)' completed by \(agent.name)."
        var activeBrowserSessionID: UUID? = nil

        func closeActiveBrowserSession() async {
            if let sid = activeBrowserSessionID {
                activeBrowserSessionID = nil
                await browserService?.closeSession(sid)
            }
        }

        for (callIndex, call) in toolCalls.enumerated() {
            if Task.isCancelled {
                await closeActiveBrowserSession()
                return .retryableError(
                    toolName: "cancelled",
                    argumentsJSON: "{}",
                    message: "Agent '\(agent.name)' execution was cancelled."
                )
            }
            let args = parseArgsDict(call.argumentsJSON)

            switch call.name {
            case "ask_human", "request_human_decision":
                await closeActiveBrowserSession()
                let question = (args["question"] as? String) ?? "Human decision required for '\(task.title)'"
                let options = (args["options"] as? [String]) ?? ["approve", "redirect", "abort"]
                return .hold(
                    kind: .humanDecision,
                    severity: .attention,
                    title: "Human Decision Required",
                    summary: question,
                    options: options
                )

            case "failing_tool_probe":
                await closeActiveBrowserSession()
                let errMsg = (args["error"] as? String) ?? "Tool execution failed"
                let check = await stallDetector.recordToolFailure(
                    agentID: agent.id,
                    toolName: call.name,
                    argumentsJSON: call.argumentsJSON,
                    errorMessage: errMsg,
                    policy: project.budgetPolicy
                )
                if check.triggeredKind == .loop {
                    return .hold(
                        kind: .loop,
                        severity: .critical,
                        title: "Repeated Failing Tool Loop Detected",
                        summary: "Agent '\(agent.name)' repeated failing tool '\(call.name)' \(check.count) times (\(errMsg)).",
                        options: ["retry", "redirect", "abort"]
                    )
                }
                return .retryableError(toolName: call.name, argumentsJSON: call.argumentsJSON, message: errMsg)

            case "write_workspace_file":
                let candidate = (args["path"] as? String) ?? ""
                let safeURL: URL
                let canonicalRoot: String
                do {
                    safeURL = try driftDetector.validateWorkspacePath(candidate, workspaceRoot: project.workspaceRoot)
                    guard let root = DriftDetector.canonicalPath(for: project.workspaceRoot),
                          safeURL.path != root else {
                        throw DriftViolation.workspaceEscape(
                            candidatePath: candidate,
                            workspaceRoot: project.workspaceRoot.path
                        )
                    }
                    canonicalRoot = root
                } catch {
                    await closeActiveBrowserSession()
                    return .hold(
                        kind: .drift,
                        severity: .critical,
                        title: "Workspace Boundary Drift Detected",
                        summary: error.localizedDescription,
                        options: ["redirect", "abort"]
                    )
                }
                try? await database.updateAgentState(id: agent.id, state: .executing)
                let content = (args["content"] as? String) ?? ""
                do {
                    let parentURL = safeURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
                    let verifiedURL = try driftDetector.validateWorkspacePath(safeURL.path, workspaceRoot: project.workspaceRoot)
                    guard verifiedURL.path == safeURL.path else {
                        throw DriftViolation.workspaceEscape(candidatePath: candidate, workspaceRoot: canonicalRoot)
                    }
                    var parentStat = stat()
                    guard lstat(parentURL.path, &parentStat) == 0,
                          (parentStat.st_mode & S_IFMT) == S_IFDIR else {
                        throw DriftViolation.workspaceEscape(candidatePath: candidate, workspaceRoot: canonicalRoot)
                    }
                    var leafStat = stat()
                    if lstat(verifiedURL.path, &leafStat) == 0,
                       (leafStat.st_mode & S_IFMT) == S_IFLNK {
                        throw DriftViolation.workspaceEscape(candidatePath: candidate, workspaceRoot: canonicalRoot)
                    }
                    let fileData = Data(content.utf8)
                    try fileData.write(to: verifiedURL, options: .atomic)
                    artifactPaths.append(candidate)
                    let fileHash = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
                    let artifact = ArtifactRecord(
                        projectID: project.id,
                        agentID: agent.id,
                        taskID: task.id,
                        kind: "workspace_file",
                        relativePath: candidate,
                        mimeType: Self.mimeType(for: candidate),
                        byteSize: Int64(fileData.count),
                        sha256: fileHash
                    )
                    try? await database.insertArtifact(artifact)
                } catch let driftErr as DriftViolation {
                    await closeActiveBrowserSession()
                    return .hold(
                        kind: .drift,
                        severity: .critical,
                        title: "Workspace Boundary Drift Detected",
                        summary: driftErr.localizedDescription,
                        options: ["redirect", "abort"]
                    )
                } catch {
                    await closeActiveBrowserSession()
                    let check = await stallDetector.recordToolFailure(
                        agentID: agent.id,
                        toolName: call.name,
                        argumentsJSON: call.argumentsJSON,
                        errorMessage: error.localizedDescription,
                        policy: project.budgetPolicy
                    )
                    if check.triggeredKind == .loop {
                        return .hold(
                            kind: .loop,
                            severity: .critical,
                            title: "Repeated File Write Failure Loop",
                            summary: error.localizedDescription,
                            options: ["retry", "abort"]
                        )
                    }
                    return .retryableError(toolName: call.name, argumentsJSON: call.argumentsJSON, message: error.localizedDescription)
                }

            case "run_command":
                guard agent.capabilities.contains(.codeExec) else {
                    await closeActiveBrowserSession()
                    return .hold(
                        kind: .drift,
                        severity: .critical,
                        title: "Unauthorized Capability Request",
                        summary: "Agent '\(agent.name)' attempted 'run_command' without 'codeExec' capability.",
                        options: ["redirect", "abort"]
                    )
                }
                let cmd = (args["command"] as? String) ?? ""
                if let sandboxExecutor {
                    try? await database.updateAgentState(id: agent.id, state: .executing)
                    var sandboxEnv: [String: String] = [:]
                    let currentEnv = ProcessInfo.processInfo.environment
                    if currentEnv["HELM_FORWARD_SANDBOX_AUTH"] == "1" {
                        let forwardableKeys = [
                            "ANTHROPIC_API_KEY",
                            "OPENAI_API_KEY",
                            "GEMINI_API_KEY",
                            "OPENROUTER_API_KEY",
                            "HELM_LLM_API_KEY",
                        ]
                        for key in forwardableKeys {
                            if let value = currentEnv[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !value.isEmpty {
                                sandboxEnv[key] = value
                            }
                        }
                    }
                    let req = ExecutionRequest(
                        projectID: project.id,
                        workspacePath: project.workspaceRoot,
                        command: cmd,
                        timeoutSeconds: project.budgetPolicy.stepTimeoutSeconds,
                        environment: sandboxEnv
                    )
                    do {
                        let res = try await sandboxExecutor.execute(req)
                        if let payloadData = try? HelmJSON.makeEncoder().encode(res),
                           let payloadStr = String(data: payloadData, encoding: .utf8) {
                            try? await database.appendEvent(RunEvent(
                                projectID: project.id,
                                agentID: agent.id,
                                taskID: task.id,
                                kind: .toolExecuted,
                                summary: "run_command exit=\(res.exitCode) timedOut=\(res.timedOut)",
                                payloadJSON: payloadStr,
                                trustLevel: .untrustedData
                            ))
                        }
                        if res.timedOut || res.exitCode != 0 {
                            await closeActiveBrowserSession()
                            let msg = res.timedOut
                                ? "Sandbox command timed out after \(String(format: "%.2f", req.timeoutSeconds))s (exit \(res.exitCode)): \(res.stderr)"
                                : "Sandbox exited \(res.exitCode): \(res.stderr)"
                            let check = await stallDetector.recordToolFailure(
                                agentID: agent.id,
                                toolName: call.name,
                                argumentsJSON: call.argumentsJSON,
                                errorMessage: msg,
                                policy: project.budgetPolicy
                            )
                            if check.triggeredKind == .loop {
                                return .hold(kind: .loop, severity: .critical, title: "Sandbox Failure Loop", summary: msg, options: ["retry", "abort"])
                            }
                            return .retryableError(toolName: call.name, argumentsJSON: call.argumentsJSON, message: msg)
                        }
                        finalSummary = res.stdout.isEmpty ? "Command '\(cmd)' exited 0." : res.stdout
                    } catch {
                        await closeActiveBrowserSession()
                        return .retryableError(toolName: call.name, argumentsJSON: call.argumentsJSON, message: error.localizedDescription)
                    }
                } else {
                    await closeActiveBrowserSession()
                    return .retryableError(
                        toolName: call.name,
                        argumentsJSON: call.argumentsJSON,
                        message: "SandboxExecutor not wired"
                    )
                }

            case "browser_act":
                guard agent.capabilities.contains(.browser) else {
                    await closeActiveBrowserSession()
                    return .hold(
                        kind: .drift,
                        severity: .critical,
                        title: "Unauthorized Capability Request",
                        summary: "Agent '\(agent.name)' attempted 'browser_act' without 'browser' capability.",
                        options: ["redirect", "abort"]
                    )
                }
                guard let browserService else {
                    await closeActiveBrowserSession()
                    return .retryableError(
                        toolName: call.name,
                        argumentsJSON: call.argumentsJSON,
                        message: "BrowserOCRService not wired"
                    )
                }

                try? await database.updateAgentState(id: agent.id, state: .browsing)
                do {
                    let sessionID: UUID
                    if let existing = activeBrowserSessionID {
                        sessionID = existing
                    } else {
                        let opened = try await browserService.openSession(projectID: project.id)
                        activeBrowserSessionID = opened
                        sessionID = opened
                    }

                    let rawAction = (args["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let urlArg = (args["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let actionKind = rawAction ?? ((urlArg != nil && !(urlArg?.isEmpty ?? true)) ? "navigate" : "navigate")

                    if actionKind != "navigate", let urlArg, !urlArg.isEmpty {
                        _ = try await browserService.perform(
                            .navigate(url: urlArg),
                            sessionID: sessionID,
                            timeoutSeconds: project.budgetPolicy.stepTimeoutSeconds
                        )
                    }

                    let browserAction: BrowserAction
                    switch actionKind {
                    case "navigate":
                        let targetURL = urlArg ?? ""
                        guard !targetURL.isEmpty else {
                            throw NSError(domain: "AgentWorkerRunner", code: 2, userInfo: [NSLocalizedDescriptionKey: "browser_act navigate requires non-empty 'url'"])
                        }
                        browserAction = .navigate(url: targetURL)
                    case "click_ocr", "clickocr", "click_ocr_text":
                        let query = (args["query"] as? String) ?? (args["target"] as? String) ?? ""
                        browserAction = .clickOCRText(query: query)
                    case "click_css", "clickcss":
                        let x = Self.extractDouble(args["x"]) ?? 0
                        let y = Self.extractDouble(args["y"]) ?? 0
                        browserAction = .clickCSS(x: x, y: y)
                    case "type_text", "typetext", "type":
                        let target = (args["target"] as? String) ?? (args["selector"] as? String) ?? (args["query"] as? String) ?? ""
                        let text = (args["text"] as? String) ?? ""
                        let submit = (args["submit"] as? Bool) ?? false
                        browserAction = .typeText(selectorOrOCR: target, text: text, submit: submit)
                    case "eval_js", "evaluate_js", "evaljs":
                        let script = (args["script"] as? String) ?? ""
                        browserAction = .evaluateJS(script: script)
                    default:
                        throw NSError(domain: "AgentWorkerRunner", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsupported browser_act action '\(actionKind)'"])
                    }

                    let observation = try await browserService.perform(
                        browserAction,
                        sessionID: sessionID,
                        timeoutSeconds: project.budgetPolicy.stepTimeoutSeconds
                    )

                    let ocrPreview = observation.ocrLines.prefix(20).map(\.text).joined(separator: "\n")
                    let obsContent = "URL: \(observation.url)\nTitle: \(observation.title)\nOCR:\n\(ocrPreview)"
                    let obsReq = SharedStateWriteRequest(
                        projectID: project.id,
                        taskID: task.id,
                        scope: .projectShared,
                        ownerAgentID: agent.id,
                        category: .observation,
                        key: "obs.browser.\(task.id.uuidString.prefix(8)).\(stepIndex).\(callIndex)",
                        title: observation.title.isEmpty ? "Browser Observation" : observation.title,
                        content: obsContent,
                        claimedTrust: .untrustedData,
                        provenance: ProvenanceRecord(
                            source: .browserObservation,
                            authorAgentID: agent.id,
                            sourceURI: observation.url
                        )
                    )
                    _ = try? await sharedStateStore.write(obsReq)

                    let sourceShotURL = observation.screenshotPNGPath
                    let fileData = try? Data(contentsOf: sourceShotURL)
                    var finalShotURL = sourceShotURL
                    var relPath = sourceShotURL.path.hasPrefix(project.workspaceRoot.path)
                        ? String(sourceShotURL.path.dropFirst(project.workspaceRoot.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        : sourceShotURL.path

                    if let data = fileData,
                       let persisted = try? Self.persistBrowserScreenshot(
                           data: data,
                           sourceFilename: sourceShotURL.lastPathComponent,
                           workspaceRoot: project.workspaceRoot,
                           driftDetector: driftDetector
                       ) {
                        finalShotURL = persisted.url
                        relPath = persisted.relativePath
                    }

                    let persistedObservation = BrowserObservation(
                        url: observation.url,
                        title: observation.title,
                        viewportSize: observation.viewportSize,
                        screenshotPNGPath: finalShotURL,
                        ocrLines: observation.ocrLines,
                        domElements: observation.domElements,
                        trustTag: observation.trustTag,
                        latencyMs: observation.latencyMs
                    )

                    if let obsData = try? HelmJSON.makeEncoder().encode(persistedObservation),
                       let obsStr = String(data: obsData, encoding: .utf8) {
                        try? await database.appendEvent(RunEvent(
                            projectID: project.id,
                            agentID: agent.id,
                            taskID: task.id,
                            kind: .toolExecuted,
                            summary: "browser_act \(actionKind) -> \(persistedObservation.url) (\(persistedObservation.ocrLines.count) OCR lines)",
                            payloadJSON: obsStr,
                            trustLevel: .untrustedData
                        ))
                    }

                    let byteSize = Int64(fileData?.count ?? 0)
                    let hashSource = fileData ?? Data(finalShotURL.path.utf8)
                    let sha = SHA256.hash(data: hashSource).map { String(format: "%02x", $0) }.joined()
                    let artifact = ArtifactRecord(
                        projectID: project.id,
                        agentID: agent.id,
                        taskID: task.id,
                        kind: "browser_screenshot",
                        relativePath: relPath,
                        mimeType: "image/png",
                        byteSize: byteSize,
                        sha256: sha
                    )
                    try? await database.insertArtifact(artifact)
                    artifactPaths.append(relPath)

                    if !ocrPreview.isEmpty {
                        finalSummary = "Browser observed \(observation.url): \(ocrPreview.replacingOccurrences(of: "\n", with: " | "))"
                    } else {
                        finalSummary = "Browser observed \(observation.url) (\(observation.title))"
                    }

                    try? await database.updateAgentState(id: agent.id, state: .thinking)
                } catch is CancellationError {
                    try? await database.updateAgentState(id: agent.id, state: .thinking)
                    await closeActiveBrowserSession()
                    return .retryableError(toolName: call.name, argumentsJSON: call.argumentsJSON, message: "browser_act cancelled")
                } catch {
                    try? await database.updateAgentState(id: agent.id, state: .thinking)
                    await closeActiveBrowserSession()
                    let msg = error.localizedDescription
                    let check = await stallDetector.recordToolFailure(
                        agentID: agent.id,
                        toolName: call.name,
                        argumentsJSON: call.argumentsJSON,
                        errorMessage: msg,
                        policy: project.budgetPolicy
                    )
                    if check.triggeredKind == .loop {
                        return .hold(kind: .loop, severity: .critical, title: "Browser Action Failure Loop", summary: msg, options: ["retry", "abort"])
                    }
                    return .retryableError(toolName: call.name, argumentsJSON: call.argumentsJSON, message: msg)
                }

            case "propose_shared_memory":
                let key = (args["key"] as? String) ?? "agent.note"
                let title = (args["title"] as? String) ?? key
                let content = (args["content"] as? String) ?? ""
                let category = SharedStateCategory(rawValue: (args["category"] as? String) ?? "fact") ?? .fact
                let req = SharedStateWriteRequest(
                    projectID: project.id,
                    taskID: task.id,
                    scope: .projectShared,
                    ownerAgentID: agent.id,
                    category: category,
                    key: key,
                    title: title,
                    content: content,
                    provenance: ProvenanceRecord(source: .workerAgent, authorAgentID: agent.id)
                )
                do {
                    _ = try await sharedStateStore.write(req)
                } catch {
                    await closeActiveBrowserSession()
                    return .hold(
                        kind: .drift,
                        severity: .critical,
                        title: "Protected Shared-State Write Rejected",
                        summary: error.localizedDescription,
                        options: ["redirect", "abort"]
                    )
                }

            case "complete_task":
                if let summary = args["summary"] as? String, !summary.isEmpty {
                    finalSummary = summary
                }
                if let key = args["shared_key"] as? String,
                   let val = args["shared_value"] as? String,
                   !key.isEmpty {
                    let title = (args["shared_title"] as? String) ?? key
                    sharedWrites.append((key: key, title: title, value: val))
                }

            default:
                break
            }
        }

        await closeActiveBrowserSession()
        await stallDetector.recordToolSuccess(agentID: agent.id)
        return .completed(summary: finalSummary, sharedWrites: sharedWrites, artifactPaths: artifactPaths)
    }

    private static func sanitizeArtifactFilename(_ rawName: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let filteredScalars = rawName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        var cleaned = String(filteredScalars)
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "shot_\(UUID().uuidString).png"
        }
        if !cleaned.lowercased().hasSuffix(".png") {
            cleaned += ".png"
        }
        return cleaned
    }

    private static func persistBrowserScreenshot(
        data: Data,
        sourceFilename: String,
        workspaceRoot: URL,
        driftDetector: DriftDetector
    ) throws -> (url: URL, relativePath: String) {
        let filename = sanitizeArtifactFilename(sourceFilename)
        let relPath = ".helm/artifacts/browser/\(filename)"
        let safeDestURL = try driftDetector.validateWorkspacePath(relPath, workspaceRoot: workspaceRoot)
        let parentURL = safeDestURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let verifiedURL = try driftDetector.validateWorkspacePath(relPath, workspaceRoot: workspaceRoot)
        guard verifiedURL.path == safeDestURL.path else {
            throw DriftViolation.workspaceEscape(candidatePath: relPath, workspaceRoot: workspaceRoot.path)
        }
        var parentStat = stat()
        guard lstat(parentURL.path, &parentStat) == 0,
              (parentStat.st_mode & S_IFMT) == S_IFDIR else {
            throw DriftViolation.workspaceEscape(candidatePath: relPath, workspaceRoot: workspaceRoot.path)
        }
        var leafStat = stat()
        if lstat(verifiedURL.path, &leafStat) == 0,
           (leafStat.st_mode & S_IFMT) == S_IFLNK {
            throw DriftViolation.workspaceEscape(candidatePath: relPath, workspaceRoot: workspaceRoot.path)
        }
        try data.write(to: verifiedURL, options: .atomic)
        return (verifiedURL, relPath)
    }

    private static func extractDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func mimeType(for path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "json": return "application/json"
        case "txt", "md", "log": return "text/plain"
        case "swift": return "text/x-swift"
        case "html", "htm": return "text/html"
        default: return "application/octet-stream"
        }
    }

    private func checkDiskBudget(project: Project) -> WorkerOutcome? {
        if let simMB = environment["HELM_SIMULATE_LOW_DISK_MB"],
           let mb = Int(simMB),
           mb < project.budgetPolicy.minFreeDiskMB {
            return .hold(
                kind: .budget,
                severity: .critical,
                title: "Low Disk Headroom Guard",
                summary: "Available disk \(mb) MB is below minimum \(project.budgetPolicy.minFreeDiskMB) MB.",
                options: ["retry", "abort"]
            )
        }
        let values = try? project.workspaceRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage {
            let availableMB = Int(available / (1024 * 1024))
            if availableMB < project.budgetPolicy.minFreeDiskMB {
                return .hold(
                    kind: .budget,
                    severity: .critical,
                    title: "Low Disk Headroom Guard",
                    summary: "Available disk \(availableMB) MB is below minimum \(project.budgetPolicy.minFreeDiskMB) MB.",
                    options: ["retry", "abort"]
                )
            }
        }
        return nil
    }

    private func parseArgsDict(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }
}
