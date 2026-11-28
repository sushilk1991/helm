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
        await executeAttempt(
            project: project,
            agent: agent,
            task: task,
            stepIndex: stepIndex,
            maxTurns: 12,
            allowHumanDecisionTool: false,
            effectiveCapabilitiesOverride: nil
        )
    }

    public func executeAttempt(
        project: Project,
        agent: AgentProfile,
        task: DelegatedTask,
        stepIndex: Int,
        maxTurns: Int,
        allowHumanDecisionTool: Bool = false,
        effectiveCapabilitiesOverride: Set<AgentCapability>? = nil
    ) async -> WorkerOutcome {
        let effectiveCaps = effectiveCapabilitiesOverride ?? agent.capabilities
        let boundedMaxTurns = max(1, maxTurns)

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
                await recordWorkEntry(
                    projectID: project.id,
                    agent: agent,
                    task: task,
                    stepNumber: 0,
                    phase: .failed,
                    summary: "Blocked untrusted shared-state rule tamper: \(error.localizedDescription)"
                )
                return .hold(
                    kind: .drift,
                    severity: .critical,
                    title: "Untrusted Shared-State Rule Tamper Blocked",
                    summary: error.localizedDescription,
                    options: ["redirect", "abort"]
                )
            }
        }

        let provider: any LLMProvider
        do {
            provider = try providerRegistry.provider(for: agent.backend)
        } catch {
            await recordWorkEntry(
                projectID: project.id,
                agent: agent,
                task: task,
                stepNumber: 0,
                phase: .failed,
                summary: "LLM provider unavailable: \(error.localizedDescription)"
            )
            return .hold(
                kind: .providerFailure,
                severity: .critical,
                title: "LLM Provider Unavailable",
                summary: error.localizedDescription,
                options: ["retry", "redirect", "abort"]
            )
        }

        // 3. Build system prompt from editable agent.systemPrompt + runtime autonomy directives
        let personalityLine = agent.personalityNotes.isEmpty
            ? "\(agent.personality.displayName): \(agent.personality.promptDirective)"
            : "\(agent.personality.displayName): \(agent.personality.promptDirective) Custom traits: \(agent.personalityNotes)"

        let baseAgentPrompt = agent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBasePrompt = baseAgentPrompt.isEmpty
            ? AgentProfile.buildSystemPromptTemplate(
                role: agent.role,
                personality: agent.personality,
                goal: agent.goal,
                notes: agent.personalityNotes
            )
            : baseAgentPrompt

        let systemPrompt = """
        \(resolvedBasePrompt)

        [Runtime Workspace & Autonomy Directives]
        - Project: \(project.name)
        - Attached Workspace Folder: \(project.workspaceRoot.path)
        - Trust Policy: \(project.sandboxTrustPolicy.rawValue)
        - Workspace-First Discovery: Inspect the attached workspace directly using list_workspace_files, search_workspace, and read_workspace_file before making assumptions.
        - Autonomous Completion: Execute steps iteratively using tool outputs until the objective is finished, then call complete_task with a clear summary. Do not stall waiting for routine path, file, or URL clarifications that you can discover from the workspace or shared memory.
        """

        // Only advertise capability-appropriate tools; never advertise ask_human unless allowHumanDecisionTool is true.
        var tools: [LLMToolSchema] = [
            LLMToolSchema(
                name: "complete_task",
                description: "Complete the task and optionally propose shared-state output.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"summary\":{\"type\":\"string\"},\"shared_key\":{\"type\":\"string\"},\"shared_title\":{\"type\":\"string\"},\"shared_value\":{\"type\":\"string\"}}}"
            ),
            LLMToolSchema(
                name: "list_workspace_files",
                description: "List files and directories inside the attached project workspace.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"max_entries\":{\"type\":\"integer\"},\"include_hidden\":{\"type\":\"boolean\"}}}"
            ),
            LLMToolSchema(
                name: "read_workspace_file",
                description: "Read a UTF-8 text file inside the attached project workspace with optional line range.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"offset_lines\":{\"type\":\"integer\"},\"max_lines\":{\"type\":\"integer\"}}}"
            ),
            LLMToolSchema(
                name: "search_workspace",
                description: "Search text files inside the attached project workspace for a query string.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"},\"max_results\":{\"type\":\"integer\"},\"case_sensitive\":{\"type\":\"boolean\"}}}"
            ),
            LLMToolSchema(
                name: "write_workspace_file",
                description: "Write a relative file inside the project workspace.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}}}"
            ),
        ]
        if effectiveCaps.contains(.codeExec) || project.sandboxTrustPolicy != .sandboxed {
            tools.append(LLMToolSchema(
                name: "run_command",
                description: "Execute a shell command inside the project workspace.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}"
            ))
        }
        if effectiveCaps.contains(.browser) || project.sandboxTrustPolicy != .sandboxed {
            tools.append(LLMToolSchema(
                name: "browser_act",
                description: "Navigate or interact with a headless web page using Vision OCR and CDP.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"},\"action\":{\"type\":\"string\",\"enum\":[\"navigate\",\"observe\",\"open\",\"read\",\"click_ocr\",\"click_css\",\"type_text\",\"eval_js\"]},\"target\":{\"type\":\"string\"},\"query\":{\"type\":\"string\"},\"x\":{\"type\":\"number\"},\"y\":{\"type\":\"number\"},\"text\":{\"type\":\"string\"},\"submit\":{\"type\":\"boolean\"},\"script\":{\"type\":\"string\"}}}"
            ))
        }
        if effectiveCaps.contains(.proposeSharedState) {
            tools.append(LLMToolSchema(
                name: "propose_shared_memory",
                description: "Write a fact or observation to shared memory.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"},\"category\":{\"type\":\"string\"}}}"
            ))
        }
        if allowHumanDecisionTool {
            tools.append(LLMToolSchema(
                name: "ask_human",
                description: "Pause and ask the human operator for a decision.",
                parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\"},\"options\":{\"type\":\"array\"}}}"
            ))
        }

        await recordWorkEntry(
            projectID: project.id,
            agent: agent,
            task: task,
            stepNumber: 0,
            phase: .planning,
            summary: "Planning '\(task.title)' in workspace \(project.workspaceRoot.lastPathComponent)"
        )

        var accumulatedSharedWrites: [(key: String, title: String, value: String)] = []
        var accumulatedArtifacts: [String] = []
        var finalSummary = "Task '\(task.title)' completed by \(agent.name)."
        var activeBrowserSessionID: UUID? = nil
        var turnTranscript = ""
        var recentSignatures: [String] = []

        func closeActiveBrowserSession() async {
            if let sid = activeBrowserSessionID {
                activeBrowserSessionID = nil
                await browserService?.closeSession(sid)
            }
        }

        var turn = 0
        while turn < boundedMaxTurns {
            if Task.isCancelled {
                await closeActiveBrowserSession()
                return .retryableError(
                    toolName: "cancelled",
                    argumentsJSON: "{}",
                    message: "Agent '\(agent.name)' execution was cancelled."
                )
            }

            try? await database.updateAgentState(id: agent.id, state: .thinking)

            // Assemble 4 SHA-256 digest-tracked prompt channels with forceFullContext: true for stateless LLMs
            let rankedMemory = try? await sharedStateStore.rankAndPackMemory(
                projectID: project.id,
                agentID: agent.id,
                query: "\(task.title) \(task.instructions) \(project.goal)",
                charBudget: project.budgetPolicy.memoryCharBudget
            )

            let rawChannels: [PromptChannel: String] = [
                .identity: "Agent: \(agent.name)\nRole: \(agent.role.rawValue)\nPersonality: \(personalityLine)\nGoal: \(agent.goal)\nCapabilities: \(effectiveCaps.map(\.rawValue).sorted().joined(separator: ", "))",
                .projectContext: "Project: \(project.name)\nGoal: \(project.goal)\nWorkspace: \(project.workspaceRoot.path)\nTrustPolicy: \(project.sandboxTrustPolicy.rawValue)",
                .sharedMemory: rankedMemory?.packedText ?? "",
                .continuity: "Task: \(task.title)\nAttempt: \(task.attemptCount + 1)/\(task.maxAttempts)\nTurn: \(turn + 1)/\(boundedMaxTurns)\nInstructions: \(task.instructions)",
            ]

            let slices = (try? await sharedStateStore.preparePromptChannels(
                projectID: project.id,
                agentID: agent.id,
                rawChannels: rawChannels,
                forceFullContext: true
            )) ?? []

            var digests: [String: String] = [:]
            var contextParts: [String] = []
            for slice in slices {
                digests[slice.channel.rawValue] = slice.sha256Digest
                if let content = slice.content, !content.isEmpty {
                    contextParts.append("[\(slice.channel.rawValue)]\n\(content)")
                }
            }

            var userPrompt = "TASK_EXECUTION\nTaskID: \(task.id.uuidString)\n" + contextParts.joined(separator: "\n\n")
            if !turnTranscript.isEmpty {
                let boundedHistory = Self.boundFromTail(turnTranscript, maxChars: 24_000)
                userPrompt += "\n\n[Execution Transcript]\n\(boundedHistory)"
            }

            let request = LLMRequest(
                agentID: agent.id,
                projectID: project.id,
                stepIndex: stepIndex + turn,
                systemPrompt: systemPrompt,
                digestChannels: digests,
                userPrompt: userPrompt,
                tools: tools,
                model: agent.modelOverride,
                timeoutSeconds: project.budgetPolicy.stepTimeoutSeconds,
                workingDirectory: project.workspaceRoot
            )

            // Execute LLM call raced against stepTimeoutSeconds
            let startedAt = Date()
            let response: LLMResponse
            do {
                response = try await LLMTimeoutRace.completeWithTimeout(
                    provider: provider,
                    request: request,
                    timeoutSeconds: project.budgetPolicy.stepTimeoutSeconds
                )
            } catch is CancellationError {
                await closeActiveBrowserSession()
                return .retryableError(
                    toolName: "cancelled",
                    argumentsJSON: "{}",
                    message: "Agent '\(agent.name)' step was cancelled."
                )
            } catch let err as LLMProviderError {
                await closeActiveBrowserSession()
                if case .timeout(let sec) = err {
                    await recordWorkEntry(
                        projectID: project.id,
                        agent: agent,
                        task: task,
                        stepNumber: turn * 10,
                        phase: .failed,
                        summary: "Agent step timed out after \(Int(sec))s"
                    )
                    return .hold(
                        kind: .stall,
                        severity: .critical,
                        title: "Agent Step Timed Out",
                        summary: "Agent '\(agent.name)' exceeded step timeout (\(Int(sec))s) on '\(task.title)'.",
                        options: ["retry", "redirect", "abort"]
                    )
                }
                let errMsg = err.localizedDescription
                await recordWorkEntry(
                    projectID: project.id,
                    agent: agent,
                    task: task,
                    stepNumber: turn * 10,
                    phase: .failed,
                    summary: "LLM provider failed: \(errMsg)"
                )
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
                await closeActiveBrowserSession()
                let errMsg = error.localizedDescription
                await recordWorkEntry(
                    projectID: project.id,
                    agent: agent,
                    task: task,
                    stepNumber: turn * 10,
                    phase: .failed,
                    summary: "LLM provider failed: \(errMsg)"
                )
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
                await closeActiveBrowserSession()
                await recordWorkEntry(
                    projectID: project.id,
                    agent: agent,
                    task: task,
                    stepNumber: turn * 10,
                    phase: .failed,
                    summary: "Step duration \(String(format: "%.2f", elapsed))s exceeded budget"
                )
                return .hold(
                    kind: .stall,
                    severity: .critical,
                    title: "Agent Step Timed Out",
                    summary: "Step duration \(String(format: "%.2f", elapsed))s exceeded budget.",
                    options: ["retry", "abort"]
                )
            }

            // Parse structured tool envelope
            let parsed = LLMToolPromptCodec.parseEnvelope(from: response.text)
            if let thought = parsed.thought?.trimmingCharacters(in: .whitespacesAndNewlines),
               !thought.isEmpty {
                await recordWorkEntry(
                    projectID: project.id,
                    agent: agent,
                    task: task,
                    stepNumber: turn * 10,
                    phase: .reasoning,
                    summary: thought
                )
            }
            let toolCalls = response.toolCalls.isEmpty ? parsed.toolCalls : response.toolCalls

            if toolCalls.isEmpty {
                if response.stopReason == "error_recoverable" || parsed.finalResponse == nil {
                    await closeActiveBrowserSession()
                    let msg = "Malformed or empty JSON action envelope from agent '\(agent.name)'"
                    await recordWorkEntry(
                        projectID: project.id,
                        agent: agent,
                        task: task,
                        stepNumber: turn * 10 + 1,
                        phase: .failed,
                        summary: msg
                    )
                    return .retryableError(
                        toolName: "llm_json_contract",
                        argumentsJSON: "{}",
                        message: msg
                    )
                }
                let trimmed = (parsed.finalResponse ?? response.text).trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") && (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) == nil {
                    await closeActiveBrowserSession()
                    let msg = "Unparseable JSON response from agent '\(agent.name)'"
                    await recordWorkEntry(
                        projectID: project.id,
                        agent: agent,
                        task: task,
                        stepNumber: turn * 10 + 1,
                        phase: .failed,
                        summary: msg
                    )
                    return .retryableError(
                        toolName: "llm_json_contract",
                        argumentsJSON: "{}",
                        message: msg
                    )
                }
                await closeActiveBrowserSession()
                await stallDetector.recordToolSuccess(agentID: agent.id)
                await recordWorkEntry(
                    projectID: project.id,
                    agent: agent,
                    task: task,
                    stepNumber: turn * 10 + 1,
                    phase: .completed,
                    summary: trimmed.isEmpty ? finalSummary : trimmed,
                    artifactPaths: accumulatedArtifacts
                )
                return .completed(
                    summary: trimmed.isEmpty ? finalSummary : trimmed,
                    sharedWrites: accumulatedSharedWrites,
                    artifactPaths: accumulatedArtifacts
                )
            }

            // Loop-progress guard for identical and periodic (2-step / 3-step) repeated non-completing tool call cycles
            let nonCompletingCalls = toolCalls.filter { $0.name != "complete_task" }
            let completingCalls = toolCalls.filter { $0.name == "complete_task" }
            if completingCalls.isEmpty {
                let turnSignature = nonCompletingCalls
                    .map { "\($0.name)|\(Self.canonicalArgsSignature($0.argumentsJSON))" }
                    .joined(separator: ";")
                recentSignatures.append(turnSignature)
                let repeatThreshold = max(3, project.budgetPolicy.maxConsecutiveToolFailures)
                let maxKeep = max(repeatThreshold, 9)
                if recentSignatures.count > maxKeep {
                    recentSignatures.removeFirst(recentSignatures.count - maxKeep)
                }

                var detectedCyclePeriod: Int? = nil
                for period in 1...3 {
                    let reps = (period == 1) ? repeatThreshold : 3
                    let window = period * reps
                    if recentSignatures.count >= window {
                        let slice = Array(recentSignatures.suffix(window))
                        let pattern = Array(slice.prefix(period))
                        var allMatch = true
                        for rep in 1..<reps {
                            let start = rep * period
                            if Array(slice[start..<(start + period)]) != pattern {
                                allMatch = false
                                break
                            }
                        }
                        if allMatch {
                            detectedCyclePeriod = period
                            break
                        }
                    }
                }

                if let period = detectedCyclePeriod {
                    await closeActiveBrowserSession()
                    let firstName = nonCompletingCalls.first?.name ?? "tool"
                    let msg = period == 1
                        ? "Agent '\(agent.name)' repeated identical tool call '\(firstName)' \(repeatThreshold) times without making progress."
                        : "Agent '\(agent.name)' entered a repeating \(period)-step tool call cycle without making progress."
                    await recordWorkEntry(
                        projectID: project.id,
                        agent: agent,
                        task: task,
                        stepNumber: turn * 10 + 1,
                        phase: .failed,
                        summary: msg,
                        toolName: firstName
                    )
                    return .hold(
                        kind: .loop,
                        severity: .critical,
                        title: "Repeated Tool Call Loop Detected",
                        summary: msg,
                        options: ["retry", "redirect", "abort"]
                    )
                }
            } else {
                recentSignatures.removeAll()
            }

            if let parsedFinal = parsed.finalResponse?.trimmingCharacters(in: .whitespacesAndNewlines),
               !parsedFinal.isEmpty {
                finalSummary = parsedFinal
            }

            var didCompleteTask = false
            var anyToolFailedThisTurn = false
            var turnTranscriptLines: [String] = []

            for (callIndex, call) in nonCompletingCalls.enumerated() {
                if Task.isCancelled {
                    await closeActiveBrowserSession()
                    return .retryableError(
                        toolName: "cancelled",
                        argumentsJSON: "{}",
                        message: "Agent '\(agent.name)' execution was cancelled."
                    )
                }
                let args = parseArgsDict(call.argumentsJSON)
                let workStep = turn * 10 + callIndex + 1

                switch call.name {
                case "ask_human", "request_human_decision":
                    if allowHumanDecisionTool {
                        await closeActiveBrowserSession()
                        let question = (args["question"] as? String) ?? "Human decision required for '\(task.title)'"
                        let options = (args["options"] as? [String]) ?? ["approve", "redirect", "abort"]
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .failed,
                            summary: "Human decision requested: \(question)",
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON
                        )
                        return .hold(
                            kind: .humanDecision,
                            severity: .attention,
                            title: "Human Decision Required",
                            summary: question,
                            options: options
                        )
                    } else {
                        let msg = "Tool 'ask_human' is disabled for autonomous execution. Use workspace discovery/read/write/command/browser tools and finish with complete_task."
                        let check = await stallDetector.recordToolFailure(
                            agentID: agent.id,
                            toolName: call.name,
                            argumentsJSON: call.argumentsJSON,
                            errorMessage: msg,
                            policy: project.budgetPolicy
                        )
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .failed,
                            summary: msg,
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: msg
                        )
                        if check.triggeredKind == .loop {
                            await closeActiveBrowserSession()
                            return .hold(
                                kind: .loop,
                                severity: .critical,
                                title: "Repeated Disallowed Tool Loop Detected",
                                summary: msg,
                                options: ["retry", "redirect", "abort"]
                            )
                        }
                        anyToolFailedThisTurn = true
                        turnTranscriptLines.append("\(call.name) -> ERROR: \(msg)")
                    }

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
                    await recordWorkEntry(
                        projectID: project.id,
                        agent: agent,
                        task: task,
                        stepNumber: workStep,
                        phase: .failed,
                        summary: "Tool '\(call.name)' failed: \(errMsg)",
                        toolName: call.name,
                        toolInputSummary: call.argumentsJSON,
                        toolOutputSummary: errMsg
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

                case "list_workspace_files":
                    try? await database.updateAgentState(id: agent.id, state: .executing)
                    let relTarget = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let maxEntries = min(500, max(1, Self.extractInt(args["max_entries"]) ?? 200))
                    let includeHidden = (args["include_hidden"] as? Bool) ?? false
                    do {
                        let listing = try listWorkspaceFiles(
                            workspaceRoot: project.workspaceRoot,
                            relativePath: relTarget,
                            maxEntries: maxEntries,
                            includeHidden: includeHidden
                        )
                        await stallDetector.recordToolSuccess(agentID: agent.id)
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .toolCall,
                            summary: "Listed workspace files (\(listing.count) entries)",
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: listing.output
                        )
                        turnTranscriptLines.append("list_workspace_files(\(relTarget.isEmpty ? "." : relTarget)) ->\n\(listing.output)")
                    } catch {
                        let errMsg = error.localizedDescription
                        let check = await stallDetector.recordToolFailure(
                            agentID: agent.id,
                            toolName: call.name,
                            argumentsJSON: call.argumentsJSON,
                            errorMessage: errMsg,
                            policy: project.budgetPolicy
                        )
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .failed,
                            summary: "list_workspace_files error: \(errMsg)",
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: errMsg
                        )
                        if check.triggeredKind == .loop {
                            await closeActiveBrowserSession()
                            return .hold(kind: .loop, severity: .critical, title: "Workspace Discovery Failure Loop", summary: errMsg, options: ["retry", "redirect", "abort"])
                        }
                        anyToolFailedThisTurn = true
                        turnTranscriptLines.append("list_workspace_files(\(relTarget)) -> ERROR: \(errMsg)")
                    }

                case "read_workspace_file":
                    try? await database.updateAgentState(id: agent.id, state: .executing)
                    let candidate = (args["path"] as? String) ?? ""
                    let offsetLines = max(1, Self.extractInt(args["offset_lines"]) ?? 1)
                    let maxLines = min(500, max(1, Self.extractInt(args["max_lines"]) ?? 200))
                    do {
                        let readRes = try readWorkspaceFile(
                            workspaceRoot: project.workspaceRoot,
                            candidatePath: candidate,
                            offsetLines: offsetLines,
                            maxLines: maxLines
                        )
                        await stallDetector.recordToolSuccess(agentID: agent.id)
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .toolCall,
                            summary: "Read '\(readRes.canonicalRelPath)'",
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: readRes.output,
                            touchedFiles: [readRes.canonicalRelPath]
                        )
                        turnTranscriptLines.append("read_workspace_file(\(readRes.canonicalRelPath)) ->\n\(readRes.output)")
                    } catch {
                        let errMsg = error.localizedDescription
                        let check = await stallDetector.recordToolFailure(
                            agentID: agent.id,
                            toolName: call.name,
                            argumentsJSON: call.argumentsJSON,
                            errorMessage: errMsg,
                            policy: project.budgetPolicy
                        )
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .failed,
                            summary: "Blocked/failed reading '\(candidate)': \(errMsg)",
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: errMsg
                        )
                        if check.triggeredKind == .loop {
                            await closeActiveBrowserSession()
                            return .hold(kind: .loop, severity: .critical, title: "Workspace Read Failure Loop", summary: errMsg, options: ["retry", "redirect", "abort"])
                        }
                        anyToolFailedThisTurn = true
                        turnTranscriptLines.append("read_workspace_file(\(candidate)) -> ERROR: \(errMsg)")
                    }

                case "search_workspace":
                    try? await database.updateAgentState(id: agent.id, state: .executing)
                    let query = (args["query"] as? String) ?? ""
                    let relTarget = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let maxResults = min(200, max(1, Self.extractInt(args["max_results"]) ?? 50))
                    let caseSensitive = (args["case_sensitive"] as? Bool) ?? false
                    do {
                        let searchRes = try searchWorkspace(
                            workspaceRoot: project.workspaceRoot,
                            query: query,
                            relativePath: relTarget,
                            maxResults: maxResults,
                            caseSensitive: caseSensitive
                        )
                        await stallDetector.recordToolSuccess(agentID: agent.id)
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .toolCall,
                            summary: "Searched workspace for '\(query)' (\(searchRes.matchCount) matches)",
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: searchRes.output
                        )
                        turnTranscriptLines.append("search_workspace(\(query)) ->\n\(searchRes.output)")
                    } catch {
                        let errMsg = error.localizedDescription
                        let check = await stallDetector.recordToolFailure(
                            agentID: agent.id,
                            toolName: call.name,
                            argumentsJSON: call.argumentsJSON,
                            errorMessage: errMsg,
                            policy: project.budgetPolicy
                        )
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .failed,
                            summary: "search_workspace error: \(errMsg)",
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: errMsg
                        )
                        if check.triggeredKind == .loop {
                            await closeActiveBrowserSession()
                            return .hold(kind: .loop, severity: .critical, title: "Workspace Search Failure Loop", summary: errMsg, options: ["retry", "redirect", "abort"])
                        }
                        anyToolFailedThisTurn = true
                        turnTranscriptLines.append("search_workspace(\(query)) -> ERROR: \(errMsg)")
                    }

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
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .failed,
                            summary: "Workspace boundary drift on write '\(candidate)': \(error.localizedDescription)",
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: error.localizedDescription
                        )
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
                        let rootPrefix = canonicalRoot == "/" ? "/" : canonicalRoot + "/"
                        let canonicalRelPath = verifiedURL.path.hasPrefix(rootPrefix)
                            ? String(verifiedURL.path.dropFirst(rootPrefix.count))
                            : verifiedURL.lastPathComponent
                        accumulatedArtifacts.append(canonicalRelPath)
                        let fileHash = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
                        let artifact = ArtifactRecord(
                            projectID: project.id,
                            agentID: agent.id,
                            taskID: task.id,
                            kind: "workspace_file",
                            relativePath: canonicalRelPath,
                            mimeType: Self.mimeType(for: canonicalRelPath),
                            byteSize: Int64(fileData.count),
                            sha256: fileHash
                        )
                        try? await database.insertArtifact(artifact)
                        await stallDetector.recordToolSuccess(agentID: agent.id)
                        let outSummary = "Wrote \(fileData.count) bytes to '\(canonicalRelPath)'"
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .fileEdit,
                            summary: outSummary,
                            toolName: call.name,
                            toolInputSummary: "path=\(canonicalRelPath) (\(fileData.count) bytes)",
                            toolOutputSummary: outSummary,
                            touchedFiles: [canonicalRelPath],
                            artifactPaths: [canonicalRelPath]
                        )
                        turnTranscriptLines.append("write_workspace_file(\(canonicalRelPath)) -> \(outSummary)")
                    } catch let driftErr as DriftViolation {
                        await closeActiveBrowserSession()
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .failed,
                            summary: "Workspace boundary drift: \(driftErr.localizedDescription)",
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: driftErr.localizedDescription
                        )
                        return .hold(
                            kind: .drift,
                            severity: .critical,
                            title: "Workspace Boundary Drift Detected",
                            summary: driftErr.localizedDescription,
                            options: ["redirect", "abort"]
                        )
                    } catch {
                        let errMsg = error.localizedDescription
                        let check = await stallDetector.recordToolFailure(
                            agentID: agent.id,
                            toolName: call.name,
                            argumentsJSON: call.argumentsJSON,
                            errorMessage: errMsg,
                            policy: project.budgetPolicy
                        )
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .failed,
                            summary: "File write error on '\(candidate)': \(errMsg)",
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: errMsg
                        )
                        if check.triggeredKind == .loop {
                            await closeActiveBrowserSession()
                            return .hold(
                                kind: .loop,
                                severity: .critical,
                                title: "Repeated File Write Failure Loop",
                                summary: errMsg,
                                options: ["retry", "abort"]
                            )
                        }
                        anyToolFailedThisTurn = true
                        turnTranscriptLines.append("write_workspace_file(\(candidate)) -> ERROR: \(errMsg)")
                    }

                case "run_command":
                    guard effectiveCaps.contains(.codeExec) || project.sandboxTrustPolicy != .sandboxed else {
                        await closeActiveBrowserSession()
                        let msg = "Agent '\(agent.name)' attempted 'run_command' without 'codeExec' capability under sandboxed policy."
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .failed,
                            summary: msg,
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: msg
                        )
                        return .hold(
                            kind: .drift,
                            severity: .critical,
                            title: "Unauthorized Capability Request",
                            summary: msg,
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
                            preferredMode: project.sandboxTrustPolicy == .sandboxed ? .seatbeltSandbox : nil,
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
                                await recordWorkEntry(
                                    projectID: project.id,
                                    agent: agent,
                                    task: task,
                                    stepNumber: workStep,
                                    phase: .failed,
                                    summary: "Command failed (exit=\(res.exitCode), timedOut=\(res.timedOut)): \(cmd)",
                                    toolName: call.name,
                                    toolInputSummary: cmd,
                                    toolOutputSummary: msg
                                )
                                if check.triggeredKind == .loop {
                                    await closeActiveBrowserSession()
                                    return .hold(kind: .loop, severity: .critical, title: "Sandbox Failure Loop", summary: msg, options: ["retry", "abort"])
                                }
                                anyToolFailedThisTurn = true
                                let combinedOut = [res.stdout, res.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                                turnTranscriptLines.append("run_command('\(cmd)') -> FAILED (exit=\(res.exitCode), timedOut=\(res.timedOut))\n\(Self.boundFromHead(combinedOut, maxChars: 6_000))")
                            } else {
                                await stallDetector.recordToolSuccess(agentID: agent.id)
                                let outText = res.stdout.isEmpty ? "Command '\(cmd)' exited 0." : res.stdout
                                finalSummary = outText
                                await recordWorkEntry(
                                    projectID: project.id,
                                    agent: agent,
                                    task: task,
                                    stepNumber: workStep,
                                    phase: .toolCall,
                                    summary: "Executed command (exit 0): \(cmd)",
                                    toolName: call.name,
                                    toolInputSummary: cmd,
                                    toolOutputSummary: outText
                                )
                                turnTranscriptLines.append("run_command('\(cmd)') -> exit 0\n\(Self.boundFromHead(outText, maxChars: 6_000))")
                            }
                        } catch {
                            let errMsg = error.localizedDescription
                            let check = await stallDetector.recordToolFailure(
                                agentID: agent.id,
                                toolName: call.name,
                                argumentsJSON: call.argumentsJSON,
                                errorMessage: errMsg,
                                policy: project.budgetPolicy
                            )
                            await recordWorkEntry(
                                projectID: project.id,
                                agent: agent,
                                task: task,
                                stepNumber: workStep,
                                phase: .failed,
                                summary: "Command execution error: \(errMsg)",
                                toolName: call.name,
                                toolInputSummary: cmd,
                                toolOutputSummary: errMsg
                            )
                            if check.triggeredKind == .loop {
                                await closeActiveBrowserSession()
                                return .hold(kind: .loop, severity: .critical, title: "Sandbox Error Loop", summary: errMsg, options: ["retry", "abort"])
                            }
                            anyToolFailedThisTurn = true
                            turnTranscriptLines.append("run_command('\(cmd)') -> ERROR: \(errMsg)")
                        }
                    } else {
                        let msg = "SandboxExecutor not wired"
                        let check = await stallDetector.recordToolFailure(
                            agentID: agent.id,
                            toolName: call.name,
                            argumentsJSON: call.argumentsJSON,
                            errorMessage: msg,
                            policy: project.budgetPolicy
                        )
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .failed,
                            summary: msg,
                            toolName: call.name,
                            toolInputSummary: cmd,
                            toolOutputSummary: msg
                        )
                        if check.triggeredKind == .loop {
                            await closeActiveBrowserSession()
                            return .hold(kind: .loop, severity: .critical, title: "Sandbox Unavailable Loop", summary: msg, options: ["retry", "abort"])
                        }
                        anyToolFailedThisTurn = true
                        turnTranscriptLines.append("run_command('\(cmd)') -> ERROR: \(msg)")
                    }

                case "browser_act":
                    guard effectiveCaps.contains(.browser) || project.sandboxTrustPolicy != .sandboxed else {
                        await closeActiveBrowserSession()
                        let msg = "Agent '\(agent.name)' attempted 'browser_act' without 'browser' capability under sandboxed policy."
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .failed,
                            summary: msg,
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: msg
                        )
                        return .hold(
                            kind: .drift,
                            severity: .critical,
                            title: "Unauthorized Capability Request",
                            summary: msg,
                            options: ["redirect", "abort"]
                        )
                    }
                    guard let browserService else {
                        let msg = "BrowserOCRService not wired"
                        let check = await stallDetector.recordToolFailure(
                            agentID: agent.id,
                            toolName: call.name,
                            argumentsJSON: call.argumentsJSON,
                            errorMessage: msg,
                            policy: project.budgetPolicy
                        )
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .failed,
                            summary: msg,
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: msg
                        )
                        if check.triggeredKind == .loop {
                            await closeActiveBrowserSession()
                            return .hold(kind: .loop, severity: .critical, title: "Browser Unavailable Loop", summary: msg, options: ["retry", "abort"])
                        }
                        anyToolFailedThisTurn = true
                        turnTranscriptLines.append("browser_act -> ERROR: \(msg)")
                        break
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
                        let isNavigateAlias = (actionKind == "navigate" || actionKind == "observe" || actionKind == "open" || actionKind == "read")

                        if !isNavigateAlias, let urlArg, !urlArg.isEmpty {
                            _ = try await browserService.perform(
                                .navigate(url: urlArg),
                                sessionID: sessionID,
                                timeoutSeconds: project.budgetPolicy.stepTimeoutSeconds
                            )
                        }

                        let browserAction: BrowserAction
                        switch actionKind {
                        case "navigate", "observe", "open", "read":
                            let targetURL = urlArg ?? ""
                            guard !targetURL.isEmpty else {
                                throw NSError(domain: "AgentWorkerRunner", code: 2, userInfo: [NSLocalizedDescriptionKey: "browser_act \(actionKind) requires non-empty 'url'"])
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
                            key: "obs.browser.\(task.id.uuidString.prefix(8)).\(stepIndex + turn).\(callIndex)",
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
                        accumulatedArtifacts.append(relPath)

                        let obsSummary: String
                        if !ocrPreview.isEmpty {
                            obsSummary = "Browser observed \(observation.url): \(ocrPreview.replacingOccurrences(of: "\n", with: " | "))"
                        } else {
                            obsSummary = "Browser observed \(observation.url) (\(observation.title))"
                        }
                        finalSummary = obsSummary

                        await stallDetector.recordToolSuccess(agentID: agent.id)
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .toolCall,
                            summary: "Browser \(actionKind) -> \(observation.url)",
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: obsContent,
                            artifactPaths: [relPath]
                        )
                        turnTranscriptLines.append("browser_act(\(actionKind)) ->\n\(obsContent)")
                        try? await database.updateAgentState(id: agent.id, state: .thinking)
                    } catch is CancellationError {
                        try? await database.updateAgentState(id: agent.id, state: .thinking)
                        await closeActiveBrowserSession()
                        return .retryableError(toolName: call.name, argumentsJSON: call.argumentsJSON, message: "browser_act cancelled")
                    } catch {
                        try? await database.updateAgentState(id: agent.id, state: .thinking)
                        let msg = error.localizedDescription
                        let check = await stallDetector.recordToolFailure(
                            agentID: agent.id,
                            toolName: call.name,
                            argumentsJSON: call.argumentsJSON,
                            errorMessage: msg,
                            policy: project.budgetPolicy
                        )
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .failed,
                            summary: "Browser action failed: \(msg)",
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: msg
                        )
                        if check.triggeredKind == .loop {
                            await closeActiveBrowserSession()
                            return .hold(kind: .loop, severity: .critical, title: "Browser Action Failure Loop", summary: msg, options: ["retry", "abort"])
                        }
                        anyToolFailedThisTurn = true
                        turnTranscriptLines.append("browser_act -> ERROR: \(msg)")
                    }

                case "propose_shared_memory", "propose_shared_state":
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
                        await stallDetector.recordToolSuccess(agentID: agent.id)
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .toolCall,
                            summary: "Stored shared memory '\(key)'",
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: "Saved \(category.rawValue) '\(key)'"
                        )
                        turnTranscriptLines.append("\(call.name)('\(key)') -> stored")
                    } catch {
                        await closeActiveBrowserSession()
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: workStep,
                            phase: .failed,
                            summary: "Protected shared-state write rejected: \(error.localizedDescription)",
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: error.localizedDescription
                        )
                        return .hold(
                            kind: .drift,
                            severity: .critical,
                            title: "Protected Shared-State Write Rejected",
                            summary: error.localizedDescription,
                            options: ["redirect", "abort"]
                        )
                    }

                default:
                    let msg = "Unknown tool '\(call.name)'. Use available workspace/command/browser tools or call complete_task."
                    await recordWorkEntry(
                        projectID: project.id,
                        agent: agent,
                        task: task,
                        stepNumber: workStep,
                        phase: .failed,
                        summary: msg,
                        toolName: call.name,
                        toolInputSummary: call.argumentsJSON,
                        toolOutputSummary: msg
                    )
                    anyToolFailedThisTurn = true
                    turnTranscriptLines.append("\(call.name) -> ERROR: \(msg)")
                }
            }

            if !completingCalls.isEmpty {
                let completeStep = turn * 10 + nonCompletingCalls.count + 1
                if anyToolFailedThisTurn {
                    let rejectMsg = "Rejected complete_task because another tool call in the same turn failed. Resolve the failure before completing."
                    await recordWorkEntry(
                        projectID: project.id,
                        agent: agent,
                        task: task,
                        stepNumber: completeStep,
                        phase: .failed,
                        summary: rejectMsg,
                        toolName: "complete_task",
                        toolInputSummary: completingCalls.last?.argumentsJSON,
                        toolOutputSummary: rejectMsg
                    )
                    turnTranscriptLines.append("complete_task -> ERROR: \(rejectMsg)")
                } else {
                    for (idx, call) in completingCalls.enumerated() {
                        let args = parseArgsDict(call.argumentsJSON)
                        if let summary = args["summary"] as? String, !summary.isEmpty {
                            finalSummary = summary
                        }
                        if let key = args["shared_key"] as? String,
                           let val = args["shared_value"] as? String,
                           !key.isEmpty {
                            let title = (args["shared_title"] as? String) ?? key
                            accumulatedSharedWrites.append((key: key, title: title, value: val))
                        }
                        didCompleteTask = true
                        await recordWorkEntry(
                            projectID: project.id,
                            agent: agent,
                            task: task,
                            stepNumber: completeStep + idx,
                            phase: .completed,
                            summary: finalSummary,
                            toolName: call.name,
                            toolInputSummary: call.argumentsJSON,
                            toolOutputSummary: finalSummary,
                            artifactPaths: accumulatedArtifacts
                        )
                    }
                }
            }

            if didCompleteTask {
                await closeActiveBrowserSession()
                await stallDetector.recordToolSuccess(agentID: agent.id)
                return .completed(
                    summary: finalSummary,
                    sharedWrites: accumulatedSharedWrites,
                    artifactPaths: accumulatedArtifacts
                )
            }

            if !turnTranscriptLines.isEmpty {
                turnTranscript += (turnTranscript.isEmpty ? "" : "\n\n") + "--- Turn \(turn + 1) ---\n" + turnTranscriptLines.joined(separator: "\n")
            }
            turn += 1
        }

        await closeActiveBrowserSession()
        let budgetMsg = "Agent '\(agent.name)' reached maximum \(boundedMaxTurns) autonomous turns on '\(task.title)' without calling complete_task."
        await recordWorkEntry(
            projectID: project.id,
            agent: agent,
            task: task,
            stepNumber: boundedMaxTurns * 10,
            phase: .failed,
            summary: budgetMsg
        )
        return .hold(
            kind: .stall,
            severity: .critical,
            title: "Agent Turn Budget Reached",
            summary: budgetMsg,
            options: ["retry", "redirect", "abort"]
        )
    }

    // MARK: - Workspace Discovery & Read Helpers

    internal static func workspaceTopLevelSummary(workspaceRoot: URL, maxEntries: Int = 40) -> String {
        let fm = FileManager.default
        let drift = DriftDetector()
        guard let canonicalRoot = DriftDetector.canonicalPath(for: workspaceRoot),
              let items = try? fm.contentsOfDirectory(
                  at: URL(fileURLWithPath: canonicalRoot, isDirectory: true),
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return "(unavailable)"
        }
        var names: [String] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = item.lastPathComponent
            if name == ".git" || name == ".build" || name == ".helm" { continue }
            guard drift.isPathInsideWorkspace(item.path, workspaceRoot: workspaceRoot) else { continue }
            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey])
            let suffix = (vals?.isDirectory == true) ? "/" : ""
            names.append("\(name)\(suffix)")
            if names.count >= maxEntries { break }
        }
        return names.isEmpty ? "(empty workspace)" : names.joined(separator: "\n")
    }

    private func listWorkspaceFiles(
        workspaceRoot: URL,
        relativePath: String,
        maxEntries: Int,
        includeHidden: Bool
    ) throws -> (output: String, count: Int) {
        guard let canonicalRoot = DriftDetector.canonicalPath(for: workspaceRoot) else {
            throw DriftViolation.workspaceEscape(candidatePath: relativePath, workspaceRoot: workspaceRoot.path)
        }
        let targetURL: URL
        if relativePath.isEmpty || relativePath == "." {
            targetURL = URL(fileURLWithPath: canonicalRoot, isDirectory: true)
        } else {
            targetURL = try driftDetector.validateWorkspacePath(relativePath, workspaceRoot: workspaceRoot)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "AgentWorkerRunner", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Directory not found: '\(relativePath.isEmpty ? "." : relativePath)'",
            ])
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: targetURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: includeHidden ? [] : [.skipsHiddenFiles]
        ) else {
            return ("(empty)", 0)
        }

        let rootPrefix = canonicalRoot == "/" ? "/" : canonicalRoot + "/"
        var entries: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            if !includeHidden && (name == ".git" || name == ".build" || name == ".helm") {
                enumerator.skipDescendants()
                continue
            }
            var st = stat()
            if lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK {
                if !driftDetector.isPathInsideWorkspace(url.path, workspaceRoot: workspaceRoot) {
                    enumerator.skipDescendants()
                    continue
                }
            }
            guard let resolved = DriftDetector.canonicalPath(for: url),
                  resolved == canonicalRoot || resolved.hasPrefix(rootPrefix) else {
                enumerator.skipDescendants()
                continue
            }
            let rel = resolved.hasPrefix(rootPrefix) ? String(resolved.dropFirst(rootPrefix.count)) : resolved
            if rel.isEmpty { continue }
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let suffix = (vals?.isDirectory == true) ? "/" : ""
            entries.append(rel + suffix)
            if entries.count >= maxEntries {
                break
            }
        }
        entries.sort()
        let out = entries.isEmpty ? "(empty)" : entries.joined(separator: "\n")
        return (out, entries.count)
    }

    private func readWorkspaceFile(
        workspaceRoot: URL,
        candidatePath: String,
        offsetLines: Int,
        maxLines: Int
    ) throws -> (output: String, canonicalRelPath: String) {
        let safeURL = try driftDetector.validateWorkspacePath(candidatePath, workspaceRoot: workspaceRoot)
        guard let canonicalRoot = DriftDetector.canonicalPath(for: workspaceRoot),
              safeURL.path != canonicalRoot else {
            throw DriftViolation.workspaceEscape(candidatePath: candidatePath, workspaceRoot: workspaceRoot.path)
        }
        let rootPrefix = canonicalRoot == "/" ? "/" : canonicalRoot + "/"
        let canonicalRelPath = safeURL.path.hasPrefix(rootPrefix)
            ? String(safeURL.path.dropFirst(rootPrefix.count))
            : safeURL.lastPathComponent
        var st = stat()
        guard lstat(safeURL.path, &st) == 0 else {
            throw NSError(domain: "AgentWorkerRunner", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "File not found: '\(candidatePath)'",
            ])
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: "AgentWorkerRunner", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Path is not a regular file: '\(candidatePath)'",
            ])
        }

        let handle = try FileHandle(forReadingFrom: safeURL)
        defer { try? handle.close() }
        let maxReadBytes = 262_144
        let rawData = try handle.read(upToCount: maxReadBytes) ?? Data()
        if rawData.contains(0) {
            throw NSError(domain: "AgentWorkerRunner", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "File '\(candidatePath)' appears to be binary.",
            ])
        }
        guard let text = String(data: rawData, encoding: .utf8) else {
            throw NSError(domain: "AgentWorkerRunner", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "File '\(candidatePath)' is not valid UTF-8 text.",
            ])
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let startIdx = min(lines.count, max(0, offsetLines - 1))
        let endIdx = min(lines.count, startIdx + maxLines)
        if startIdx >= endIdx {
            return ("(empty or offset beyond EOF; total lines: \(lines.count))", canonicalRelPath)
        }
        var formatted: [String] = []
        for idx in startIdx..<endIdx {
            formatted.append("L\(idx + 1): \(lines[idx])")
        }
        var joined = formatted.joined(separator: "\n")
        if rawData.count >= maxReadBytes || endIdx < lines.count {
            joined += "\n...[truncated; total lines: \(lines.count)]"
        }
        return (Self.boundFromHead(joined, maxChars: 16_384), canonicalRelPath)
    }

    private func searchWorkspace(
        workspaceRoot: URL,
        query: String,
        relativePath: String,
        maxResults: Int,
        caseSensitive: Bool
    ) throws -> (output: String, matchCount: Int) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw NSError(domain: "AgentWorkerRunner", code: 15, userInfo: [
                NSLocalizedDescriptionKey: "search_workspace requires non-empty 'query'",
            ])
        }
        guard let canonicalRoot = DriftDetector.canonicalPath(for: workspaceRoot) else {
            throw DriftViolation.workspaceEscape(candidatePath: relativePath, workspaceRoot: workspaceRoot.path)
        }
        let targetURL: URL
        if relativePath.isEmpty || relativePath == "." {
            targetURL = URL(fileURLWithPath: canonicalRoot, isDirectory: true)
        } else {
            targetURL = try driftDetector.validateWorkspacePath(relativePath, workspaceRoot: workspaceRoot)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir) else {
            throw NSError(domain: "AgentWorkerRunner", code: 16, userInfo: [
                NSLocalizedDescriptionKey: "Search path not found: '\(relativePath)'",
            ])
        }

        let rootPrefix = canonicalRoot == "/" ? "/" : canonicalRoot + "/"
        var filesToSearch: [URL] = []
        if !isDir.boolValue {
            filesToSearch = [targetURL]
        } else if let enumerator = FileManager.default.enumerator(
            at: targetURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            while let url = enumerator.nextObject() as? URL {
                let name = url.lastPathComponent
                if name == ".git" || name == ".build" || name == ".helm" {
                    enumerator.skipDescendants()
                    continue
                }
                var st = stat()
                if lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK {
                    if !driftDetector.isPathInsideWorkspace(url.path, workspaceRoot: workspaceRoot) {
                        enumerator.skipDescendants()
                        continue
                    }
                }
                let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if vals?.isDirectory == true { continue }
                if let size = vals?.fileSize, size > 1_048_576 { continue }
                filesToSearch.append(url)
            }
        }

        var matches: [String] = []
        for fileURL in filesToSearch.sorted(by: { $0.path < $1.path }) {
            guard driftDetector.isPathInsideWorkspace(fileURL.path, workspaceRoot: workspaceRoot),
                  let resolved = DriftDetector.canonicalPath(for: fileURL),
                  let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
                  !data.prefix(1024).contains(0),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            let relPath = resolved.hasPrefix(rootPrefix) ? String(resolved.dropFirst(rootPrefix.count)) : resolved
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (idx, rawLine) in lines.enumerated() {
                let lineStr = String(rawLine)
                let matched = caseSensitive
                    ? lineStr.contains(trimmedQuery)
                    : lineStr.localizedCaseInsensitiveContains(trimmedQuery)
                if matched {
                    matches.append("\(relPath):\(idx + 1): \(Self.boundFromHead(lineStr, maxChars: 240))")
                    if matches.count >= maxResults { break }
                }
            }
            if matches.count >= maxResults { break }
        }
        let out = matches.isEmpty ? "(no matches)" : Self.boundFromHead(matches.joined(separator: "\n"), maxChars: 12_000)
        return (out, matches.count)
    }

    // MARK: - Work Feed & Formatting Helpers

    private func recordWorkEntry(
        projectID: UUID,
        agent: AgentProfile,
        task: DelegatedTask,
        stepNumber: Int,
        phase: AgentWorkPhase,
        summary: String,
        toolName: String? = nil,
        toolInputSummary: String? = nil,
        toolOutputSummary: String? = nil,
        touchedFiles: [String] = [],
        artifactPaths: [String] = []
    ) async {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeSummary = Self.boundFromHead(trimmedSummary.isEmpty ? "\(phase.rawValue) update" : trimmedSummary, maxChars: 1_024)
        let safeInput = toolInputSummary.map { Self.boundFromHead($0, maxChars: 1_024) }
        let safeOutput = toolOutputSummary.map { Self.boundFromHead($0, maxChars: 8_192) }
        let entry = AgentWorkEntry(
            projectID: projectID,
            agentID: agent.id,
            agentName: agent.name,
            taskID: task.id,
            taskTitle: task.title,
            stepNumber: max(0, stepNumber),
            phase: phase,
            summary: safeSummary,
            toolName: toolName,
            toolInputSummary: safeInput,
            toolOutputSummary: safeOutput,
            touchedFiles: touchedFiles,
            artifactPaths: artifactPaths
        )
        try? await database.insertAgentWorkEntry(entry)
    }

    private static func boundFromHead(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let keep = max(0, maxChars - 3)
        return String(text.prefix(keep)) + "..."
    }

    private static func boundFromTail(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let keep = max(0, maxChars - 16)
        return "...[truncated]\n" + String(text.suffix(keep))
    }

    private static func canonicalArgsSignature(_ rawJSON: String) -> String {
        guard let data = rawJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(obj),
              let canonical = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: canonical, encoding: .utf8) else {
            return rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return str
    }

    private static func extractInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
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
