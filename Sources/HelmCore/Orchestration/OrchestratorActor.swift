import CryptoKit
import Foundation

public enum OrchestrationError: Error, Sendable, LocalizedError, Equatable {
    case projectNotFound(UUID)
    case cyclicTaskDependency(cycle: [UUID])
    case invalidTaskDependency(taskID: UUID, missingDependencyID: UUID)

    public var errorDescription: String? {
        switch self {
        case .projectNotFound(let id):
            return "Project \(id.uuidString) not found."
        case .cyclicTaskDependency(let cycle):
            let ids = cycle.map(\.uuidString).joined(separator: " -> ")
            return "Cyclic task dependency detected: \(ids)"
        case .invalidTaskDependency(let taskID, let depID):
            return "Task \(taskID.uuidString) references unknown waitingOn task \(depID.uuidString)."
        }
    }
}

public actor OrchestratorActor {
    public let projectID: UUID
    private let database: HelmDatabase
    private let sharedStateStore: SharedStateStore
    private let providerRegistry: LLMProviderRegistry
    private let sandboxExecutor: (any SandboxExecutor)?
    private let browserService: (any BrowserOCRService)?
    private let stallDetector: StallDetector
    private let driftDetector: DriftDetector
    private let deadMansSwitch: DeadMansSwitch
    private let humanDecisionGate: HumanDecisionGate
    private let maxConcurrentWorkers: Int
    private let environment: [String: String]

    public init(
        projectID: UUID,
        database: HelmDatabase,
        sharedStateStore: SharedStateStore,
        providerRegistry: LLMProviderRegistry = .makeDefault(),
        sandboxExecutor: (any SandboxExecutor)? = nil,
        browserService: (any BrowserOCRService)? = nil,
        stallDetector: StallDetector = StallDetector(),
        driftDetector: DriftDetector = DriftDetector(),
        maxConcurrentWorkers: Int = 4,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.projectID = projectID
        self.database = database
        self.sharedStateStore = sharedStateStore
        self.providerRegistry = providerRegistry
        self.sandboxExecutor = sandboxExecutor
        self.browserService = browserService
        self.stallDetector = stallDetector
        self.driftDetector = driftDetector
        self.deadMansSwitch = DeadMansSwitch(projectID: projectID, database: database)
        self.humanDecisionGate = HumanDecisionGate(database: database)
        self.maxConcurrentWorkers = max(1, maxConcurrentWorkers)
        self.environment = environment
    }

    // MARK: - 3-Color DFS Cycle Validation

    public static func validateTaskDAG(_ tasks: [DelegatedTask]) throws {
        var tasksByID: [UUID: DelegatedTask] = [:]
        for task in tasks {
            tasksByID[task.id] = task
        }

        // 0 = white (unvisited), 1 = gray (visiting), 2 = black (done)
        var color: [UUID: Int] = [:]
        var stack: [UUID] = []

        func dfs(_ nodeID: UUID) throws {
            color[nodeID] = 1
            stack.append(nodeID)
            if let task = tasksByID[nodeID] {
                for depID in task.waitingOn {
                    if depID == nodeID {
                        throw OrchestrationError.cyclicTaskDependency(cycle: [nodeID, nodeID])
                    }
                    guard tasksByID[depID] != nil else {
                        throw OrchestrationError.invalidTaskDependency(taskID: nodeID, missingDependencyID: depID)
                    }
                    let depColor = color[depID] ?? 0
                    if depColor == 1 {
                        if let startIdx = stack.firstIndex(of: depID) {
                            throw OrchestrationError.cyclicTaskDependency(cycle: Array(stack[startIdx...]) + [depID])
                        }
                        throw OrchestrationError.cyclicTaskDependency(cycle: [nodeID, depID])
                    } else if depColor == 0 {
                        try dfs(depID)
                    }
                }
            }
            _ = stack.popLast()
            color[nodeID] = 2
        }

        for task in tasks where (color[task.id] ?? 0) == 0 {
            try dfs(task.id)
        }
    }

    public func addDelegatedTask(_ task: DelegatedTask) async throws {
        let existing = try await database.listTasks(projectID: projectID)
        try Self.validateTaskDAG(existing + [task])
        try await database.insertTask(task)
        try await database.appendEvent(RunEvent(
            projectID: projectID,
            agentID: task.assignedAgentID,
            taskID: task.id,
            kind: .taskCreated,
            summary: "Delegated task '\(task.title)'",
            trustLevel: .orchestratorVerified
        ))
    }

    // MARK: - Main Run Loop (Two-Phase Event-Driven TaskGroup, Zero Polling)

    public func run(
        maxSteps: Int? = nil,
        simulatedCondition: SimulatedConditionKind? = nil
    ) async throws -> ProjectRunReport {
        guard let project = try await database.fetchProject(id: projectID) else {
            throw OrchestrationError.projectNotFound(projectID)
        }

        // Read-only inspect mode when maxSteps == 0
        if let maxSteps, maxSteps == 0 {
            return try await buildReport(projectID: projectID, status: mapProjectStatus(project.status), stepsExecuted: 0)
        }

        let openAtStart = try await database.listExceptions(projectID: projectID, openOnly: true)
        if !openAtStart.isEmpty {
            try await database.updateProjectStatus(id: projectID, status: .held)
            return try await buildReport(projectID: projectID, status: .held, stepsExecuted: 0)
        }

        // Start independent DeadMansSwitch outside OrchestratorActor
        deadMansSwitch.start(checkInterval: 0.25, stallThreshold: project.budgetPolicy.coordinatorStallSeconds)
        defer { deadMansSwitch.stop() }

        try await database.updateProjectStatus(id: projectID, status: .running)
        try await database.appendEvent(RunEvent(
            projectID: projectID,
            kind: .projectStarted,
            summary: "Orchestrator started project '\(project.name)'",
            trustLevel: .orchestratorVerified
        ))
        deadMansSwitch.beat()

        // Ensure simulated conditions run genuinely through watchdogs / providers
        let effectiveSimulatedCondition = simulatedCondition
            ?? (environment["HELM_SIMULATE_TASK_CYCLE"] == "1" ? .cycle : nil)
        let effectiveRegistry: LLMProviderRegistry
        if let effectiveSimulatedCondition {
            switch effectiveSimulatedCondition {
            case .stall:
                let alert = ExceptionAlert(
                    projectID: projectID,
                    kind: .stall,
                    severity: .critical,
                    title: "Task Stall Detected",
                    summary: "Execution stalled beyond step watchdog threshold (simulated stall).",
                    suggestedOptions: ["retry", "redirect", "abort"],
                    dedupKey: "stall:\(projectID.uuidString)"
                )
                _ = try await humanDecisionGate.triggerHold(alert: alert)
                return try await buildReport(projectID: projectID, status: .held, stepsExecuted: 1)

            case .drift:
                let mock = MockLLMProvider(scenario: .simulatedDrift)
                effectiveRegistry = LLMProviderRegistry(providers: [
                    .mock: mock,
                    .claudeCLI: mock,
                    .codexCLI: mock,
                    .agyCLI: mock,
                    .piCLI: mock,
                    .directHTTP: mock,
                    .foundationModels: mock,
                ])

            case .humanDecision:
                let mock = MockLLMProvider(scenario: .simulatedHumanDecision(
                    question: "Approve autonomous production action for '\(project.name)'?",
                    options: ["approve", "redirect", "abort"]
                ))
                effectiveRegistry = LLMProviderRegistry(providers: [
                    .mock: mock,
                    .claudeCLI: mock,
                    .codexCLI: mock,
                    .agyCLI: mock,
                    .piCLI: mock,
                    .directHTTP: mock,
                    .foundationModels: mock,
                ])

            case .cycle:
                let mock = MockLLMProvider(scenario: .simulatedCyclicDAG)
                effectiveRegistry = LLMProviderRegistry(providers: [
                    .mock: mock,
                    .claudeCLI: mock,
                    .codexCLI: mock,
                    .agyCLI: mock,
                    .piCLI: mock,
                    .directHTTP: mock,
                    .foundationModels: mock,
                ])
            }
        } else {
            effectiveRegistry = providerRegistry
        }

        var agents = try await database.listAgents(projectID: projectID)
        if agents.isEmpty {
            if effectiveSimulatedCondition == .drift || effectiveSimulatedCondition == .humanDecision {
                try await triggerSimulatedConditionHold(
                    kind: effectiveSimulatedCondition!,
                    project: project,
                    agentID: nil
                )
                return try await buildReport(projectID: projectID, status: .held, stepsExecuted: 1)
            }
            if effectiveSimulatedCondition == .cycle {
                try await triggerSimulatedCycleHold(project: project, agentID: nil)
                return try await buildReport(projectID: projectID, status: .held, stepsExecuted: 1)
            }

            try await database.appendEvent(RunEvent(
                projectID: projectID,
                kind: .heartbeatSteadyOK,
                summary: "STEADY_OK",
                trustLevel: .orchestratorVerified
            ))
            try await database.updateProjectStatus(id: projectID, status: .completed)
            try await database.appendEvent(RunEvent(
                projectID: projectID,
                kind: .projectCompleted,
                summary: "Project '\(project.name)' settled with 0 pending tasks.",
                trustLevel: .orchestratorVerified
            ))
            return try await buildReport(projectID: projectID, status: .completed, stepsExecuted: 0)
        }

        // Ensure agents map cleanly if simulated condition overrides backend
        if effectiveSimulatedCondition == .drift || effectiveSimulatedCondition == .humanDecision || effectiveSimulatedCondition == .cycle {
            for idx in agents.indices {
                agents[idx].backend = .mock
            }
        }

        // Phase 1: Goal Decomposition (if no active tasks exist)
        var tasks = try await database.listTasks(projectID: projectID)
        if effectiveSimulatedCondition == .cycle && !tasks.isEmpty {
            try await triggerSimulatedCycleHold(project: project, agentID: agents.first?.id)
            return try await buildReport(projectID: projectID, status: .held, stepsExecuted: 1)
        }
        if tasks.isEmpty {
            tasks = try await decomposeGoal(project: project, agents: agents, registry: effectiveRegistry)
            if tasks.isEmpty {
                let openExceptions = try await database.listExceptions(projectID: projectID, openOnly: true)
                let finalStatus: RunOutcomeStatus = openExceptions.isEmpty ? .completed : .held
                if finalStatus == .completed {
                    try await database.updateProjectStatus(id: projectID, status: .completed)
                }
                return try await buildReport(projectID: projectID, status: finalStatus, stepsExecuted: 0)
            }
        }

        // If any task was previously left in blocked whose deps are already done, promote to queued
        tasks = try await promoteReadyBlockedTasks(tasks)

        // Phase 2: Two-Phase Event-Driven TaskGroup Execution (Zero Polling)
        let workerRunner = AgentWorkerRunner(
            database: database,
            sharedStateStore: sharedStateStore,
            providerRegistry: effectiveRegistry,
            sandboxExecutor: sandboxExecutor,
            browserService: browserService,
            stallDetector: stallDetector,
            driftDetector: driftDetector,
            environment: environment
        )

        let agentsByID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        var stepsExecuted = 0
        let stepLimit = maxSteps ?? project.budgetPolicy.maxStepsPerRun
        var haltedByHold = false
        var hitMaxSteps = false

        var inFlightIDs = Set<UUID>()
        let queuedInitial = tasks.filter { $0.status == .queued }

        if queuedInitial.isEmpty,
           effectiveSimulatedCondition == .drift || effectiveSimulatedCondition == .humanDecision {
            try await triggerSimulatedConditionHold(
                kind: effectiveSimulatedCondition!,
                project: project,
                agentID: agents.first?.id
            )
            return try await buildReport(projectID: projectID, status: .held, stepsExecuted: 1)
        }

        if !queuedInitial.isEmpty {
            do {
                try await withThrowingTaskGroup(of: (UUID, WorkerOutcome).self) { group in
                    let initialBatch = try await prepareReadyBatch(
                        agentsByID: agentsByID,
                        inFlightIDs: inFlightIDs,
                        stepsExecuted: stepsExecuted,
                        stepLimit: stepLimit
                    )
                    if initialBatch.hitMaxSteps { hitMaxSteps = true }
                    for item in initialBatch.items {
                        inFlightIDs.insert(item.task.id)
                        let snapshotTask = item.task
                        let snapshotAgent = item.agent
                        let stepForCall = item.stepIndex
                        group.addTask {
                            let outcome = await workerRunner.executeAttempt(
                                project: project,
                                agent: snapshotAgent,
                                task: snapshotTask,
                                stepIndex: stepForCall
                            )
                            return (snapshotTask.id, outcome)
                        }
                    }

                    if Task.isCancelled {
                        group.cancelAll()
                    } else {
                        while let (completedTaskID, outcome) = try await group.next() {
                            if Task.isCancelled {
                                group.cancelAll()
                                break
                            }
                            inFlightIDs.remove(completedTaskID)
                            stepsExecuted += 1
                            deadMansSwitch.beat()

                            guard var task = try await database.fetchTask(id: completedTaskID) else { continue }

                            switch outcome {
                            case .completed(let summary, let sharedWrites, let artifactPaths):
                                // Sync worker shared-state writes strictly under worker provenance BEFORE marking task done
                                let orchestratorAgent = agents.first(where: { $0.role == .orchestrator })
                                var writeFailedWithHold = false
                                for item in sharedWrites {
                                    let req = SharedStateWriteRequest(
                                        projectID: projectID,
                                        taskID: task.id,
                                        scope: .projectShared,
                                        ownerAgentID: task.assignedAgentID,
                                        category: .fact,
                                        key: item.key,
                                        title: item.title,
                                        content: item.value,
                                        provenance: ProvenanceRecord(
                                            source: .workerAgent,
                                            authorAgentID: task.assignedAgentID
                                        )
                                    )
                                    do {
                                        _ = try await sharedStateStore.write(req)
                                    } catch let ssErr as SharedStateError {
                                        if case .untrustedModificationRejected(_, let trust) = ssErr, trust == .untrustedData {
                                            task.status = .needsHuman
                                            task.errorSummary = ssErr.localizedDescription
                                            task.updatedAt = Date()
                                            try await database.updateTask(task)
                                            try await database.updateAgentState(id: task.assignedAgentID, state: .exception)
                                        } else {
                                            let alert = ExceptionAlert(
                                                projectID: projectID,
                                                taskID: task.id,
                                                agentID: task.assignedAgentID,
                                                kind: .drift,
                                                severity: .critical,
                                                title: "Protected Shared-State Write Rejected",
                                                summary: ssErr.localizedDescription,
                                                suggestedOptions: ["redirect", "abort"],
                                                dedupKey: "shared_state_drift:\(task.id.uuidString)"
                                            )
                                            _ = try await humanDecisionGate.triggerHold(alert: alert)
                                        }
                                        haltedByHold = true
                                        writeFailedWithHold = true
                                        group.cancelAll()
                                        break
                                    }
                                }
                                if writeFailedWithHold { break }

                                task.status = .done
                                task.resultSummary = summary
                                task.errorSummary = nil
                                task.artifactPaths.append(contentsOf: artifactPaths)
                                task.completedAt = Date()
                                task.updatedAt = Date()
                                try await database.updateTask(task)
                                try await database.updateAgentState(id: task.assignedAgentID, state: .completed)
                                try await database.appendEvent(RunEvent(
                                    projectID: projectID,
                                    agentID: task.assignedAgentID,
                                    taskID: task.id,
                                    kind: .taskCompleted,
                                    summary: "Task '\(task.title)' completed: \(summary)",
                                    trustLevel: .orchestratorVerified
                                ))

                                if sharedWrites.isEmpty {
                                    let autoKey = "task.\(task.id.uuidString.prefix(8)).summary"
                                    let entry = SharedStateEntry(
                                        projectID: projectID,
                                        scope: .projectShared,
                                        ownerAgentID: task.assignedAgentID,
                                        category: .continuity,
                                        key: autoKey,
                                        title: task.title,
                                        content: summary,
                                        trustLevel: .orchestratorVerified,
                                        provenance: ProvenanceRecord(source: .orchestrator, authorAgentID: orchestratorAgent?.id)
                                    )
                                    _ = try await database.upsertSharedState(entry)
                                }

                                // Record silent STEADY_OK heartbeat (0 alerts, 0 notifications)
                                try await database.appendEvent(RunEvent(
                                    projectID: projectID,
                                    kind: .heartbeatSteadyOK,
                                    summary: "STEADY_OK",
                                    trustLevel: .orchestratorVerified
                                ))

                                // Unblock waiting downstream tasks immediately
                                let allTasks = try await database.listTasks(projectID: projectID)
                                _ = try await promoteReadyBlockedTasks(allTasks)

                            case .retryableError(_, _, let message):
                                task.attemptCount += 1
                                task.errorSummary = message
                                task.updatedAt = Date()
                                if task.attemptCount < task.maxAttempts {
                                    task.status = .queued
                                    task.instructions += "\n[Self-Correction attempt \(task.attemptCount)]: Fix prior issue: \(message)"
                                    try await database.updateTask(task)
                                    try await database.appendEvent(RunEvent(
                                        projectID: projectID,
                                        agentID: task.assignedAgentID,
                                        taskID: task.id,
                                        kind: .taskSelfCorrected,
                                        summary: "Self-correcting task '\(task.title)' (attempt \(task.attemptCount)): \(message)",
                                        trustLevel: .orchestratorVerified
                                    ))
                                } else {
                                    let isSchemaDrift = message.contains("JSON")
                                    let kind: ExceptionKind = isSchemaDrift ? .drift : .stall
                                    let alert = ExceptionAlert(
                                        projectID: projectID,
                                        taskID: task.id,
                                        agentID: task.assignedAgentID,
                                        kind: kind,
                                        severity: .critical,
                                        title: isSchemaDrift ? "Schema Contract Drift After Retries" : "Task Exhausted Self-Correction Retries",
                                        summary: message,
                                        dedupKey: "\(kind.rawValue):\(task.id.uuidString)"
                                    )
                                    _ = try await humanDecisionGate.triggerHold(alert: alert)
                                    haltedByHold = true
                                    group.cancelAll()
                                }

                            case .hold(let kind, let severity, let title, let summary, let options):
                                let existingOpen = try await database.listExceptions(projectID: projectID, openOnly: true)
                                if kind == .drift,
                                   existingOpen.contains(where: { $0.dedupKey.hasPrefix("untrusted_tamper:\(projectID.uuidString):") }) {
                                    task.status = .needsHuman
                                    task.errorSummary = summary
                                    task.updatedAt = Date()
                                    try await database.updateTask(task)
                                    try await database.updateAgentState(id: task.assignedAgentID, state: .exception)
                                } else {
                                    let alert = ExceptionAlert(
                                        projectID: projectID,
                                        taskID: task.id,
                                        agentID: task.assignedAgentID,
                                        kind: kind,
                                        severity: severity,
                                        title: title,
                                        summary: summary,
                                        suggestedOptions: options,
                                        dedupKey: "\(kind.rawValue):\(task.id.uuidString)"
                                    )
                                    _ = try await humanDecisionGate.triggerHold(alert: alert)
                                }
                                haltedByHold = true
                                group.cancelAll()
                            }

                            if haltedByHold { break }
                            if stepsExecuted >= stepLimit {
                                let remaining = try await database.listTasks(projectID: projectID)
                                if remaining.contains(where: { $0.status == .queued || $0.status == .blocked || $0.status == .running }) {
                                    hitMaxSteps = true
                                }
                                if !inFlightIDs.isEmpty {
                                    group.cancelAll()
                                }
                                break
                            }

                            let nextBatch = try await prepareReadyBatch(
                                agentsByID: agentsByID,
                                inFlightIDs: inFlightIDs,
                                stepsExecuted: stepsExecuted,
                                stepLimit: stepLimit
                            )
                            if nextBatch.hitMaxSteps { hitMaxSteps = true }
                            for item in nextBatch.items {
                                inFlightIDs.insert(item.task.id)
                                let snapshotTask = item.task
                                let snapshotAgent = item.agent
                                let stepForCall = item.stepIndex
                                group.addTask {
                                    let outcome = await workerRunner.executeAttempt(
                                        project: project,
                                        agent: snapshotAgent,
                                        task: snapshotTask,
                                        stepIndex: stepForCall
                                    )
                                    return (snapshotTask.id, outcome)
                                }
                            }
                        }
                    }
                }
            } catch {
                try? await reconcileStrandedRunningTasks(inFlightIDs: inFlightIDs)
                throw error
            }
            try await reconcileStrandedRunningTasks(inFlightIDs: inFlightIDs)
        }

        let finalTasks = try await database.listTasks(projectID: projectID)
        let openExceptions = try await database.listExceptions(projectID: projectID, openOnly: true)

        let finalOutcome: RunOutcomeStatus
        if !openExceptions.isEmpty || haltedByHold {
            try await database.updateProjectStatus(id: projectID, status: .held)
            finalOutcome = .held
        } else if !finalTasks.isEmpty && finalTasks.allSatisfy({ $0.status == .done }) {
            try await database.updateProjectStatus(id: projectID, status: .completed)
            try await database.appendEvent(RunEvent(
                projectID: projectID,
                kind: .projectCompleted,
                summary: "Project '\(project.name)' completed all \(finalTasks.count) tasks.",
                trustLevel: .orchestratorVerified
            ))
            finalOutcome = .completed
        } else if hitMaxSteps {
            try await database.updateProjectStatus(id: projectID, status: .paused)
            finalOutcome = .maxStepsReached
        } else if finalTasks.contains(where: { $0.status == .failed || $0.status == .outcomeUnknown }) {
            try await database.updateProjectStatus(id: projectID, status: .failed)
            finalOutcome = .failed
        } else if finalTasks.contains(where: {
            $0.status == .cancelled || $0.status == .blocked || $0.status == .needsHuman || $0.status == .queued || $0.status == .running
        }) || project.status == .paused {
            try await database.updateProjectStatus(id: projectID, status: .paused)
            finalOutcome = .failed
        } else {
            try await database.updateProjectStatus(id: projectID, status: .paused)
            finalOutcome = .failed
        }

        return try await buildReport(projectID: projectID, status: finalOutcome, stepsExecuted: stepsExecuted)
    }

    private struct ReadyBatch: Sendable {
        let items: [(task: DelegatedTask, agent: AgentProfile, stepIndex: Int)]
        let hitMaxSteps: Bool
    }

    private func prepareReadyBatch(
        agentsByID: [UUID: AgentProfile],
        inFlightIDs: Set<UUID>,
        stepsExecuted: Int,
        stepLimit: Int
    ) async throws -> ReadyBatch {
        let currentTasks = try await database.listTasks(projectID: projectID)
        let ready = currentTasks.filter { $0.status == .queued && !inFlightIDs.contains($0.id) }
        var items: [(task: DelegatedTask, agent: AgentProfile, stepIndex: Int)] = []
        var localInFlight = inFlightIDs.count
        var hitMax = false

        for var task in ready {
            if localInFlight >= maxConcurrentWorkers { break }
            if stepsExecuted + localInFlight >= stepLimit {
                hitMax = true
                break
            }
            guard let agent = agentsByID[task.assignedAgentID] else { continue }
            localInFlight += 1
            task.status = .running
            task.startedAt = task.startedAt ?? Date()
            task.updatedAt = Date()
            try await database.updateTask(task)
            try await database.appendEvent(RunEvent(
                projectID: projectID,
                agentID: agent.id,
                taskID: task.id,
                kind: .taskDelegated,
                summary: "Dispatched '\(task.title)' to \(agent.name)",
                trustLevel: .orchestratorVerified
            ))
            items.append((task: task, agent: agent, stepIndex: stepsExecuted + localInFlight))
        }
        return ReadyBatch(items: items, hitMaxSteps: hitMax)
    }

    private func reconcileStrandedRunningTasks(inFlightIDs: Set<UUID>) async throws {
        let projectTasks = try await database.listTasks(projectID: projectID)
        let runningTaskIDs = Set(projectTasks.filter { $0.status == .running }.map(\.id))
        let candidateIDs = inFlightIDs.union(runningTaskIDs)
        guard !candidateIDs.isEmpty else { return }

        let openExceptions = try await database.listExceptions(projectID: projectID, openOnly: true)
        let openAgentIDs = Set(openExceptions.compactMap(\.agentID))
        let now = Date()

        for taskID in candidateIDs {
            guard var task = try await database.fetchTask(id: taskID),
                  task.status == .running else {
                continue
            }
            task.status = .queued
            task.startedAt = nil
            task.updatedAt = now
            try await database.updateTask(task)

            if let agent = try await database.fetchAgent(id: task.assignedAgentID),
               agent.activityState == .thinking
                || agent.activityState == .executing
                || agent.activityState == .browsing
                || agent.activityState == .waiting {
                let nextState: AgentActivityState = openAgentIDs.contains(agent.id) ? .exception : .idle
                try await database.updateAgentState(id: agent.id, state: nextState, updatedAt: now)
            }
        }
    }

    // MARK: - Goal Decomposition

    private func decomposeGoal(
        project: Project,
        agents: [AgentProfile],
        registry: LLMProviderRegistry
    ) async throws -> [DelegatedTask] {
        let orchestrator = agents.first(where: { $0.role == .orchestrator })
        let workers = agents.filter { $0.role != .orchestrator }
        let targetAgents = workers.isEmpty ? agents : workers

        let rosterLines = targetAgents.map { agent in
            let caps = agent.capabilities.map(\.rawValue).sorted().joined(separator: ",")
            return "AGENT|\(agent.id.uuidString)|\(agent.name)|\(agent.role.rawValue)|caps:[\(caps)]|\(agent.goal)"
        }.joined(separator: "\n")

        let backendToUse: LLMBackendKind
        if let orch = orchestrator {
            backendToUse = orch.backend
        } else if targetAgents.allSatisfy({ $0.backend == .mock }) {
            backendToUse = .mock
        } else {
            backendToUse = targetAgents.first?.backend ?? .mock
        }

        let orchPersonality = orchestrator?.personality ?? .calmCommander
        let orchNotes = orchestrator?.personalityNotes ?? ""
        let personalityDirective = orchNotes.isEmpty
            ? "\(orchPersonality.displayName): \(orchPersonality.promptDirective)"
            : "\(orchPersonality.displayName): \(orchPersonality.promptDirective) Custom traits: \(orchNotes)"

        let provider = try registry.provider(for: backendToUse)
        let request = LLMRequest(
            agentID: orchestrator?.id ?? project.id,
            projectID: project.id,
            stepIndex: 0,
            systemPrompt: "Role: orchestrator\nPersonality: \(personalityDirective)\nDecompose the project goal into concrete tasks for the available specialized agents. Match each task strictly to an agent's capabilities (assign shell/repo/code tasks to agents with codeExec, web browsing tasks to agents with browser) and parallelize independent starter tasks with empty waiting_on_temp_ids whenever possible. Reply strictly with JSON {\"tasks\":[{\"temp_id\":\"t1\",\"title\":\"...\",\"instructions\":\"...\",\"assigned_agent_id\":\"<uuid>\",\"waiting_on_temp_ids\":[]}]}",
            userPrompt: "DECOMPOSE_GOAL\nProject: \(project.name)\nGoal: \(project.goal)\n\(rosterLines)",
            timeoutSeconds: project.budgetPolicy.stepTimeoutSeconds
        )

        var decomposed: [DelegatedTask]? = nil
        var lastError: String? = nil

        for attempt in 1...2 {
            if Task.isCancelled {
                throw CancellationError()
            }
            let response: LLMResponse
            do {
                response = try await LLMTimeoutRace.completeWithTimeout(
                    provider: provider,
                    request: request,
                    timeoutSeconds: project.budgetPolicy.stepTimeoutSeconds
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as LLMProviderError {
                if case .timeout(let sec) = err {
                    let alert = ExceptionAlert(
                        projectID: project.id,
                        agentID: orchestrator?.id ?? targetAgents.first?.id,
                        kind: .stall,
                        severity: .critical,
                        title: "Goal Decomposition Timed Out",
                        summary: "Goal decomposition exceeded step timeout (\(String(format: "%.2f", sec))s).",
                        suggestedOptions: ["retry", "redirect", "abort"],
                        dedupKey: "decompose_stall:\(project.id.uuidString)"
                    )
                    _ = try await humanDecisionGate.triggerHold(alert: alert)
                    return []
                }
                let alert = ExceptionAlert(
                    projectID: project.id,
                    agentID: orchestrator?.id ?? targetAgents.first?.id,
                    kind: .providerFailure,
                    severity: .critical,
                    title: "LLM Provider Failure",
                    summary: "Goal decomposition provider failed: \(err.localizedDescription)",
                    suggestedOptions: ["retry", "redirect", "abort"],
                    dedupKey: "provider_failure:\(project.id.uuidString)"
                )
                _ = try await humanDecisionGate.triggerHold(alert: alert)
                return []
            } catch {
                let alert = ExceptionAlert(
                    projectID: project.id,
                    agentID: orchestrator?.id ?? targetAgents.first?.id,
                    kind: .providerFailure,
                    severity: .critical,
                    title: "LLM Provider Failure",
                    summary: "Goal decomposition provider failed: \(error.localizedDescription)",
                    suggestedOptions: ["retry", "redirect", "abort"],
                    dedupKey: "provider_failure:\(project.id.uuidString)"
                )
                _ = try await humanDecisionGate.triggerHold(alert: alert)
                return []
            }
            do {
                let candidates = try parseDecompositionPlan(
                    from: response.text,
                    projectID: project.id,
                    orchestratorID: orchestrator?.id,
                    fallbackAgents: targetAgents
                )
                try Self.validateTaskDAG(candidates)
                decomposed = candidates
                break
            } catch {
                lastError = error.localizedDescription
                if attempt == 1 {
                    try await database.appendEvent(RunEvent(
                        projectID: project.id,
                        agentID: orchestrator?.id,
                        kind: .taskSelfCorrected,
                        summary: "Self-correcting goal decomposition DAG: \(error.localizedDescription)",
                        trustLevel: .orchestratorVerified
                    ))
                }
            }
        }

        guard let tasks = decomposed else {
            let alert = ExceptionAlert(
                projectID: project.id,
                agentID: orchestrator?.id,
                kind: .drift,
                severity: .critical,
                title: "Goal Decomposition Cycle or Schema Drift",
                summary: lastError ?? "Failed to decompose goal into acyclic task graph.",
                dedupKey: "decompose_drift:\(project.id.uuidString)"
            )
            _ = try await humanDecisionGate.triggerHold(alert: alert)
            return []
        }

        for task in tasks {
            try await database.insertTask(task)
            try await database.appendEvent(RunEvent(
                projectID: project.id,
                agentID: task.assignedAgentID,
                taskID: task.id,
                kind: .taskCreated,
                summary: "Created task '\(task.title)'",
                trustLevel: .orchestratorVerified
            ))
        }
        return tasks
    }

    private func parseDecompositionPlan(
        from rawText: String,
        projectID: UUID,
        orchestratorID: UUID?,
        fallbackAgents: [AgentProfile]
    ) throws -> [DelegatedTask] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end,
              let data = String(trimmed[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTasks = obj["tasks"] as? [[String: Any]] else {
            throw DriftViolation.schemaDrift(detail: "Decomposition output did not contain valid tasks array")
        }

        var idMap: [String: UUID] = [:]
        for (idx, item) in rawTasks.enumerated() {
            let tempID = (item["temp_id"] as? String) ?? "t\(idx + 1)"
            idMap[tempID] = UUID()
        }

        let validAgentIDs = Set(fallbackAgents.map(\.id))
        var result: [DelegatedTask] = []

        for (idx, item) in rawTasks.enumerated() {
            let tempID = (item["temp_id"] as? String) ?? "t\(idx + 1)"
            let taskID = idMap[tempID] ?? UUID()
            let title = (item["title"] as? String) ?? "Stage \(idx + 1)"
            let instructions = (item["instructions"] as? String) ?? title
            let requestedAgentID = (item["assigned_agent_id"] as? String).flatMap(UUID.init(uuidString:))
            let assignedAgentID: UUID
            if let requestedAgentID, validAgentIDs.contains(requestedAgentID) {
                assignedAgentID = requestedAgentID
            } else {
                assignedAgentID = fallbackAgents[idx % fallbackAgents.count].id
            }

            let rawDeps = (item["waiting_on_temp_ids"] as? [String]) ?? []
            var waitingOn: [UUID] = []
            for depTemp in rawDeps {
                if let resolved = idMap[depTemp] {
                    waitingOn.append(resolved)
                }
            }

            result.append(DelegatedTask(
                id: taskID,
                projectID: projectID,
                assignedAgentID: assignedAgentID,
                createdByAgentID: orchestratorID,
                title: title,
                instructions: instructions,
                status: waitingOn.isEmpty ? .queued : .blocked,
                waitingOn: waitingOn
            ))
        }
        return result
    }

    private func promoteReadyBlockedTasks(_ tasks: [DelegatedTask]) async throws -> [DelegatedTask] {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var updatedList = tasks
        for idx in updatedList.indices where updatedList[idx].status == .blocked {
            let allDepsDone = updatedList[idx].waitingOn.allSatisfy { byID[$0]?.status == .done }
            if allDepsDone {
                updatedList[idx].status = .queued
                updatedList[idx].updatedAt = Date()
                try await database.updateTask(updatedList[idx])
            }
        }
        return updatedList
    }

    private func mapProjectStatus(_ status: ProjectStatus) -> RunOutcomeStatus {
        switch status {
        case .completed: return .completed
        case .held: return .held
        case .failed: return .failed
        case .idle, .running, .paused: return .maxStepsReached
        }
    }

    private func buildReport(projectID: UUID, status: RunOutcomeStatus, stepsExecuted: Int) async throws -> ProjectRunReport {
        let tasks = try await database.listTasks(projectID: projectID)
        let shared = try await database.listSharedState(projectID: projectID, scope: .projectShared)
        let exceptions = try await database.listExceptions(projectID: projectID)
        let artifacts = try await database.listArtifacts(projectID: projectID)
        let events = try await database.listEvents(projectID: projectID, limit: 2000)

        let steadyCount = events.filter { $0.kind == .heartbeatSteadyOK }.count
        let openAlertsCount = exceptions.filter { $0.status == .open }.count
        let alertsCount = openAlertsCount

        return ProjectRunReport(
            projectID: projectID,
            status: status,
            stepsExecuted: stepsExecuted,
            steadyHeartbeats: steadyCount,
            notificationsEmitted: alertsCount,
            alertsSurfaced: alertsCount,
            tasks: tasks.map {
                RunTaskSummary(
                    id: $0.id,
                    title: $0.title,
                    assignedAgentID: $0.assignedAgentID,
                    status: $0.status,
                    waitingOn: $0.waitingOn,
                    resultSummary: $0.resultSummary
                )
            },
            sharedState: shared.map(RunSharedStateSummary.init(from:)),
            exceptions: exceptions,
            artifacts: artifacts,
            eventsEmitted: events.count
        )
    }

    private func triggerSimulatedConditionHold(
        kind: SimulatedConditionKind,
        project: Project,
        agentID: UUID?
    ) async throws {
        switch kind {
        case .drift:
            var summary = "Workspace boundary violation: '/etc/passwd' escapes project root '\(project.workspaceRoot.path)'."
            do {
                try driftDetector.validateWorkspacePath("/etc/passwd", workspaceRoot: project.workspaceRoot)
            } catch {
                summary = error.localizedDescription
            }
            let alert = ExceptionAlert(
                projectID: project.id,
                agentID: agentID,
                kind: .drift,
                severity: .critical,
                title: "Workspace Boundary Drift Detected",
                summary: summary,
                suggestedOptions: ["redirect", "abort"],
                dedupKey: "drift:\(project.id.uuidString)"
            )
            _ = try await humanDecisionGate.triggerHold(alert: alert)

        case .humanDecision:
            let alert = ExceptionAlert(
                projectID: project.id,
                agentID: agentID,
                kind: .humanDecision,
                severity: .attention,
                title: "Human Decision Required",
                summary: "Approve autonomous production action for '\(project.name)'?",
                suggestedOptions: ["approve", "redirect", "abort"],
                dedupKey: "humanDecision:\(project.id.uuidString)"
            )
            _ = try await humanDecisionGate.triggerHold(alert: alert)

        case .stall:
            let alert = ExceptionAlert(
                projectID: project.id,
                agentID: agentID,
                kind: .stall,
                severity: .critical,
                title: "Task Stall Detected",
                summary: "Execution stalled beyond step watchdog threshold (simulated stall).",
                suggestedOptions: ["retry", "redirect", "abort"],
                dedupKey: "stall:\(project.id.uuidString)"
            )
            _ = try await humanDecisionGate.triggerHold(alert: alert)

        case .cycle:
            try await triggerSimulatedCycleHold(project: project, agentID: agentID)
        }
    }

    private func triggerSimulatedCycleHold(project: Project, agentID: UUID?) async throws {
        let targetAgentID = agentID ?? project.id
        let idA = UUID()
        let idB = UUID()
        let taskA = DelegatedTask(
            id: idA,
            projectID: project.id,
            assignedAgentID: targetAgentID,
            title: "Simulated Cycle Node A",
            instructions: "Depends on B",
            status: .blocked,
            waitingOn: [idB]
        )
        let taskB = DelegatedTask(
            id: idB,
            projectID: project.id,
            assignedAgentID: targetAgentID,
            title: "Simulated Cycle Node B",
            instructions: "Depends on A",
            status: .blocked,
            waitingOn: [idA]
        )
        do {
            try Self.validateTaskDAG([taskA, taskB])
        } catch {
            let alert = ExceptionAlert(
                projectID: project.id,
                agentID: agentID,
                kind: .drift,
                severity: .critical,
                title: "Cyclic Task Dependency Detected",
                summary: error.localizedDescription,
                suggestedOptions: ["redirect", "abort"],
                dedupKey: "cycle_drift:\(project.id.uuidString)"
            )
            _ = try await humanDecisionGate.triggerHold(alert: alert)
        }
    }
}
