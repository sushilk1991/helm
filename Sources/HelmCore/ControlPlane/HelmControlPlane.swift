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
    public typealias ChatDispatchHook = @Sendable (
        _ project: Project,
        _ message: ChatMessage,
        _ controlPlane: HelmControlPlane
    ) async throws -> [ChatMessage]

    public private(set) var projects: [Project] = []
    public private(set) var openExceptionsByProject: [UUID: [ExceptionAlert]] = [:]
    public private(set) var agentsByProject: [UUID: [AgentProfile]] = [:]
    public private(set) var tasksByProject: [UUID: [DelegatedTask]] = [:]
    public private(set) var chatMessagesByProject: [UUID: [ChatMessage]] = [:]
    public private(set) var workFeedByProject: [UUID: [AgentWorkEntry]] = [:]

    public var chatDispatchHook: ChatDispatchHook?

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

    public func createProject(
        name: String,
        goal: String,
        workspaceRoot: URL,
        sandboxTrustPolicy: SandboxTrustPolicy = .standardWorkspace
    ) async throws -> Project {
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
            workspaceRoot: workspaceRoot,
            sandboxTrustPolicy: sandboxTrustPolicy
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

    @discardableResult
    public func updateProjectTrustPolicy(
        projectID: UUID,
        policy: SandboxTrustPolicy
    ) async throws -> Project {
        guard try await database.fetchProject(id: projectID) != nil else {
            throw ControlPlaneError.projectNotFound(projectID)
        }
        try await database.updateProjectTrustPolicy(id: projectID, policy: policy)
        try await database.appendEvent(RunEvent(
            projectID: projectID,
            kind: .sharedStateWritten,
            summary: "Updated project trust policy to \(policy.displayName)",
            trustLevel: .humanAuthoritative
        ))
        try await refreshSnapshots(projectID: projectID)
        guard let updated = try await database.fetchProject(id: projectID) else {
            throw ControlPlaneError.projectNotFound(projectID)
        }
        return updated
    }

    public func addAgent(
        projectID: UUID,
        name: String,
        role: AgentRole,
        goal: String,
        backend: LLMBackendKind,
        capabilities: Set<AgentCapability>? = nil,
        personality: AgentPersonality? = nil,
        personalityNotes: String = "",
        systemPrompt: String? = nil
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

        let resolvedCapabilities = capabilities ?? AgentProfile.RolePreset.preset(for: role).capabilities
        let agent = AgentProfile(
            projectID: projectID,
            name: trimmedName,
            role: role,
            goal: trimmedGoal,
            personality: personality ?? AgentPersonality.defaultForRole(role),
            personalityNotes: personalityNotes.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: systemPrompt,
            capabilities: resolvedCapabilities,
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
        modelOverride: String?? = nil,
        systemPrompt: String? = nil
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
        if let systemPrompt {
            let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPrompt.isEmpty else {
                throw ControlPlaneError.invalidInput("Agent system prompt cannot be empty.")
            }
            agent.systemPrompt = trimmedPrompt
        }
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
        guard try await database.fetchProject(id: projectID) != nil else {
            throw ControlPlaneError.projectNotFound(projectID)
        }
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

    public func listEvents(projectID: UUID, limit: Int = 1_000) async throws -> [RunEvent] {
        try await database.listEvents(projectID: projectID, limit: limit)
    }

    // MARK: - Chat & Live Work Feed

    public static func makeOrchestratedChatDispatchHook() -> ChatDispatchHook {
        { project, incoming, controlPlane in
            let orchestrator = OrchestratorActor(
                projectID: project.id,
                database: controlPlane.database,
                sharedStateStore: controlPlane.sharedStateStore,
                providerRegistry: controlPlane.providerRegistry,
                sandboxExecutor: controlPlane.sandboxExecutor,
                browserService: controlPlane.browserService,
                environment: controlPlane.environment
            )
            return try await orchestrator.handleChatMessage(incoming)
        }
    }

    public func enableAutonomousChatDispatch() {
        self.chatDispatchHook = Self.makeOrchestratedChatDispatchHook()
    }

    @discardableResult
    public func sendChatMessageAndWait(
        projectID: UUID,
        channel: ChatChannelKind,
        content: String,
        senderKind: ChatSenderKind = .user,
        senderAgentID: UUID? = nil,
        senderName: String? = nil,
        referencedFiles: [String] = [],
        relatedTaskID: UUID? = nil,
        messageID: UUID = UUID()
    ) async throws -> ChatMessage {
        let overrideHook: ChatDispatchHook? = (chatDispatchHook == nil && senderKind == .user)
            ? Self.makeOrchestratedChatDispatchHook()
            : nil
        let message = try await sendChatMessageImpl(
            projectID: projectID,
            channel: channel,
            content: content,
            senderKind: senderKind,
            senderAgentID: senderAgentID,
            senderName: senderName,
            referencedFiles: referencedFiles,
            relatedTaskID: relatedTaskID,
            dispatchHookOverride: overrideHook,
            messageID: messageID
        )
        try await refreshSnapshots(projectID: projectID)
        return message
    }

    public func listChatMessages(
        projectID: UUID,
        channel: ChatChannelKind? = nil,
        limit: Int = 200
    ) async throws -> [ChatMessage] {
        guard try await database.fetchProject(id: projectID) != nil else {
            throw ControlPlaneError.projectNotFound(projectID)
        }
        let messages = try await database.listChatMessages(
            projectID: projectID,
            channel: channel,
            limit: limit
        )
        if channel == nil {
            self.chatMessagesByProject[projectID] = messages
        }
        return messages
    }

    @discardableResult
    public func appendChatMessage(_ message: ChatMessage) async throws -> ChatMessage {
        guard try await database.fetchProject(id: message.projectID) != nil else {
            throw ControlPlaneError.projectNotFound(message.projectID)
        }
        let agents = try await database.listAgents(projectID: message.projectID)
        try await validateChatMessageFields(
            projectID: message.projectID,
            channel: message.channelKind,
            content: message.content,
            senderAgentID: message.senderAgentID,
            relatedTaskID: message.relatedTaskID,
            agents: agents
        )
        try await database.insertChatMessage(message)
        self.chatMessagesByProject[message.projectID] = try await database.listChatMessages(
            projectID: message.projectID,
            channel: nil,
            limit: 200
        )
        return message
    }

    @discardableResult
    public func sendChatMessage(
        projectID: UUID,
        channel: ChatChannelKind,
        content: String,
        senderKind: ChatSenderKind = .user,
        senderAgentID: UUID? = nil,
        senderName: String? = nil,
        referencedFiles: [String] = [],
        relatedTaskID: UUID? = nil,
        messageID: UUID = UUID()
    ) async throws -> ChatMessage {
        try await sendChatMessageImpl(
            projectID: projectID,
            channel: channel,
            content: content,
            senderKind: senderKind,
            senderAgentID: senderAgentID,
            senderName: senderName,
            referencedFiles: referencedFiles,
            relatedTaskID: relatedTaskID,
            dispatchHookOverride: nil,
            messageID: messageID
        )
    }

    private func sendChatMessageImpl(
        projectID: UUID,
        channel: ChatChannelKind,
        content: String,
        senderKind: ChatSenderKind,
        senderAgentID: UUID?,
        senderName: String?,
        referencedFiles: [String],
        relatedTaskID: UUID?,
        dispatchHookOverride: ChatDispatchHook?,
        messageID: UUID = UUID()
    ) async throws -> ChatMessage {
        guard let project = try await database.fetchProject(id: projectID) else {
            throw ControlPlaneError.projectNotFound(projectID)
        }
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let agents = try await database.listAgents(projectID: projectID)
        try await validateChatMessageFields(
            projectID: projectID,
            channel: channel,
            content: trimmedContent,
            senderAgentID: senderAgentID,
            relatedTaskID: relatedTaskID,
            agents: agents
        )

        let resolvedSenderName: String
        if let senderName {
            let trimmedSender = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSender.isEmpty {
                resolvedSenderName = trimmedSender
            } else {
                resolvedSenderName = Self.defaultSenderName(
                    senderKind: senderKind,
                    senderAgentID: senderAgentID,
                    agents: agents
                )
            }
        } else {
            resolvedSenderName = Self.defaultSenderName(
                senderKind: senderKind,
                senderAgentID: senderAgentID,
                agents: agents
            )
        }

        let message = ChatMessage(
            id: messageID,
            projectID: projectID,
            channelKind: channel,
            senderKind: senderKind,
            senderAgentID: senderAgentID,
            senderName: resolvedSenderName,
            content: trimmedContent,
            referencedFiles: referencedFiles,
            relatedTaskID: relatedTaskID
        )
        try await database.insertChatMessage(message)
        self.chatMessagesByProject[projectID] = try await database.listChatMessages(
            projectID: projectID,
            channel: nil,
            limit: 200
        )

        let effectiveHook = dispatchHookOverride ?? chatDispatchHook
        if senderKind == .user, let hook = effectiveHook {
            let replies = try await hook(project, message, self)
            if !replies.isEmpty {
                let currentAgents = try await database.listAgents(projectID: projectID)
                var unpersistedReplies: [ChatMessage] = []
                var seenReplyIDs: Set<UUID> = []
                for reply in replies {
                    guard reply.projectID == projectID else {
                        throw ControlPlaneError.invalidInput(
                            "Chat reply project '\(reply.projectID.uuidString)' does not match project '\(projectID.uuidString)'."
                        )
                    }
                    if let existing = try await database.fetchChatMessage(id: reply.id) {
                        guard existing.projectID == projectID else {
                            throw ControlPlaneError.invalidInput(
                                "Existing chat reply '\(reply.id.uuidString)' does not belong to project '\(projectID.uuidString)'."
                            )
                        }
                        continue
                    }
                    try await validateChatMessageFields(
                        projectID: projectID,
                        channel: reply.channelKind,
                        content: reply.content,
                        senderAgentID: reply.senderAgentID,
                        relatedTaskID: reply.relatedTaskID,
                        agents: currentAgents
                    )
                    if seenReplyIDs.insert(reply.id).inserted {
                        unpersistedReplies.append(reply)
                    }
                }
                for reply in unpersistedReplies {
                    try await database.insertChatMessage(reply)
                }
                self.chatMessagesByProject[projectID] = try await database.listChatMessages(
                    projectID: projectID,
                    channel: nil,
                    limit: 200
                )
            }
        }

        return message
    }

    private func validateChatMessageFields(
        projectID: UUID,
        channel: ChatChannelKind,
        content: String,
        senderAgentID: UUID?,
        relatedTaskID: UUID?,
        agents: [AgentProfile]
    ) async throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ControlPlaneError.invalidInput("Chat message content cannot be empty.")
        }
        if case .direct(let targetAgentID) = channel {
            guard agents.contains(where: { $0.id == targetAgentID }) else {
                throw ControlPlaneError.invalidInput("Target agent '\(targetAgentID.uuidString)' does not belong to project.")
            }
        }
        if let senderAgentID {
            guard agents.contains(where: { $0.id == senderAgentID }) else {
                throw ControlPlaneError.invalidInput("Sender agent '\(senderAgentID.uuidString)' does not belong to project.")
            }
        }
        if let relatedTaskID {
            guard let task = try await database.fetchTask(id: relatedTaskID),
                  task.projectID == projectID else {
                throw ControlPlaneError.invalidInput("Related task '\(relatedTaskID.uuidString)' does not belong to project.")
            }
        }
    }

    public func listAgentWorkFeed(
        projectID: UUID,
        agentID: UUID? = nil,
        limit: Int = 200
    ) async throws -> [AgentWorkEntry] {
        guard try await database.fetchProject(id: projectID) != nil else {
            throw ControlPlaneError.projectNotFound(projectID)
        }
        let entries = try await database.listAgentWorkEntries(
            projectID: projectID,
            agentID: agentID,
            limit: limit
        )
        if agentID == nil {
            self.workFeedByProject[projectID] = entries
        }
        return entries
    }

    @discardableResult
    public func recordAgentWorkEntry(_ entry: AgentWorkEntry) async throws -> AgentWorkEntry {
        guard try await database.fetchProject(id: entry.projectID) != nil else {
            throw ControlPlaneError.projectNotFound(entry.projectID)
        }
        let trimmedSummary = entry.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else {
            throw ControlPlaneError.invalidInput("Agent work entry summary cannot be empty.")
        }
        guard entry.stepNumber >= 0 else {
            throw ControlPlaneError.invalidInput("Agent work entry step number cannot be negative.")
        }
        let agents = try await database.listAgents(projectID: entry.projectID)
        guard agents.contains(where: { $0.id == entry.agentID }) else {
            throw ControlPlaneError.invalidInput("Agent '\(entry.agentID.uuidString)' does not belong to project.")
        }
        if let taskID = entry.taskID {
            guard let task = try await database.fetchTask(id: taskID),
                  task.projectID == entry.projectID else {
                throw ControlPlaneError.invalidInput("Task '\(taskID.uuidString)' does not belong to project.")
            }
        }
        try await database.insertAgentWorkEntry(entry)
        self.workFeedByProject[entry.projectID] = try await database.listAgentWorkEntries(
            projectID: entry.projectID,
            agentID: nil,
            limit: 200
        )
        return entry
    }

    private static func defaultSenderName(
        senderKind: ChatSenderKind,
        senderAgentID: UUID?,
        agents: [AgentProfile]
    ) -> String {
        switch senderKind {
        case .user:
            return "You"
        case .agent, .orchestrator:
            if let senderAgentID, let match = agents.first(where: { $0.id == senderAgentID }) {
                return match.name
            }
            return senderKind == .orchestrator ? "Helm Orchestrator" : "Agent"
        case .system:
            return "Helm"
        }
    }

    public func reloadFromStore() async throws {
        try await reconcileBootIfNeeded()
        let loaded = try await database.listProjects()
        self.projects = loaded
        for project in loaded {
            self.agentsByProject[project.id] = try await database.listAgents(projectID: project.id)
            self.tasksByProject[project.id] = try await database.listTasks(projectID: project.id)
            self.openExceptionsByProject[project.id] = try await database.listExceptions(projectID: project.id, openOnly: true)
            self.chatMessagesByProject[project.id] = try await database.listChatMessages(projectID: project.id, channel: nil, limit: 200)
            self.workFeedByProject[project.id] = try await database.listAgentWorkEntries(projectID: project.id, agentID: nil, limit: 200)
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
        self.chatMessagesByProject[projectID] = try await database.listChatMessages(projectID: projectID, channel: nil, limit: 200)
        self.workFeedByProject[projectID] = try await database.listAgentWorkEntries(projectID: projectID, agentID: nil, limit: 200)
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
