import Foundation
import HelmBrowser
import HelmCore
import HelmIsolation
import Observation

public struct LocalEnvironmentStatus: Sendable, Equatable {
    public let virtualizationAvailable: Bool
    public let chromeAvailable: Bool
    public let claudeCLIAvailable: Bool
    public let codexCLIAvailable: Bool
    public let agyCLIAvailable: Bool
    public let piCLIAvailable: Bool
    public let foundationModelsSupported: Bool

    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) -> LocalEnvironmentStatus {
        let fm = FileManager.default
        let chromePath = environment["HELM_CHROME_PATH"] ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let chrome = fm.isExecutableFile(atPath: chromePath)
        let claude = isToolOnPath("claude", overrideKey: "HELM_CLAUDE_PATH", environment: environment)
        let codex = isToolOnPath("codex", overrideKey: "HELM_CODEX_PATH", environment: environment)
        let agy = isToolOnPath("agy", overrideKey: "HELM_AGY_PATH", environment: environment)
        let pi = isToolOnPath("pi", overrideKey: "HELM_PI_PATH", environment: environment)
            || isToolOnPath("pycli", overrideKey: "HELM_PI_PATH", environment: environment)
        let supportsFM: Bool
        if #available(macOS 26.0, *) {
            supportsFM = true
        } else {
            supportsFM = false
        }
        return LocalEnvironmentStatus(
            virtualizationAvailable: EntitlementChecker.isVirtualizationAvailable(),
            chromeAvailable: chrome,
            claudeCLIAvailable: claude,
            codexCLIAvailable: codex,
            agyCLIAvailable: agy,
            piCLIAvailable: pi,
            foundationModelsSupported: supportsFM
        )
    }

    public var recommendedBackend: LLMBackendKind {
        if claudeCLIAvailable { return .claudeCLI }
        if codexCLIAvailable { return .codexCLI }
        if agyCLIAvailable { return .agyCLI }
        if piCLIAvailable { return .piCLI }
        if foundationModelsSupported { return .foundationModels }
        return .mock
    }

    private static func isToolOnPath(_ name: String, overrideKey: String, environment: [String: String]) -> Bool {
        let fm = FileManager.default
        if let custom = environment[overrideKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty,
           fm.isExecutableFile(atPath: custom) {
            return true
        }
        let searchDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "\(NSHomeDirectory())/.bun/bin",
            "\(NSHomeDirectory())/.gemini/antigravity-cli/bin",
        ] + (environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
        for dir in searchDirs {
            let full = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: full) {
                return true
            }
        }
        return false
    }
}

public enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    case agent = "Agent"
    case activity = "Activity"
    case timeline = "Timeline"

    public var id: String { rawValue }
}

public enum WorkspaceSecondaryTab: String, CaseIterable, Identifiable, Sendable {
    case liveWork = "Live Work"
    case tasks = "Tasks"
    case memory = "Memory"

    public var id: String { rawValue }
}

public struct ChatSendOutcome: Sendable, Equatable {
    public let succeeded: Bool
    public let didPersistUserMessage: Bool

    public var shouldRestoreDraft: Bool {
        !succeeded && !didPersistUserMessage
    }

    public init(succeeded: Bool, didPersistUserMessage: Bool) {
        self.succeeded = succeeded
        self.didPersistUserMessage = didPersistUserMessage
    }
}

@MainActor
@Observable
public final class HelmWorkspaceStore {
    public let controlPlane: HelmControlPlane
    public let ocrService: VisionOCRService
    public let sandboxExecutor: ExecutionRouter
    public let browserService: BrowseReadActTool
    public let notificationCoordinator: NotificationCoordinator
    public let updateManager: AppUpdateManager
    public let cliAuthManager: CLIAuthManager

    public var selectedProjectID: UUID?
    public var selectedAgentID: UUID?
    public var isInspectorVisible: Bool = false
    public var inspectorTab: InspectorTab = .agent
    public var secondaryTab: WorkspaceSecondaryTab = .liveWork
    public var activeChatChannelByProject: [UUID: ChatChannelKind] = [:]
    public var workFeedFilterAgentIDByProject: [UUID: UUID?] = [:]
    public var selectedTaskID: UUID?
    public var showNewProjectSheet: Bool = false
    public var showAddAgentSheet: Bool = false
    public var showSettingsSheet: Bool = false
    public var highlightedAuthProvider: CLIAuthProviderKind? = nil
    public var showOnboarding: Bool = false
    public var hasCompletedOnboarding: Bool = false

    public var defaultBackend: LLMBackendKind = .mock
    public var apiBaseURL: String = ""
    public var apiKeyInput: String = ""
    public var claudeCLIPath: String = ""
    public var codexCLIPath: String = ""
    public var agyCLIPath: String = ""
    public var piCLIPath: String = ""
    public var environmentStatus: LocalEnvironmentStatus = LocalEnvironmentStatus(
        virtualizationAvailable: EntitlementChecker.isVirtualizationAvailable(),
        chromeAvailable: false,
        claudeCLIAvailable: false,
        codexCLIAvailable: false,
        agyCLIAvailable: false,
        piCLIAvailable: false,
        foundationModelsSupported: false
    )

    public var isWindowOccluded: Bool = false
    public var forcedReduceMotion: Bool = false
    public var settleHelmCounter: Int = 0
    public var bannerErrorMessage: String?
    public var isRunningDiagnostic: Bool = false

    public var sharedStateByProject: [UUID: [RunSharedStateSummary]] = [:]
    public var privateMemoryByAgent: [UUID: [SharedStateEntry]] = [:]
    public var eventsByProject: [UUID: [RunEvent]] = [:]
    public var artifactsByProject: [UUID: [ArtifactRecord]] = [:]
    public var chatMessagesByProject: [UUID: [ChatMessage]] = [:]
    public var pendingChatMessagesByProject: [UUID: [ChatMessage]] = [:]
    public var sendingChatChannels: Set<String> = []
    public var chatErrorByProject: [UUID: String] = [:]
    public var lastChatSendOutcomeByProject: [UUID: ChatSendOutcome] = [:]
    public var chatNavigationNonce: Int = 0
    public var workFeedByProject: [UUID: [AgentWorkEntry]] = [:]
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
    private var pendingBaselineIDsByMessageID: [UUID: Set<UUID>] = [:]
    private var exactIDPendingMessageIDs: Set<UUID> = []
    private var sendingChannelCounts: [String: Int] = [:]

    private static let onboardingKey = "helm.v1.onboardingCompleted"
    private static let defaultBackendKey = "helm.v1.defaultBackend"
    private static let apiBaseURLKey = "helm.v1.apiBaseURL"
    private static let claudePathKey = "helm.v1.claudeCLIPath"
    private static let codexPathKey = "helm.v1.codexCLIPath"
    private static let agyPathKey = "helm.v1.agyCLIPath"
    private static let piPathKey = "helm.v1.piCLIPath"
    private static let resumeAfterUpdateKey = "helm.v1.resumeAfterUpdateProjectIDs"

    public init(
        controlPlane: HelmControlPlane,
        ocrService: VisionOCRService,
        sandboxExecutor: ExecutionRouter,
        browserService: BrowseReadActTool,
        notificationCoordinator: NotificationCoordinator,
        updateManager: AppUpdateManager? = nil,
        cliAuthManager: CLIAuthManager? = nil,
        forcedReduceMotion: Bool = false
    ) {
        self.controlPlane = controlPlane
        self.ocrService = ocrService
        self.sandboxExecutor = sandboxExecutor
        self.browserService = browserService
        self.notificationCoordinator = notificationCoordinator
        self.updateManager = updateManager ?? AppUpdateManager(
            environment: ["HELM_DISABLE_UPDATE_CHECK": "1"],
            arguments: ["--headless"]
        )
        self.cliAuthManager = cliAuthManager ?? CLIAuthManager(
            arguments: ["--headless"],
            environment: ["HELM_DISABLE_AUTH_PROBE": "1"]
        )
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
        cp.enableAutonomousChatDispatch()
        let notif = NotificationCoordinator(arguments: arguments, environment: environment)
        let updater = AppUpdateManager(environment: environment, arguments: arguments)
        let authManager = CLIAuthManager(arguments: arguments, environment: environment)
        let reduceMotion = arguments.contains("--reduce-motion") || environment["HELM_REDUCE_MOTION"] == "1"
        let store = HelmWorkspaceStore(
            controlPlane: cp,
            ocrService: ocr,
            sandboxExecutor: router,
            browserService: browser,
            notificationCoordinator: notif,
            updateManager: updater,
            cliAuthManager: authManager,
            forcedReduceMotion: reduceMotion
        )
        store.loadPersistedCLISettings()
        let envStatus = LocalEnvironmentStatus.detect()
        store.environmentStatus = envStatus
        if let savedRaw = UserDefaults.standard.string(forKey: defaultBackendKey),
           let saved = LLMBackendKind(rawValue: savedRaw) {
            store.defaultBackend = saved
        } else {
            store.defaultBackend = envStatus.recommendedBackend
        }
        store.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: onboardingKey)
        store.wireUpdateLifecycleHooks()
        return store
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

    public var runningProjectCount: Int {
        controlPlane.projects.filter { $0.status == .running }.count
    }

    public func activeTask(for agentID: UUID) -> DelegatedTask? {
        selectedProjectTasks.first(where: { $0.assignedAgentID == agentID && $0.status == .running })
    }

    public var selectedProjectActiveTasks: [DelegatedTask] {
        selectedProjectTasks.filter { $0.status == .running }
    }

    public var selectedProjectLatestEvent: RunEvent? {
        selectedProjectEvents.last
    }

    public var selectedChatChannel: ChatChannelKind {
        guard let project = selectedProject else { return .crew }
        let channel = activeChatChannelByProject[project.id] ?? .crew
        if case .direct(let agentID) = channel,
           !selectedProjectAgents.contains(where: { $0.id == agentID }) {
            return .crew
        }
        return channel
    }

    internal static func unpersistedPendingMessages(
        _ pending: [ChatMessage],
        persisted: [ChatMessage],
        baselineIDsByPendingID: [UUID: Set<UUID>] = [:],
        exactIDMatchOnlyPendingIDs: Set<UUID> = []
    ) -> [ChatMessage] {
        let sortedPersisted = persisted.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
        let sortedPending = pending.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
        var consumedPersistedIDs: Set<UUID> = []
        var remaining: [ChatMessage] = []

        for candidate in sortedPending {
            if let exact = sortedPersisted.first(where: { $0.id == candidate.id && !consumedPersistedIDs.contains($0.id) }) {
                consumedPersistedIDs.insert(exact.id)
                continue
            }
            if exactIDMatchOnlyPendingIDs.contains(candidate.id) {
                remaining.append(candidate)
                continue
            }
            if candidate.senderKind == .user {
                let candidateTrimmed = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let windowStart = candidate.createdAt.addingTimeInterval(-2.0)
                let excludedIDs = baselineIDsByPendingID[candidate.id] ?? []
                if let matched = sortedPersisted.first(where: { msg in
                    !consumedPersistedIDs.contains(msg.id)
                        && !excludedIDs.contains(msg.id)
                        && msg.senderKind == .user
                        && msg.channelKind == candidate.channelKind
                        && msg.content.trimmingCharacters(in: .whitespacesAndNewlines) == candidateTrimmed
                        && msg.createdAt >= windowStart
                }) {
                    consumedPersistedIDs.insert(matched.id)
                    continue
                }
            }
            remaining.append(candidate)
        }
        return remaining
    }

    public func chatMessages(forProject projectID: UUID, channel: ChatChannelKind) -> [ChatMessage] {
        let persisted = (chatMessagesByProject[projectID] ?? []).filter { $0.channelKind == channel }
        let channelPending = (pendingChatMessagesByProject[projectID] ?? []).filter { $0.channelKind == channel }
        let pending = Self.unpersistedPendingMessages(
            channelPending,
            persisted: persisted,
            baselineIDsByPendingID: pendingBaselineIDsByMessageID,
            exactIDMatchOnlyPendingIDs: exactIDPendingMessageIDs
        )
        return (persisted + pending).sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    public var selectedChatMessages: [ChatMessage] {
        guard let project = selectedProject else { return [] }
        return chatMessages(forProject: project.id, channel: selectedChatChannel)
    }

    public func isSendingChat(forProject projectID: UUID, channel: ChatChannelKind) -> Bool {
        sendingChatChannels.contains("\(projectID.uuidString):\(channel.channelKey)")
    }

    public var isSendingSelectedChat: Bool {
        guard let project = selectedProject else { return false }
        return isSendingChat(forProject: project.id, channel: selectedChatChannel)
    }

    public var selectedChatError: String? {
        guard let project = selectedProject else { return nil }
        return chatErrorByProject[project.id]
    }

    public func workFeed(forProject projectID: UUID, agentID: UUID? = nil) -> [AgentWorkEntry] {
        let entries = workFeedByProject[projectID] ?? []
        guard let agentID else { return entries }
        return entries.filter { $0.agentID == agentID }
    }

    public var selectedWorkFeedFilterAgentID: UUID? {
        guard let project = selectedProject,
              let candidate = workFeedFilterAgentIDByProject[project.id] ?? nil,
              selectedProjectAgents.contains(where: { $0.id == candidate }) else {
            return nil
        }
        return candidate
    }

    public var selectedWorkFeed: [AgentWorkEntry] {
        guard let project = selectedProject else { return [] }
        return workFeed(forProject: project.id, agentID: selectedWorkFeedFilterAgentID)
    }

    public var selectedTask: DelegatedTask? {
        guard let selectedTaskID else { return nil }
        return selectedProjectTasks.first(where: { $0.id == selectedTaskID })
    }

    // MARK: - Onboarding, Settings & Safe Update Hooks

    public func loadPersistedCLISettings() {
        apiBaseURL = UserDefaults.standard.string(forKey: Self.apiBaseURLKey) ?? ""
        claudeCLIPath = UserDefaults.standard.string(forKey: Self.claudePathKey) ?? ""
        codexCLIPath = UserDefaults.standard.string(forKey: Self.codexPathKey) ?? ""
        agyCLIPath = UserDefaults.standard.string(forKey: Self.agyPathKey) ?? ""
        piCLIPath = UserDefaults.standard.string(forKey: Self.piPathKey) ?? ""
        applyCLIEnvironmentOverrides()
    }

    public func saveCLISettings(
        defaultBackend: LLMBackendKind,
        claudePath: String,
        codexPath: String,
        agyPath: String,
        piPath: String,
        apiBaseURL: String,
        apiKey: String
    ) {
        self.defaultBackend = defaultBackend
        self.claudeCLIPath = claudePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.codexCLIPath = codexPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.agyCLIPath = agyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.piCLIPath = piPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiBaseURL = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKeyInput = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        UserDefaults.standard.set(defaultBackend.rawValue, forKey: Self.defaultBackendKey)
        UserDefaults.standard.set(self.claudeCLIPath, forKey: Self.claudePathKey)
        UserDefaults.standard.set(self.codexCLIPath, forKey: Self.codexPathKey)
        UserDefaults.standard.set(self.agyCLIPath, forKey: Self.agyPathKey)
        UserDefaults.standard.set(self.piCLIPath, forKey: Self.piPathKey)
        UserDefaults.standard.set(self.apiBaseURL, forKey: Self.apiBaseURLKey)

        applyCLIEnvironmentOverrides()
        rescanEnvironment()
    }

    public func rescanEnvironment() {
        environmentStatus = LocalEnvironmentStatus.detect()
    }

    private func applyCLIEnvironmentOverrides() {
        setOrUnsetEnv("HELM_CLAUDE_PATH", claudeCLIPath)
        setOrUnsetEnv("HELM_CODEX_PATH", codexCLIPath)
        setOrUnsetEnv("HELM_AGY_PATH", agyCLIPath)
        setOrUnsetEnv("HELM_PI_PATH", piCLIPath)
        setOrUnsetEnv("HELM_LLM_BASE_URL", apiBaseURL)
        if !apiKeyInput.isEmpty {
            setenv("HELM_LLM_API_KEY", apiKeyInput, 1)
        }
    }

    private func setOrUnsetEnv(_ key: String, _ value: String) {
        if value.isEmpty {
            unsetenv(key)
        } else {
            setenv(key, value, 1)
        }
    }

    public func wireUpdateLifecycleHooks() {
        updateManager.runningProjectCountProvider = { [weak self] in
            self?.runningProjectCount ?? 0
        }
        updateManager.prepareForSafeRestart = { [weak self] in
            await self?.checkpointAndPauseForUpdate()
        }
    }

    public func checkpointAndPauseForUpdate() async {
        let runningIDs = controlPlane.projects
            .filter { $0.status == .running }
            .map { $0.id.uuidString }
        if !runningIDs.isEmpty {
            UserDefaults.standard.set(runningIDs, forKey: Self.resumeAfterUpdateKey)
            await pauseAllProjects()
        }
    }

    private func resumeProjectsAfterUpdateIfNeeded() async {
        guard let saved = UserDefaults.standard.stringArray(forKey: Self.resumeAfterUpdateKey),
              !saved.isEmpty else {
            return
        }
        UserDefaults.standard.removeObject(forKey: Self.resumeAfterUpdateKey)
        var resumedAny = false
        for raw in saved {
            guard let id = UUID(uuidString: raw),
                  controlPlane.projects.contains(where: { $0.id == id && $0.status != .held && $0.status != .completed }) else {
                continue
            }
            try? await controlPlane.startProject(projectID: id)
            pendingStartProjectIDs.insert(id)
            resumedAny = true
        }
        if resumedAny {
            pollingGraceDeadline = Date().addingTimeInterval(3.0)
            await reloadAll()
            ensurePollingState(forceStart: true)
        }
    }

    public func savePreferences(backend: LLMBackendKind, baseURL: String, apiKey: String) {
        saveCLISettings(
            defaultBackend: backend,
            claudePath: claudeCLIPath,
            codexPath: codexCLIPath,
            agyPath: agyCLIPath,
            piPath: piCLIPath,
            apiBaseURL: baseURL,
            apiKey: apiKey
        )
    }

    public func completeOnboarding() {
        hasCompletedOnboarding = true
        showOnboarding = false
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
    }

    public func reopenOnboarding() {
        showSettingsSheet = false
        rescanEnvironment()
        showOnboarding = true
    }

    public func openSettings() {
        rescanEnvironment()
        cliAuthManager.refreshAllStatuses()
        showSettingsSheet = true
    }

    public func openSettingsToAuth(highlighting provider: CLIAuthProviderKind? = nil) {
        highlightedAuthProvider = provider
        rescanEnvironment()
        cliAuthManager.refreshAllStatuses()
        showSettingsSheet = true
    }

    // MARK: - Lifecycle & Polling

    public func bootstrapInteractive() async {
        Task.detached(priority: .utility) { [ocrService] in
            await ocrService.warmUpInBackground()
        }
        environmentStatus = LocalEnvironmentStatus.detect()
        cliAuthManager.refreshAllStatuses()
        await reloadAll()
        if selectedProjectID == nil {
            selectedProjectID = controlPlane.projects.first?.id
        }
        if selectedAgentID == nil {
            selectedAgentID = selectedProjectAgents.first?.id
        }
        if controlPlane.projects.isEmpty && !hasCompletedOnboarding {
            showOnboarding = true
            isInspectorVisible = false
        }
        settleHelmCounter += 1
        await resumeProjectsAfterUpdateIfNeeded()
        ensurePollingState()
        updateManager.startPeriodicChecks()
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
            if let selectedTaskID,
               !selectedProjectTasks.contains(where: { $0.id == selectedTaskID }) {
                self.selectedTaskID = nil
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
            var chatMessages = try await controlPlane.listChatMessages(projectID: projectID, channel: nil, limit: 200)
            let activeChannel = activeChatChannelByProject[projectID] ?? .crew
            let channelMessages = try await controlPlane.listChatMessages(projectID: projectID, channel: activeChannel, limit: 200)
            if !channelMessages.isEmpty {
                var seenChatIDs = Set(chatMessages.map(\.id))
                var addedAny = false
                for msg in channelMessages where seenChatIDs.insert(msg.id).inserted {
                    chatMessages.append(msg)
                    addedAny = true
                }
                if addedAny {
                    chatMessages.sort {
                        if $0.createdAt == $1.createdAt {
                            return $0.id.uuidString < $1.id.uuidString
                        }
                        return $0.createdAt < $1.createdAt
                    }
                }
            }

            var workEntries = try await controlPlane.listAgentWorkFeed(projectID: projectID, agentID: nil, limit: 200)
            if let filterAgentID = workFeedFilterAgentIDByProject[projectID] ?? nil {
                let agentEntries = try await controlPlane.listAgentWorkFeed(projectID: projectID, agentID: filterAgentID, limit: 200)
                if !agentEntries.isEmpty {
                    var seenWorkIDs = Set(workEntries.map(\.id))
                    var addedAny = false
                    for entry in agentEntries where seenWorkIDs.insert(entry.id).inserted {
                        workEntries.append(entry)
                        addedAny = true
                    }
                    if addedAny {
                        workEntries.sort {
                            if $0.createdAt == $1.createdAt {
                                if $0.stepNumber == $1.stepNumber {
                                    return $0.id.uuidString < $1.id.uuidString
                                }
                                return $0.stepNumber < $1.stepNumber
                            }
                            return $0.createdAt < $1.createdAt
                        }
                    }
                }
            }

            sharedStateByProject[projectID] = shared
            eventsByProject[projectID] = events
            artifactsByProject[projectID] = artifacts
            chatMessagesByProject[projectID] = chatMessages
            workFeedByProject[projectID] = workEntries

            if let pending = pendingChatMessagesByProject[projectID], !pending.isEmpty {
                let remaining = Self.unpersistedPendingMessages(
                    pending,
                    persisted: chatMessages,
                    baselineIDsByPendingID: pendingBaselineIDsByMessageID,
                    exactIDMatchOnlyPendingIDs: exactIDPendingMessageIDs
                )
                let remainingIDs = Set(remaining.map(\.id))
                for removed in pending where !remainingIDs.contains(removed.id) {
                    pendingBaselineIDsByMessageID.removeValue(forKey: removed.id)
                    exactIDPendingMessageIDs.remove(removed.id)
                }
                pendingChatMessagesByProject[projectID] = remaining.isEmpty ? nil : remaining
            }

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
        selectedTaskID = nil
        settleHelmCounter += 1
        Task {
            await refreshProjectDetails(projectID: id, notifyExceptions: false)
        }
    }

    public func selectChatChannel(_ channel: ChatChannelKind) {
        guard let project = selectedProject else { return }
        let resolved: ChatChannelKind
        switch channel {
        case .crew:
            resolved = .crew
        case .direct(let agentID):
            if selectedProjectAgents.contains(where: { $0.id == agentID }) {
                resolved = .direct(agentID: agentID)
                selectedAgentID = agentID
            } else {
                resolved = .crew
            }
        }
        activeChatChannelByProject[project.id] = resolved
        chatErrorByProject[project.id] = nil
        chatNavigationNonce += 1
        let projectID = project.id
        Task {
            await refreshProjectDetails(projectID: projectID, notifyExceptions: false)
        }
    }

    public func selectAgent(
        _ agentID: UUID,
        openDirectChat: Bool = true,
        openInspector: Bool = false
    ) {
        selectedAgentID = agentID
        if openDirectChat {
            selectChatChannel(.direct(agentID: agentID))
        }
        if openInspector {
            inspectorTab = .agent
            isInspectorVisible = true
        }
    }

    public func setWorkFeedFilter(agentID: UUID?) {
        guard let project = selectedProject else { return }
        let projectID = project.id
        if let agentID, !selectedProjectAgents.contains(where: { $0.id == agentID }) {
            workFeedFilterAgentIDByProject[projectID] = nil
        } else {
            workFeedFilterAgentIDByProject[projectID] = agentID
        }
        Task {
            await refreshProjectDetails(projectID: projectID, notifyExceptions: false)
        }
    }

    public func selectTask(_ taskID: UUID?) {
        if let taskID, selectedProjectTasks.contains(where: { $0.id == taskID }) {
            selectedTaskID = taskID
        } else {
            selectedTaskID = nil
        }
    }

    public func openTaskInWorkspace(_ taskID: UUID) {
        secondaryTab = .tasks
        selectTask(taskID)
    }

    public func inspectAgent(_ agentID: UUID) {
        selectedAgentID = agentID
        inspectorTab = .agent
        isInspectorVisible = true
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
                    await updateManager.notifyProjectsBecameIdle()
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
            let withinGrace = !pendingStartProjectIDs.isEmpty && (pollingGraceDeadline.map { Date() < $0 } ?? false)
            return withinGrace || controlPlane.projects.contains { $0.status == .running }
        }
    }

    public func shutdownBackgroundWork() async {
        stopPollingForTermination()
        updateManager.stopPeriodicChecks()
        cliAuthManager.cancelActiveLogin()
        let browserService = self.browserService
        let sandboxExecutor = self.sandboxExecutor
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await browserService.closeAllSessions() }
            group.addTask { await sandboxExecutor.shutdownAll() }
        }
    }

    // MARK: - User Actions

    public func createProject(
        name: String,
        goal: String,
        workspaceRoot: URL,
        backend: LLMBackendKind? = nil,
        leadPersonality: AgentPersonality = .calmCommander,
        starterRoles: [AgentRole] = [],
        sandboxTrustPolicy: SandboxTrustPolicy = .standardWorkspace
    ) async throws {
        let chosenBackend = backend ?? defaultBackend
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? workspaceRoot.lastPathComponent
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = try await controlPlane.createProject(
            name: resolvedName,
            goal: goal,
            workspaceRoot: workspaceRoot,
            sandboxTrustPolicy: sandboxTrustPolicy
        )
        let leadPreset = AgentProfile.RolePreset.orchestrator
        _ = try await controlPlane.addAgent(
            projectID: project.id,
            name: "Compass",
            role: .orchestrator,
            goal: leadPreset.goal,
            backend: chosenBackend,
            capabilities: leadPreset.capabilities,
            personality: leadPersonality
        )
        for role in starterRoles where role != .orchestrator {
            let preset = AgentProfile.RolePreset.preset(for: role)
            _ = try await controlPlane.addAgent(
                projectID: project.id,
                name: preset.name,
                role: role,
                goal: preset.goal,
                backend: chosenBackend,
                capabilities: preset.capabilities,
                personality: AgentPersonality.defaultForRole(role)
            )
        }
        await reloadAll()
        selectProject(project.id)
    }

    @discardableResult
    public func updateProjectTrustPolicy(
        _ policy: SandboxTrustPolicy,
        projectID: UUID? = nil
    ) async throws -> Project {
        guard let targetID = projectID ?? selectedProject?.id else {
            throw ControlPlaneError.invalidInput("No project selected.")
        }
        let updated = try await controlPlane.updateProjectTrustPolicy(projectID: targetID, policy: policy)
        await reloadAll()
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
    ) async throws {
        let resolvedCapabilities = capabilities ?? AgentProfile.RolePreset.preset(for: role).capabilities
        let agent = try await controlPlane.addAgent(
            projectID: projectID,
            name: name,
            role: role,
            goal: goal,
            backend: backend,
            capabilities: resolvedCapabilities,
            personality: personality ?? AgentPersonality.defaultForRole(role),
            personalityNotes: personalityNotes,
            systemPrompt: systemPrompt
        )
        await refreshProjectDetails(projectID: projectID, notifyExceptions: false)
        selectedAgentID = agent.id
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
    ) async throws {
        let updated = try await controlPlane.updateAgent(
            agentID: agentID,
            name: name,
            goal: goal,
            backend: backend,
            personality: personality,
            personalityNotes: personalityNotes,
            capabilities: capabilities,
            modelOverride: modelOverride,
            systemPrompt: systemPrompt
        )
        await refreshProjectDetails(projectID: updated.projectID, notifyExceptions: false)
        selectedAgentID = updated.id
    }

    @discardableResult
    public func sendChatMessage(
        content: String,
        to channel: ChatChannelKind? = nil,
        referencedFiles: [String] = [],
        relatedTaskID: UUID? = nil,
        projectID: UUID? = nil
    ) async -> Bool {
        let outcome = await sendChatMessageWithOutcome(
            content: content,
            to: channel,
            referencedFiles: referencedFiles,
            relatedTaskID: relatedTaskID,
            projectID: projectID
        )
        return outcome.succeeded
    }

    @discardableResult
    public func sendChatMessageWithOutcome(
        content: String,
        to channel: ChatChannelKind? = nil,
        referencedFiles: [String] = [],
        relatedTaskID: UUID? = nil,
        projectID: UUID? = nil
    ) async -> ChatSendOutcome {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let targetProjectID = projectID ?? selectedProject?.id else {
            return ChatSendOutcome(succeeded: false, didPersistUserMessage: false)
        }
        let targetChannel: ChatChannelKind
        if let channel {
            targetChannel = channel
        } else if targetProjectID == selectedProject?.id {
            targetChannel = selectedChatChannel
        } else {
            targetChannel = activeChatChannelByProject[targetProjectID] ?? .crew
        }

        chatErrorByProject[targetProjectID] = nil
        let optimistic = ChatMessage(
            projectID: targetProjectID,
            channelKind: targetChannel,
            senderKind: .user,
            senderName: "You",
            content: trimmed,
            referencedFiles: referencedFiles,
            relatedTaskID: relatedTaskID
        )
        var baselineIDs = Set((chatMessagesByProject[targetProjectID] ?? []).map(\.id))
        if let cpMessages = controlPlane.chatMessagesByProject[targetProjectID] {
            baselineIDs.formUnion(cpMessages.map(\.id))
        }
        pendingBaselineIDsByMessageID[optimistic.id] = baselineIDs
        exactIDPendingMessageIDs.insert(optimistic.id)
        pendingChatMessagesByProject[targetProjectID, default: []].append(optimistic)

        let channelKey = "\(targetProjectID.uuidString):\(targetChannel.channelKey)"
        sendingChannelCounts[channelKey, default: 0] += 1
        sendingChatChannels.insert(channelKey)
        defer {
            let nextCount = (sendingChannelCounts[channelKey] ?? 0) - 1
            if nextCount <= 0 {
                sendingChannelCounts.removeValue(forKey: channelKey)
                sendingChatChannels.remove(channelKey)
            } else {
                sendingChannelCounts[channelKey] = nextCount
            }
        }

        pendingStartProjectIDs.insert(targetProjectID)
        pollingGraceDeadline = Date().addingTimeInterval(3.0)
        ensurePollingState(forceStart: true)

        do {
            _ = try await controlPlane.sendChatMessage(
                projectID: targetProjectID,
                channel: targetChannel,
                content: trimmed,
                referencedFiles: referencedFiles,
                relatedTaskID: relatedTaskID,
                messageID: optimistic.id
            )
            pendingChatMessagesByProject[targetProjectID]?.removeAll { $0.id == optimistic.id }
            if pendingChatMessagesByProject[targetProjectID]?.isEmpty == true {
                pendingChatMessagesByProject[targetProjectID] = nil
            }
            pendingBaselineIDsByMessageID.removeValue(forKey: optimistic.id)
            exactIDPendingMessageIDs.remove(optimistic.id)
            await refreshProjectDetails(projectID: targetProjectID, notifyExceptions: true)
            ensurePollingState()
            let outcome = ChatSendOutcome(succeeded: true, didPersistUserMessage: true)
            lastChatSendOutcomeByProject[targetProjectID] = outcome
            return outcome
        } catch {
            pendingChatMessagesByProject[targetProjectID]?.removeAll { $0.id == optimistic.id }
            if pendingChatMessagesByProject[targetProjectID]?.isEmpty == true {
                pendingChatMessagesByProject[targetProjectID] = nil
            }
            pendingBaselineIDsByMessageID.removeValue(forKey: optimistic.id)
            exactIDPendingMessageIDs.remove(optimistic.id)
            var didPersist = false
            if let latestMessages = try? await controlPlane.listChatMessages(projectID: targetProjectID, channel: nil, limit: 200) {
                chatMessagesByProject[targetProjectID] = latestMessages
                await refreshProjectDetails(projectID: targetProjectID, notifyExceptions: false)
                let persistedMessages = chatMessagesByProject[targetProjectID] ?? latestMessages
                didPersist = persistedMessages.contains(where: { $0.id == optimistic.id })
            }
            chatErrorByProject[targetProjectID] = error.localizedDescription
            ensurePollingState()
            let outcome = ChatSendOutcome(succeeded: false, didPersistUserMessage: didPersist)
            lastChatSendOutcomeByProject[targetProjectID] = outcome
            return outcome
        }
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
