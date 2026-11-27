import Foundation
import HelmBrowser
import HelmCore
import HelmIsolation
import Observation

@MainActor
@Observable
public final class HelmWorkspaceStore {
    public let controlPlane: HelmControlPlane
    public let ocrService: VisionOCRService
    public let sandboxExecutor: ExecutionRouter
    public let browserService: BrowseReadActTool
    public let notificationCoordinator: NotificationCoordinator

    public var selectedProjectID: UUID?
    public var selectedAgentID: UUID?
    public var isInspectorVisible: Bool = true
    public var showNewProjectSheet: Bool = false
    public var showAddAgentSheet: Bool = false

    public var isWindowOccluded: Bool = false
    public var forcedReduceMotion: Bool = false
    public var settleHelmCounter: Int = 0
    public var bannerErrorMessage: String?
    public var isRunningDiagnostic: Bool = false

    public var sharedStateByProject: [UUID: [RunSharedStateSummary]] = [:]
    public var privateMemoryByAgent: [UUID: [SharedStateEntry]] = [:]
    public var eventsByProject: [UUID: [RunEvent]] = [:]
    public var artifactsByProject: [UUID: [ArtifactRecord]] = [:]
    public var latestBrowserObservationByProject: [UUID: BrowserObservation] = [:]
    public var latestExecutionResultByProject: [UUID: ExecutionResult] = [:]
    public var horizonPingCounterByProject: [UUID: Int] = [:]

    public let virtualizationAvailable: Bool = EntitlementChecker.isVirtualizationAvailable()

    private var pollingTask: Task<Void, Never>?
    private var pendingStartProjectIDs: Set<UUID> = []
    private var pollingGraceDeadline: Date?
    private var lastSteadyEventIDByProject: [UUID: UUID] = [:]
    private var lastExecutionEventIDByProject: [UUID: UUID] = [:]
    private var lastBrowserEventIDByProject: [UUID: UUID] = [:]

    public init(
        controlPlane: HelmControlPlane,
        ocrService: VisionOCRService,
        sandboxExecutor: ExecutionRouter,
        browserService: BrowseReadActTool,
        notificationCoordinator: NotificationCoordinator,
        forcedReduceMotion: Bool = false
    ) {
        self.controlPlane = controlPlane
        self.ocrService = ocrService
        self.sandboxExecutor = sandboxExecutor
        self.browserService = browserService
        self.notificationCoordinator = notificationCoordinator
        self.forcedReduceMotion = forcedReduceMotion
    }

    public static func makeLive(
        databasePath: String,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> HelmWorkspaceStore {
        let ocr = VisionOCRService()
        let router = ExecutionRouter()
        let browser = BrowseReadActTool(ocrService: ocr)
        let cp = try HelmControlPlane(
            databasePath: databasePath,
            providerRegistry: .makeDefault(environment: environment),
            sandboxExecutor: router,
            browserService: browser,
            environment: environment
        )
        let notif = NotificationCoordinator(arguments: arguments, environment: environment)
        let reduceMotion = arguments.contains("--reduce-motion") || environment["HELM_REDUCE_MOTION"] == "1"
        return HelmWorkspaceStore(
            controlPlane: cp,
            ocrService: ocr,
            sandboxExecutor: router,
            browserService: browser,
            notificationCoordinator: notif,
            forcedReduceMotion: reduceMotion
        )
    }

    // MARK: - Derived Selections

    public var projects: [Project] {
        controlPlane.projects
    }

    public var selectedProject: Project? {
        if let selectedProjectID,
           let match = controlPlane.projects.first(where: { $0.id == selectedProjectID }) {
            return match
        }
        return controlPlane.projects.first
    }

    public var selectedProjectAgents: [AgentProfile] {
        guard let project = selectedProject else { return [] }
        return controlPlane.agentsByProject[project.id] ?? []
    }

    public var selectedProjectTasks: [DelegatedTask] {
        guard let project = selectedProject else { return [] }
        return controlPlane.tasksByProject[project.id] ?? []
    }

    public var selectedProjectOpenExceptions: [ExceptionAlert] {
        guard let project = selectedProject else { return [] }
        return controlPlane.openExceptionsByProject[project.id] ?? []
    }

    public var allOpenExceptions: [(project: Project, alert: ExceptionAlert)] {
        controlPlane.projects.flatMap { project in
            (controlPlane.openExceptionsByProject[project.id] ?? []).map { (project, $0) }
        }
    }

    public var totalOpenExceptionCount: Int {
        controlPlane.openExceptionsByProject.values.reduce(0) { $0 + $1.count }
    }

    public var selectedAgent: AgentProfile? {
        let agents = selectedProjectAgents
        if let selectedAgentID,
           let match = agents.first(where: { $0.id == selectedAgentID }) {
            return match
        }
        return agents.first(where: { $0.role == .orchestrator }) ?? agents.first
    }

    public var selectedProjectSharedState: [RunSharedStateSummary] {
        guard let project = selectedProject else { return [] }
        return sharedStateByProject[project.id] ?? []
    }

    public var selectedProjectEvents: [RunEvent] {
        guard let project = selectedProject else { return [] }
        return eventsByProject[project.id] ?? []
    }

    public var selectedProjectArtifacts: [ArtifactRecord] {
        guard let project = selectedProject else { return [] }
        return artifactsByProject[project.id] ?? []
    }

    public var selectedAgentPrivateMemory: [SharedStateEntry] {
        guard let agent = selectedAgent else { return [] }
        return privateMemoryByAgent[agent.id] ?? []
    }

    public var selectedLatestBrowserObservation: BrowserObservation? {
        guard let project = selectedProject else { return nil }
        return latestBrowserObservationByProject[project.id]
    }

    public var selectedLatestExecutionResult: ExecutionResult? {
        guard let project = selectedProject else { return nil }
        return latestExecutionResultByProject[project.id]
    }

    // MARK: - Lifecycle & Polling

    public func bootstrapInteractive() async {
        Task.detached(priority: .utility) { [ocrService] in
            await ocrService.warmUpInBackground()
        }
        await reloadAll()
        if selectedProjectID == nil {
            selectedProjectID = controlPlane.projects.first?.id
        }
        if selectedAgentID == nil {
            selectedAgentID = selectedProjectAgents.first?.id
        }
        settleHelmCounter += 1
        ensurePollingState()
    }

    public func reloadAll() async {
        do {
            try await controlPlane.reloadFromStore()
            for project in controlPlane.projects {
                await refreshProjectDetails(projectID: project.id, notifyExceptions: true)
            }
            if selectedProjectID == nil {
                selectedProjectID = controlPlane.projects.first?.id
            }
            if let current = selectedProject,
               !(controlPlane.agentsByProject[current.id] ?? []).contains(where: { $0.id == selectedAgentID }) {
                selectedAgentID = (controlPlane.agentsByProject[current.id] ?? []).first?.id
            }
        } catch {
            bannerErrorMessage = error.localizedDescription
        }
    }

    public func refreshProjectDetails(projectID: UUID, notifyExceptions: Bool = true) async {
        do {
            _ = try await controlPlane.listAgents(projectID: projectID)
            _ = try await controlPlane.listTasks(projectID: projectID)
            let openAlerts = try await controlPlane.listExceptions(projectID: projectID, openOnly: true)
            let shared = try await controlPlane.listSharedState(projectID: projectID)
            let events = try await controlPlane.listEvents(projectID: projectID, limit: 200)
            let artifacts = try await controlPlane.database.listArtifacts(projectID: projectID)

            sharedStateByProject[projectID] = shared
            eventsByProject[projectID] = events
            artifactsByProject[projectID] = artifacts

            let agents = controlPlane.agentsByProject[projectID] ?? []
            for agent in agents {
                let priv = try await controlPlane.database.listSharedState(
                    projectID: projectID,
                    scope: .agentPrivate,
                    ownerAgentID: agent.id
                )
                privateMemoryByAgent[agent.id] = priv
            }

            if let latestHeartbeat = events.last(where: { $0.kind == .heartbeatSteadyOK }) {
                if lastSteadyEventIDByProject[projectID] != latestHeartbeat.id {
                    lastSteadyEventIDByProject[projectID] = latestHeartbeat.id
                    horizonPingCounterByProject[projectID, default: 0] += 1
                }
            }

            let decoder = HelmJSON.makeDecoder()
            var sawExec = false
            var sawBrowser = false
            for event in events.reversed() where event.kind == .toolExecuted {
                guard let payload = event.payloadJSON, let data = payload.data(using: .utf8) else { continue }
                if !sawExec, let execResult = try? decoder.decode(ExecutionResult.self, from: data) {
                    sawExec = true
                    if lastExecutionEventIDByProject[projectID] != event.id {
                        lastExecutionEventIDByProject[projectID] = event.id
                        latestExecutionResultByProject[projectID] = execResult
                    }
                } else if !sawBrowser, let browserObs = try? decoder.decode(BrowserObservation.self, from: data) {
                    sawBrowser = true
                    if lastBrowserEventIDByProject[projectID] != event.id {
                        lastBrowserEventIDByProject[projectID] = event.id
                        latestBrowserObservationByProject[projectID] = browserObs
                    }
                }
                if sawExec && sawBrowser { break }
            }

            if notifyExceptions,
               let project = controlPlane.projects.first(where: { $0.id == projectID }) {
                for alert in openAlerts {
                    await notificationCoordinator.notifyIfNewException(alert, projectName: project.name)
                }
            }
        } catch {
            bannerErrorMessage = error.localizedDescription
        }
    }

    public func selectProject(_ id: UUID) {
        selectedProjectID = id
        selectedAgentID = (controlPlane.agentsByProject[id] ?? []).first?.id
        settleHelmCounter += 1
        Task {
            await refreshProjectDetails(projectID: id, notifyExceptions: false)
        }
    }

    public func stopPollingForTermination() {
        pollingTask?.cancel()
        pollingTask = nil
        pendingStartProjectIDs.removeAll()
        pollingGraceDeadline = nil
    }

    public func ensurePollingState(forceStart: Bool = false) {
        let hasRunning = controlPlane.projects.contains { $0.status == .running }
        let withinGrace = !pendingStartProjectIDs.isEmpty && (pollingGraceDeadline.map { Date() < $0 } ?? false)
        let shouldPoll = forceStart || hasRunning || withinGrace
        if shouldPoll {
            if pollingTask == nil {
                pollingTask = Task { [weak self] in
                    await self?.runPollingLoop()
                }
            }
        } else {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    private func runPollingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { break }
            let shouldContinue = await pollRunningProjects()
            if !shouldContinue {
                pendingStartProjectIDs.removeAll()
                pollingGraceDeadline = nil
                await reloadAll()
                let stillNeeded = controlPlane.projects.contains { $0.status == .running }
                    || (!pendingStartProjectIDs.isEmpty && (pollingGraceDeadline.map { Date() < $0 } ?? false))
                if !stillNeeded {
                    break
                }
            }
        }
        pollingTask = nil
    }

    private func pollRunningProjects() async -> Bool {
        do {
            let list = try await controlPlane.listProjects()
            for project in list {
                if project.status == .running {
                    pendingStartProjectIDs.remove(project.id)
                }
                await refreshProjectDetails(projectID: project.id, notifyExceptions: true)
            }
            let hasRunning = list.contains { $0.status == .running }
            let withinGrace = !pendingStartProjectIDs.isEmpty && (pollingGraceDeadline.map { Date() < $0 } ?? false)
            return hasRunning || withinGrace
        } catch {
            // Transient DB read retry next tick
            let withinGrace = !pendingStartProjectIDs.isEmpty && (pollingGraceDeadline.map { Date() < $0 } ?? false)
            return withinGrace || controlPlane.projects.contains { $0.status == .running }
        }
    }

    public func shutdownBackgroundWork() async {
        stopPollingForTermination()
        let browserService = self.browserService
        let sandboxExecutor = self.sandboxExecutor
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await browserService.closeAllSessions() }
            group.addTask { await sandboxExecutor.shutdownAll() }
        }
    }

    // MARK: - User Actions

    public func createProject(name: String, goal: String, workspaceRoot: URL) async throws {
        let project = try await controlPlane.createProject(name: name, goal: goal, workspaceRoot: workspaceRoot)
        // Automatically ensure an Orchestrator agent exists so new projects are immediately operable
        _ = try await controlPlane.addAgent(
            projectID: project.id,
            name: "Helm Orchestrator",
            role: .orchestrator,
            goal: "Coordinate specialists, track shared state, and surface exceptions only when human intervention is needed.",
            backend: .mock,
            capabilities: [.readSharedState, .proposeSharedState, .delegateTasks, .requestHumanDecision]
        )
        await reloadAll()
        selectProject(project.id)
    }

    public func addAgent(
        projectID: UUID,
        name: String,
        role: AgentRole,
        goal: String,
        backend: LLMBackendKind,
        capabilities: Set<AgentCapability>
    ) async throws {
        let agent = try await controlPlane.addAgent(
            projectID: projectID,
            name: name,
            role: role,
            goal: goal,
            backend: backend,
            capabilities: capabilities
        )
        await refreshProjectDetails(projectID: projectID, notifyExceptions: false)
        selectedAgentID = agent.id
    }

    public func startSelectedProject() async {
        guard let project = selectedProject else { return }
        bannerErrorMessage = nil
        await notificationCoordinator.requestAuthorizationIfNeeded()
        do {
            try await controlPlane.startProject(projectID: project.id)
            pendingStartProjectIDs.insert(project.id)
            pollingGraceDeadline = Date().addingTimeInterval(3.0)
            settleHelmCounter += 1
            await reloadAll()
            ensurePollingState(forceStart: true)
        } catch {
            bannerErrorMessage = error.localizedDescription
        }
    }

    public func pauseSelectedProject() async {
        guard let project = selectedProject else { return }
        do {
            try await controlPlane.pauseProject(projectID: project.id)
            pendingStartProjectIDs.remove(project.id)
            if pendingStartProjectIDs.isEmpty {
                pollingGraceDeadline = nil
            }
            await reloadAll()
            ensurePollingState()
        } catch {
            bannerErrorMessage = error.localizedDescription
        }
    }

    public func pauseAllProjects() async {
        for project in controlPlane.projects where project.status == .running {
            try? await controlPlane.pauseProject(projectID: project.id)
        }
        pendingStartProjectIDs.removeAll()
        pollingGraceDeadline = nil
        await reloadAll()
        ensurePollingState()
    }

    public func simulateCondition(_ kind: SimulatedConditionKind) async {
        guard let project = selectedProject else { return }
        bannerErrorMessage = nil
        do {
            try await controlPlane.simulateCondition(projectID: project.id, kind: kind)
            await reloadAll()
            ensurePollingState()
        } catch {
            bannerErrorMessage = error.localizedDescription
        }
    }

    public func resolveException(_ alert: ExceptionAlert, resolution: ExceptionResolution) async {
        bannerErrorMessage = nil
        do {
            _ = try await controlPlane.resolveException(exceptionID: alert.id, resolution: resolution)
            notificationCoordinator.clearNotified(exceptionID: alert.id)
            var restarted = false
            if resolution != .abort {
                let tasks = try await controlPlane.listTasks(projectID: alert.projectID)
                if tasks.isEmpty || tasks.contains(where: { $0.status == .queued || $0.status == .running || $0.status == .blocked }) {
                    try await controlPlane.startProject(projectID: alert.projectID)
                    pendingStartProjectIDs.insert(alert.projectID)
                    pollingGraceDeadline = Date().addingTimeInterval(3.0)
                    restarted = true
                }
            }
            await reloadAll()
            ensurePollingState(forceStart: restarted)
        } catch {
            bannerErrorMessage = error.localizedDescription
        }
    }

    public func runQuickSandboxCheck(command: String, preferredMode: IsolationMode? = nil) async {
        guard let project = selectedProject else { return }
        isRunningDiagnostic = true
        defer { isRunningDiagnostic = false }
        do {
            let req = ExecutionRequest(
                projectID: project.id,
                workspacePath: project.workspaceRoot,
                command: command,
                preferredMode: preferredMode,
                timeoutSeconds: 20,
                maxOutputBytes: 32_768
            )
            let result = try await sandboxExecutor.execute(req)
            latestExecutionResultByProject[project.id] = result
        } catch {
            bannerErrorMessage = error.localizedDescription
        }
    }

    public func runQuickBrowserCheck(url: String) async {
        guard let project = selectedProject else { return }
        isRunningDiagnostic = true
        defer { isRunningDiagnostic = false }
        do {
            let sessionID = try await browserService.openSession(projectID: project.id)
            defer {
                Task { await browserService.closeSession(sessionID) }
            }
            let obs = try await browserService.perform(.navigate(url: url), sessionID: sessionID, timeoutSeconds: 30)
            latestBrowserObservationByProject[project.id] = obs
        } catch {
            bannerErrorMessage = error.localizedDescription
        }
    }
}
