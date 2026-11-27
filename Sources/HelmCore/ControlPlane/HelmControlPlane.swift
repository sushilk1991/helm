import Foundation
import Observation

public enum ControlPlaneError: Error, Sendable, LocalizedError, Equatable {
    case invalidInput(String)
    case unwritableWorkspace(String)
    case projectNotFound(UUID)
    case duplicateAgentName(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let msg): return "Invalid input: \(msg)"
        case .unwritableWorkspace(let path): return "Workspace is not writable: \(path)"
        case .projectNotFound(let id): return "Project not found: \(id.uuidString)"
        case .duplicateAgentName(let name): return "Agent named '\(name)' already exists in this project."
        }
    }
}

@MainActor
@Observable
public final class HelmControlPlane: Sendable {
    public private(set) var projects: [Project] = []
    public private(set) var openExceptionsByProject: [UUID: [ExceptionAlert]] = [:]
    public private(set) var agentsByProject: [UUID: [AgentProfile]] = [:]
    public private(set) var tasksByProject: [UUID: [DelegatedTask]] = [:]

    public let database: HelmDatabase
    public let sharedStateStore: SharedStateStore
    private let providerRegistry: LLMProviderRegistry
    private let sandboxExecutor: (any SandboxExecutor)?
    private let browserService: (any BrowserOCRService)?
    private let environment: [String: String]
    private var activeRunTasks: [UUID: Task<Void, Never>] = [:]
    private var runGenerationByProject: [UUID: UInt64] = [:]
    private var hasReconciledBoot: Bool = false
    private var bootReconcileTask: Task<Void, Error>?

    public init(
        database: HelmDatabase,
        providerRegistry: LLMProviderRegistry = .makeDefault(),
        sandboxExecutor: (any SandboxExecutor)? = nil,
        browserService: (any BrowserOCRService)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.database = database
        self.sharedStateStore = SharedStateStore(database: database)
        self.providerRegistry = providerRegistry
        self.sandboxExecutor = sandboxExecutor
        self.browserService = browserService
        self.environment = environment
    }

    public convenience init(
        databasePath: String = HelmDatabase.defaultDatabasePath(),
        providerRegistry: LLMProviderRegistry = .makeDefault(),
        sandboxExecutor: (any SandboxExecutor)? = nil,
        browserService: (any BrowserOCRService)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let db = try HelmDatabase(path: databasePath)
        self.init(
            database: db,
            providerRegistry: providerRegistry,
            sandboxExecutor: sandboxExecutor,
            browserService: browserService,
            environment: environment
        )
    }

    // MARK: - Locked Control Plane Surface

    public func createProject(name: String, goal: String, workspaceRoot: URL) async throws -> Project {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ControlPlaneError.invalidInput("Project name cannot be empty.")
        }
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else {
            throw ControlPlaneError.invalidInput("Project goal cannot be empty.")
        }

        try Self.validateAndPrepareWorkspace(workspaceRoot)

        let project = Project(
            name: trimmedName,
            goal: trimmedGoal,
            workspaceRoot: workspaceRoot
        )
        try await database.insertProject(project)
        try await database.appendEvent(RunEvent(
            projectID: project.id,
            kind: .projectCreated,
            summary: "Created project '\(project.name)'",
            trustLevel: .humanAuthoritative
        ))
        try await refreshSnapshots(projectID: project.id)
        return project
    }

    public func addAgent(
        projectID: UUID,
        name: String,
        role: AgentRole,
        goal: String,
        backend: LLMBackendKind,
        capabilities: Set<AgentCapability> = [.readSharedState, .proposeSharedState, .requestHumanDecision],
        personality: AgentPersonality? = nil,
        personalityNotes: String = ""
    ) async throws -> AgentProfile {
        guard try await database.fetchProject(id: projectID) != nil else {
            throw ControlPlaneError.projectNotFound(projectID)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ControlPlaneError.invalidInput("Agent name cannot be empty.")
        }
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else {
            throw ControlPlaneError.invalidInput("Agent goal cannot be empty.")
        }

        let existing = try await database.listAgents(projectID: projectID)
        if existing.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            throw ControlPlaneError.duplicateAgentName(trimmedName)
        }

        let agent = AgentProfile(
            projectID: projectID,
            name: trimmedName,
            role: role,
            goal: trimmedGoal,
            personality: personality ?? AgentPersonality.defaultForRole(role),
            personalityNotes: personalityNotes.trimmingCharacters(in: .whitespacesAndNewlines),
            capabilities: capabilities,
            backend: backend
        )
        try await database.insertAgent(agent)
        try await database.appendEvent(RunEvent(
            projectID: projectID,
            agentID: agent.id,
            kind: .agentAdded,
            summary: "Added agent '\(agent.name)' (\(agent.role.rawValue), \(agent.personality.displayName), backend: \(agent.backend.rawValue))",
            trustLevel: .humanAuthoritative
        ))
        try await refreshSnapshots(projectID: projectID)
        return agent
    }

    public func updateAgent(
        agentID: UUID,
        name: String? = nil,
        goal: String? = nil,
        backend: LLMBackendKind? = nil,
        personality: AgentPersonality? = nil,
        personalityNotes: String? = nil,
        capabilities: Set<AgentCapability>? = nil,
        modelOverride: String?? = nil
    ) async throws -> AgentProfile {
        guard var agent = try await database.fetchAgent(id: agentID) else {
            throw HelmDatabaseError.notFound("Agent \(agentID.uuidString)")
        }

        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ControlPlaneError.invalidInput("Agent name cannot be empty.")
            }
            let siblings = try await database.listAgents(projectID: agent.projectID)
            if siblings.contains(where: { $0.id != agent.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                throw ControlPlaneError.duplicateAgentName(trimmed)
            }
            agent.name = trimmed
        }
        if let goal {
            let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ControlPlaneError.invalidInput("Agent goal cannot be empty.")
            }
            agent.goal = trimmed
        }
        if let backend { agent.backend = backend }
        if let personality { agent.personality = personality }
        if let personalityNotes {
            agent.personalityNotes = personalityNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let capabilities { agent.capabilities = capabilities }
        if let modelOverride { agent.modelOverride = modelOverride }
        agent.updatedAt = Date()

        try await database.updateAgent(agent)
        try await database.appendEvent(RunEvent(
            projectID: agent.projectID,
            agentID: agent.id,
            kind: .agentStateChanged,
            summary: "Updated \(agent.name) (\(agent.personality.displayName), \(agent.backend.rawValue))",
            trustLevel: .humanAuthoritative
        ))
        try await refreshSnapshots(projectID: agent.projectID)
        return agent
    }

    public func startProject(projectID: UUID) async throws {
        guard try await database.fetchProject(id: projectID) != nil else {
            throw ControlPlaneError.projectNotFound(projectID)
        }
        let generation = (runGenerationByProject[projectID] ?? 0) &+ 1
        runGenerationByProject[projectID] = generation

        if let previous = activeRunTasks[projectID] {
            previous.cancel()
            await previous.value
        }

        guard runGenerationByProject[projectID] == generation else {
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.runProjectUntilSettled(projectID: projectID)
            } catch is CancellationError {
                // Expected on pauseProject or superseding startProject
            } catch {
                await self.recordUnexpectedRunFailure(projectID: projectID, error: error)
            }
            if self.runGenerationByProject[projectID] == generation {
                self.activeRunTasks.removeValue(forKey: projectID)
            }
        }
        activeRunTasks[projectID] = task
    }

    public func pauseProject(projectID: UUID) async throws {
        guard try await database.fetchProject(id: projectID) != nil else {
            throw ControlPlaneError.projectNotFound(projectID)
        }
        let generation = (runGenerationByProject[projectID] ?? 0) &+ 1
        runGenerationByProject[projectID] = generation

        if let previous = activeRunTasks[projectID] {
            previous.cancel()
            await previous.value
        }

        guard runGenerationByProject[projectID] == generation else {
            return
        }

        activeRunTasks.removeValue(forKey: projectID)
        let openExceptions = try await database.listExceptions(projectID: projectID, openOnly: true)
        if openExceptions.isEmpty {
            try await database.updateProjectStatus(id: projectID, status: .paused)
            try await database.appendEvent(RunEvent(
                projectID: projectID,
                kind: .projectPaused,
                summary: "Project paused by operator",
                trustLevel: .humanAuthoritative
            ))
        } else {
            try await database.updateProjectStatus(id: projectID, status: .held)
        }
        try await refreshSnapshots(projectID: projectID)
    }

    @discardableResult
    public func resolveException(exceptionID: UUID, resolution: ExceptionResolution) async throws -> ExceptionAlert {
        let gate = HumanDecisionGate(database: database)
        let resolved = try await gate.resolve(exceptionID: exceptionID, resolution: resolution)

        // If operator explicitly approved an unauthorized capability request, grant the requested capability
        // so resuming the agent doesn't immediately re-trip the exact same hold.
        if resolution == .approve,
           let agentID = resolved.agentID,
           resolved.title.localizedCaseInsensitiveContains("Unauthorized Capability"),
           var agent = try await database.fetchAgent(id: agentID) {
            let lower = resolved.summary.lowercased()
            var changed = false
            if lower.contains("codeexec") || lower.contains("run_command") {
                agent.capabilities.insert(.codeExec)
                changed = true
            }
            if lower.contains("browser") || lower.contains("browser_act") {
                agent.capabilities.insert(.browser)
                agent.capabilities.insert(.ocr)
                changed = true
            }
            if changed {
                agent.updatedAt = Date()
                try await database.updateAgent(agent)
                try await database.appendEvent(RunEvent(
                    projectID: resolved.projectID,
                    agentID: agent.id,
                    kind: .agentStateChanged,
                    summary: "Granted approved capability to \(agent.name)",
                    trustLevel: .humanAuthoritative
                ))
            }
        }

        try await refreshSnapshots(projectID: resolved.projectID)
        return resolved
    }

    public func simulateCondition(projectID: UUID, kind: SimulatedConditionKind) async throws {
        guard try await database.fetchProject(id: projectID) != nil else {
            throw ControlPlaneError.projectNotFound(projectID)
        }
        let generation = (runGenerationByProject[projectID] ?? 0) &+ 1
        runGenerationByProject[projectID] = generation

        if let previous = activeRunTasks[projectID] {
            previous.cancel()
            await previous.value
        }

        guard runGenerationByProject[projectID] == generation else {
            return
        }

        let simTask = Task { @MainActor [weak self] () -> Result<Void, Error> in
            guard let self else { return .success(()) }
            do {
                _ = try await self.runProjectUntilSettled(
                    projectID: projectID,
                    maxSteps: nil,
                    simulatedCondition: kind
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        let trackedTask = Task { @MainActor [weak self] in
            _ = await withTaskCancellationHandler {
                await simTask.value
            } onCancel: {
                simTask.cancel()
            }
            if let self, self.runGenerationByProject[projectID] == generation {
                self.activeRunTasks.removeValue(forKey: projectID)
            }
        }
        activeRunTasks[projectID] = trackedTask
        let result = await simTask.value
        await trackedTask.value
        if case .failure(let error) = result, !(error is CancellationError) {
            throw error
        }
    }

    private func recordUnexpectedRunFailure(projectID: UUID, error: Error) async {
        let gate = HumanDecisionGate(database: database)
        let alert = ExceptionAlert(
            projectID: projectID,
            kind: .providerFailure,
            severity: .critical,
            title: "Orchestrator Execution Error",
            summary: error.localizedDescription,
            suggestedOptions: ["retry", "redirect", "abort"],
            dedupKey: "run_failure:\(projectID.uuidString):\(error.localizedDescription.prefix(64))"
        )
        _ = try? await gate.triggerHold(alert: alert)
        try? await database.appendEvent(RunEvent(
            projectID: projectID,
            kind: .exceptionRaised,
            summary: "Unexpected orchestrator run failure: \(error.localizedDescription)",
            trustLevel: .orchestratorVerified
        ))
        try? await refreshSnapshots(projectID: projectID)
    }

    // MARK: - Execution & Queries

    public func runProjectUntilSettled(
        projectID: UUID,
        maxSteps: Int? = nil,
        simulatedCondition: SimulatedConditionKind? = nil
    ) async throws -> ProjectRunReport {
        guard try await database.fetchProject(id: projectID) != nil else {
            throw ControlPlaneError.projectNotFound(projectID)
        }
        try await reconcileBootIfNeeded()
        let orchestrator = OrchestratorActor(
            projectID: projectID,
            database: database,
            sharedStateStore: sharedStateStore,
            providerRegistry: providerRegistry,
            sandboxExecutor: sandboxExecutor,
            browserService: browserService,
            environment: environment
        )
        let report = try await orchestrator.run(maxSteps: maxSteps, simulatedCondition: simulatedCondition)
        try await refreshSnapshots(projectID: projectID)
        return report
    }

    public func listProjects() async throws -> [Project] {
        let list = try await database.listProjects()
        self.projects = list
        return list
    }

    public func fetchProject(id: UUID) async throws -> Project? {
        try await database.fetchProject(id: id)
    }

    public func listAgents(projectID: UUID) async throws -> [AgentProfile] {
        guard try await database.fetchProject(id: projectID) != nil else {
            throw ControlPlaneError.projectNotFound(projectID)
        }
        let list = try await database.listAgents(projectID: projectID)
        self.agentsByProject[projectID] = list
        return list
    }

    public func listTasks(projectID: UUID) async throws -> [DelegatedTask] {
        let list = try await database.listTasks(projectID: projectID)
        self.tasksByProject[projectID] = list
        return list
    }

    public func listSharedState(projectID: UUID) async throws -> [RunSharedStateSummary] {
        guard try await database.fetchProject(id: projectID) != nil else {
            throw ControlPlaneError.projectNotFound(projectID)
        }
        let entries = try await database.listSharedState(projectID: projectID, scope: .projectShared)
        return entries.map(RunSharedStateSummary.init(from:))
    }

    public func listExceptions(projectID: UUID, openOnly: Bool = false) async throws -> [ExceptionAlert] {
        guard try await database.fetchProject(id: projectID) != nil else {
            throw ControlPlaneError.projectNotFound(projectID)
        }
        let list = try await database.listExceptions(projectID: projectID, openOnly: openOnly)
        if openOnly {
            self.openExceptionsByProject[projectID] = list
        }
        return list
    }

    public func listEvents(projectID: UUID, limit: Int = 200) async throws -> [RunEvent] {
        try await database.listEvents(projectID: projectID, limit: limit)
    }

    public func reloadFromStore() async throws {
        try await reconcileBootIfNeeded()
        let loaded = try await database.listProjects()
        self.projects = loaded
        for project in loaded {
            self.agentsByProject[project.id] = try await database.listAgents(projectID: project.id)
            self.tasksByProject[project.id] = try await database.listTasks(projectID: project.id)
            self.openExceptionsByProject[project.id] = try await database.listExceptions(projectID: project.id, openOnly: true)
        }
    }

    private func reconcileBootIfNeeded() async throws {
        if hasReconciledBoot { return }
        if let existingTask = bootReconcileTask {
            try await existingTask.value
            return
        }
        let db = self.database
        let task = Task {
            _ = try await db.reconcileOrphanedRunsOnBoot()
        }
        bootReconcileTask = task
        do {
            try await task.value
            hasReconciledBoot = true
            bootReconcileTask = nil
        } catch {
            bootReconcileTask = nil
            throw error
        }
    }

    private func refreshSnapshots(projectID: UUID) async throws {
        self.projects = try await database.listProjects()
        self.agentsByProject[projectID] = try await database.listAgents(projectID: projectID)
        self.tasksByProject[projectID] = try await database.listTasks(projectID: projectID)
        self.openExceptionsByProject[projectID] = try await database.listExceptions(projectID: projectID, openOnly: true)
    }

    private static func validateAndPrepareWorkspace(_ workspaceRoot: URL) throws {
        let fm = FileManager.default
        let path = workspaceRoot.path
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw ControlPlaneError.unwritableWorkspace("\(path) exists and is not a directory")
            }
        } else {
            do {
                try fm.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
            } catch {
                throw ControlPlaneError.unwritableWorkspace("\(path): \(error.localizedDescription)")
            }
        }

        guard fm.isWritableFile(atPath: path) else {
            throw ControlPlaneError.unwritableWorkspace("\(path) is read-only or not writable")
        }

        // Verify actual write capability with an ephemeral probe file (handles POSIX chmod 0555 & ACLs)
        let probeURL = workspaceRoot.appendingPathComponent(".helm_write_probe_\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probeURL)
            try? fm.removeItem(at: probeURL)
        } catch {
            throw ControlPlaneError.unwritableWorkspace("\(path): \(error.localizedDescription)")
        }
    }
}
