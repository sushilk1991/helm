import AppKit
import CoreGraphics
import Foundation
@testable import HelmAppCore
@testable import HelmBrowser
@testable import HelmCore
@testable import HelmIsolation
import ImageIO
import Testing

@Suite("M3 Chat-First Workspace, Live Work Feed, Inspector & Preserved Capabilities Tests")
struct M3WorkspaceUITests {
    @MainActor
    private func makeInMemoryStore(
        chatHook: HelmControlPlane.ChatDispatchHook? = nil
    ) throws -> (store: HelmWorkspaceStore, db: HelmDatabase, cp: HelmControlPlane, ws: URL) {
        let db = try HelmDatabase(path: ":memory:")
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("HelmM3Test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)

        let ocr = VisionOCRService()
        let router = ExecutionRouter()
        let browser = BrowseReadActTool(ocrService: ocr)
        let cp = HelmControlPlane(
            database: db,
            providerRegistry: .makeDefault(),
            sandboxExecutor: router,
            browserService: browser
        )
        cp.chatDispatchHook = chatHook
        let notif = NotificationCoordinator(
            arguments: ["--headless"],
            environment: ["HELM_DISABLE_NOTIFICATIONS": "1", "HELM_NO_ACTIVATE": "1"]
        )
        let store = HelmWorkspaceStore(
            controlPlane: cp,
            ocrService: ocr,
            sandboxExecutor: router,
            browserService: browser,
            notificationCoordinator: notif,
            forcedReduceMotion: true
        )
        return (store, db, cp, ws)
    }

    // MARK: - R1: Chat-First Workspace (Crew & 1-on-1 Direct Channels)

    @Test("R1: HelmWorkspaceStore supports Shared Crew and 1-on-1 Direct chat channels with isolation and reply hook")
    @MainActor
    func chatChannelsAndIsolation() async throws {
        let (store, _, _, ws) = try makeInMemoryStore { project, message, _ in
            switch message.channelKind {
            case .crew:
                return [
                    ChatMessage(
                        projectID: project.id,
                        channelKind: .crew,
                        senderKind: .orchestrator,
                        senderName: "Compass",
                        content: "Crew reply for \(project.workspaceRoot.lastPathComponent): \(message.content)",
                        referencedFiles: ["README.md"]
                    ),
                ]
            case .direct(let agentID):
                return [
                    ChatMessage(
                        projectID: project.id,
                        channelKind: .direct(agentID: agentID),
                        senderKind: .agent,
                        senderAgentID: agentID,
                        senderName: "Specialist",
                        content: "Direct 1-on-1 reply: \(message.content)"
                    ),
                ]
            }
        }
        defer { try? FileManager.default.removeItem(at: ws) }

        try await store.createProject(
            name: "ChatWorkspace",
            goal: "Verify crew and direct chat",
            workspaceRoot: ws,
            starterRoles: [.researcher, .coder]
        )
        defer { store.stopPollingForTermination() }

        let agents = store.selectedProjectAgents
        let coder = try #require(agents.first(where: { $0.role == .coder }))
        let researcher = try #require(agents.first(where: { $0.role == .researcher }))

        #expect(store.selectedChatChannel == .crew)

        // 1. Send Shared Crew message
        let crewOK = await store.sendChatMessage(
            content: "Summarize the project folder",
            referencedFiles: ["Package.swift"]
        )
        #expect(crewOK)
        let crewMsgs = store.selectedChatMessages
        #expect(crewMsgs.count == 2)
        #expect(crewMsgs[0].senderKind == .user)
        #expect(crewMsgs[0].referencedFiles == ["Package.swift"])
        #expect(crewMsgs[1].senderKind == .orchestrator)
        #expect(crewMsgs[1].content.contains(ws.lastPathComponent))

        // 2. Select coder for 1-on-1 direct chat without opening inspector
        store.selectAgent(coder.id, openDirectChat: true, openInspector: false)
        #expect(store.selectedChatChannel == .direct(agentID: coder.id))
        #expect(store.isInspectorVisible == false)
        #expect(store.selectedChatMessages.isEmpty)

        let directOK = await store.sendChatMessage(content: "Run the unit tests")
        #expect(directOK)
        #expect(store.selectedChatMessages.count == 2)
        #expect(store.selectedChatMessages[1].content == "Direct 1-on-1 reply: Run the unit tests")

        // 3. Researcher 1-on-1 channel remains isolated from coder & crew
        store.selectChatChannel(.direct(agentID: researcher.id))
        #expect(store.selectedChatMessages.isEmpty)

        // 4. Empty message does not persist
        let emptyOK = await store.sendChatMessage(content: "   \n  ")
        #expect(!emptyOK)
        #expect(store.selectedChatMessages.isEmpty)
    }

    @Test("R1: sendChatMessage surfaces errors without losing project state")
    @MainActor
    func chatSendErrorHandling() async throws {
        struct SimulatedSendError: LocalizedError {
            var errorDescription: String? { "Dispatch offline" }
        }

        let (store, _, _, ws) = try makeInMemoryStore { _, _, _ in
            throw SimulatedSendError()
        }
        defer { try? FileManager.default.removeItem(at: ws) }

        try await store.createProject(name: "ErrChat", goal: "Verify error handling", workspaceRoot: ws)
        defer { store.stopPollingForTermination() }

        let ok = await store.sendChatMessage(content: "Hello crew")
        #expect(!ok)
        #expect(store.selectedChatError == "Dispatch offline")
    }

    // MARK: - R3: Live Per-Agent Work Feed & Navigable Tasks

    @Test("R3: workFeedByProject loads entries, filters by agent, and openTaskInWorkspace selects task with dependencies")
    @MainActor
    func workFeedAndNavigableTasks() async throws {
        let (store, db, cp, ws) = try makeInMemoryStore()
        defer { try? FileManager.default.removeItem(at: ws) }

        try await store.createProject(
            name: "WorkFeedApp",
            goal: "Track live agent work and tasks",
            workspaceRoot: ws,
            starterRoles: [.researcher, .coder]
        )
        defer { store.stopPollingForTermination() }

        let project = try #require(store.selectedProject)
        let researcher = try #require(store.selectedProjectAgents.first(where: { $0.role == .researcher }))
        let coder = try #require(store.selectedProjectAgents.first(where: { $0.role == .coder }))

        let t1 = DelegatedTask(
            projectID: project.id,
            assignedAgentID: researcher.id,
            title: "Audit repo structure",
            instructions: "List Sources/ files",
            status: .done,
            resultSummary: "Found 4 modules",
            artifactPaths: ["docs/audit.md"]
        )
        let t2 = DelegatedTask(
            projectID: project.id,
            assignedAgentID: coder.id,
            title: "Add telemetry tests",
            instructions: "Write unit tests for Telemetry",
            status: .running,
            waitingOn: [t1.id],
            artifactPaths: ["Tests/TelemetryTests.swift"]
        )
        try await db.insertTask(t1)
        try await db.insertTask(t2)

        _ = try await cp.recordAgentWorkEntry(AgentWorkEntry(
            projectID: project.id,
            agentID: researcher.id,
            agentName: researcher.name,
            taskID: t1.id,
            taskTitle: t1.title,
            stepNumber: 1,
            phase: .toolCall,
            summary: "Listed workspace directory",
            toolName: "list_workspace_files",
            toolInputSummary: ".",
            toolOutputSummary: "12 files",
            touchedFiles: ["Package.swift"],
            artifactPaths: ["docs/audit.md"]
        ))
        _ = try await cp.recordAgentWorkEntry(AgentWorkEntry(
            projectID: project.id,
            agentID: coder.id,
            agentName: coder.name,
            taskID: t2.id,
            taskTitle: t2.title,
            stepNumber: 2,
            phase: .fileEdit,
            summary: "Created TelemetryTests.swift",
            toolName: "write_workspace_file",
            touchedFiles: ["Tests/TelemetryTests.swift"],
            artifactPaths: ["Tests/TelemetryTests.swift"]
        ))

        await store.reloadAll()

        #expect(store.selectedWorkFeed.count == 2)
        store.setWorkFeedFilter(agentID: coder.id)
        #expect(store.selectedWorkFeedFilterAgentID == coder.id)
        #expect(store.selectedWorkFeed.count == 1)
        #expect(store.selectedWorkFeed[0].touchedFiles == ["Tests/TelemetryTests.swift"])

        store.setWorkFeedFilter(agentID: nil)
        #expect(store.selectedWorkFeed.count == 2)

        store.openTaskInWorkspace(t2.id)
        #expect(store.secondaryTab == .tasks)
        let selected = try #require(store.selectedTask)
        #expect(selected.id == t2.id)
        #expect(selected.waitingOn == [t1.id])
        #expect(selected.artifactPaths == ["Tests/TelemetryTests.swift"])
    }

    // MARK: - R4: Editable System Prompt & Simplified SandboxTrustPolicy

    @Test("R4: Editable systemPrompt persists, personality switches stay non-locking, and SandboxTrustPolicy updates cleanly")
    @MainActor
    func editableSystemPromptAndTrustPolicy() async throws {
        let (store, _, _, ws) = try makeInMemoryStore()
        defer { try? FileManager.default.removeItem(at: ws) }

        try await store.createProject(
            name: "TrustAndPrompt",
            goal: "Verify R4 configuration",
            workspaceRoot: ws,
            starterRoles: [.coder]
        )
        defer { store.stopPollingForTermination() }

        let project = try #require(store.selectedProject)
        #expect(project.sandboxTrustPolicy == .standardWorkspace)

        // Default agents never include .requestHumanDecision
        for agent in store.selectedProjectAgents {
            #expect(!agent.capabilities.contains(.requestHumanDecision))
        }

        // Onboarding compatibility typealias check
        #expect(AgentRolePreset.preset(for: .coder).name == "Forge Coder")

        // Switch project trust policy across all policies
        for policy in [SandboxTrustPolicy.sandboxed, .trustedFullAccess, .standardWorkspace] {
            let updated = try await store.updateProjectTrustPolicy(policy, projectID: project.id)
            #expect(updated.sandboxTrustPolicy == policy)
            #expect(store.selectedProject?.sandboxTrustPolicy == policy)
        }

        // Add agent with default role capabilities and custom systemPrompt
        let customPrompt = "Always inspect Tests/ before modifying code and report exact test counts."
        try await store.addAgent(
            projectID: project.id,
            name: "Verifier",
            role: .qaVerifier,
            goal: "Verify test suites",
            backend: .mock,
            personality: .adversarialReviewer,
            systemPrompt: customPrompt
        )

        let verifier = try #require(store.selectedProjectAgents.first(where: { $0.name == "Verifier" }))
        #expect(verifier.systemPrompt == customPrompt)
        #expect(!verifier.capabilities.contains(.requestHumanDecision))
        #expect(verifier.capabilities.contains(.codeExec))

        // Updating personality alone does NOT overwrite custom systemPrompt
        try await store.updateAgent(
            agentID: verifier.id,
            personality: .pragmaticBuilder
        )
        let afterPersonalitySwitch = try #require(store.selectedProjectAgents.first(where: { $0.id == verifier.id }))
        #expect(afterPersonalitySwitch.personality == .pragmaticBuilder)
        #expect(afterPersonalitySwitch.systemPrompt == customPrompt)

        // Explicit systemPrompt edit persists
        let updatedPrompt = "Run swift test and validate snapshot hashes."
        try await store.updateAgent(agentID: verifier.id, systemPrompt: updatedPrompt)
        let afterPromptEdit = try #require(store.selectedProjectAgents.first(where: { $0.id == verifier.id }))
        #expect(afterPromptEdit.systemPrompt == updatedPrompt)

        // Empty/whitespace systemPrompt is rejected
        await #expect(throws: Error.self) {
            try await store.updateAgent(agentID: verifier.id, systemPrompt: "   \n ")
        }
    }

    // MARK: - R5: Snapshot QA & Preserved Capabilities

    @Test("R5: HeadlessSnapshotRunner emits valid Dark/Light default + extra + settings PNGs with lightMean > darkMean")
    @MainActor
    func headlessSnapshotRunnerM3Coverage() async throws {
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("HelmM3Snaps_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outDir) }

        setenv("HELM_SNAPSHOT_SETTINGS", "1", 1)
        setenv("HELM_SNAPSHOT_EXTRA", "1", 1)
        defer {
            unsetenv("HELM_SNAPSHOT_SETTINGS")
            unsetenv("HELM_SNAPSHOT_EXTRA")
        }

        try await HeadlessSnapshotRunner.run(snapshotDirectory: outDir, reduceMotion: true)

        let expected1280x800 = [
            "helm_light_steady_reduce_motion.png",
            "helm_dark_steady_reduce_motion.png",
            "helm_light_exception_reduce_motion.png",
            "helm_dark_exception_reduce_motion.png",
            "helm_light_inspector_direct_reduce_motion.png",
            "helm_dark_inspector_direct_reduce_motion.png",
            "helm_light_tasks_navigable_reduce_motion.png",
            "helm_dark_tasks_navigable_reduce_motion.png",
        ]
        for name in expected1280x800 {
            let url = outDir.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path), "Missing snapshot \(name)")
            let dims = try pngDimensionsAndMeanLuminance(at: url)
            #expect(dims.width == 1280)
            #expect(dims.height == 800)
        }

        let lightSteadyLum = try pngDimensionsAndMeanLuminance(at: outDir.appendingPathComponent("helm_light_steady_reduce_motion.png")).meanLuminance
        let darkSteadyLum = try pngDimensionsAndMeanLuminance(at: outDir.appendingPathComponent("helm_dark_steady_reduce_motion.png")).meanLuminance
        #expect(lightSteadyLum > darkSteadyLum)

        let steadyData = try Data(contentsOf: outDir.appendingPathComponent("helm_dark_steady_reduce_motion.png"))
        let excData = try Data(contentsOf: outDir.appendingPathComponent("helm_dark_exception_reduce_motion.png"))
        #expect(steadyData != excData)

        let lightSettings = outDir.appendingPathComponent("helm_light_settings_reduce_motion.png")
        let darkSettings = outDir.appendingPathComponent("helm_dark_settings_reduce_motion.png")
        let lightSettingsDims = try pngDimensionsAndMeanLuminance(at: lightSettings)
        let darkSettingsDims = try pngDimensionsAndMeanLuminance(at: darkSettings)
        #expect(lightSettingsDims.width == 720 && lightSettingsDims.height == 660)
        #expect(darkSettingsDims.width == 720 && darkSettingsDims.height == 660)
        #expect(lightSettingsDims.meanLuminance > darkSettingsDims.meanLuminance)
    }

    @Test("R5: Preserved CLIAuthManager profile modes & sandbox forwarding toggle cleanly")
    @MainActor
    func preservedCLIAuthManagerModes() {
        let manager = CLIAuthManager(
            arguments: ["--headless"],
            environment: ["HELM_DISABLE_AUTH_PROBE": "1"]
        )
        let originalMode = manager.profileMode
        let originalForward = manager.forwardCredentialsToSandbox
        defer {
            manager.setProfileMode(originalMode)
            manager.setForwardCredentialsToSandbox(originalForward)
        }

        manager.setProfileMode(.helmIsolated)
        #expect(manager.profileMode == .helmIsolated)
        manager.setProfileMode(.system)
        #expect(manager.profileMode == .system)

        manager.setForwardCredentialsToSandbox(true)
        #expect(manager.forwardCredentialsToSandbox == true)
        manager.setForwardCredentialsToSandbox(false)
        #expect(manager.forwardCredentialsToSandbox == false)
    }

    // MARK: - M3 Iteration 2 Regression Tests

    @Test("R1/R2: HelmWorkspaceStore.makeLive wires autonomous chat dispatch and produces reply + AgentWorkEntry")
    @MainActor
    func makeLiveWiresAutonomousChatDispatch() async throws {
        let baseTmp = FileManager.default.temporaryDirectory.appendingPathComponent("HelmM3Live_\(UUID().uuidString)")
        let ws = baseTmp.appendingPathComponent("workspace")
        let dbURL = baseTmp.appendingPathComponent("helm-live.sqlite")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try "print(\"hello helm\")\n".write(to: ws.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        let store = try HelmWorkspaceStore.makeLive(
            databasePath: dbURL.path,
            arguments: ["--headless", "--reduce-motion"],
            environment: [
                "HELM_DISABLE_NOTIFICATIONS": "1",
                "HELM_NO_ACTIVATE": "1",
                "HELM_DISABLE_UPDATE_CHECK": "1",
                "HELM_DISABLE_AUTH_PROBE": "1",
            ]
        )
        defer {
            store.stopPollingForTermination()
            try? FileManager.default.removeItem(at: baseTmp)
        }

        #expect(store.controlPlane.chatDispatchHook != nil)

        try await store.createProject(
            name: "LiveDispatchProject",
            goal: "Verify live makeLive autonomous chat dispatch",
            workspaceRoot: ws,
            backend: .mock,
            starterRoles: [.coder]
        )

        let sent = await store.sendChatMessage(content: "Inspect main.swift in the workspace and summarize it")
        #expect(sent)

        let messages = store.selectedChatMessages
        #expect(messages.count >= 2)
        #expect(messages.first?.senderKind == .user)
        #expect(messages.contains { $0.senderKind == .orchestrator || $0.senderKind == .agent })
        #expect(!store.selectedWorkFeed.isEmpty)

        await store.shutdownBackgroundWork()
    }

    @Test("R1: Slow mid-flight chat dispatch deduplicates optimistic user message during refreshProjectDetails")
    @MainActor
    func slowChatDispatchDeduplicatesOptimisticUserMessage() async throws {
        let (store, _, _, ws) = try makeInMemoryStore { project, message, _ in
            try await Task.sleep(for: .milliseconds(450))
            return [
                ChatMessage(
                    projectID: project.id,
                    channelKind: message.channelKind,
                    senderKind: .orchestrator,
                    senderName: "Compass",
                    content: "Delayed autonomous reply"
                ),
            ]
        }
        defer { try? FileManager.default.removeItem(at: ws) }

        try await store.createProject(
            name: "SlowDedupProject",
            goal: "Verify zero duplicate user bubbles during slow dispatch",
            workspaceRoot: ws
        )
        defer { store.stopPollingForTermination() }

        let project = try #require(store.selectedProject)
        let sendTask = Task {
            await store.sendChatMessageWithOutcome(content: "Slow multi-turn prompt")
        }

        // Wait until the persisted user message appears in SQLite while the hook is still running
        for _ in 0..<30 {
            let persisted = try await store.controlPlane.listChatMessages(projectID: project.id, channel: .crew, limit: 50)
            if !persisted.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        // Concurrent refresh while sendChatMessageWithOutcome is mid-flight must deduplicate optimistic bubble
        await store.refreshProjectDetails(projectID: project.id, notifyExceptions: false)
        let midFlightUserMessages = store.selectedChatMessages.filter { $0.senderKind == .user }
        #expect(midFlightUserMessages.count == 1)
        #expect(store.pendingChatMessagesByProject[project.id] == nil)

        let outcome = await sendTask.value
        #expect(outcome.succeeded)
        #expect(outcome.didPersistUserMessage)
        #expect(!outcome.shouldRestoreDraft)
        #expect(store.selectedChatMessages.count == 2)
        #expect(store.selectedChatMessages.filter { $0.senderKind == .user }.count == 1)
    }

    @Test("R1: Dispatch hook failure after user persistence keeps 1 user message, surfaces error, and does not restore draft")
    @MainActor
    func hookFailureAfterPersistenceDoesNotRestoreDraft() async throws {
        struct SimulatedHookError: LocalizedError {
            var errorDescription: String? { "Agent turn failed" }
        }

        let (store, _, _, ws) = try makeInMemoryStore { _, _, _ in
            throw SimulatedHookError()
        }
        defer { try? FileManager.default.removeItem(at: ws) }

        try await store.createProject(name: "HookFailProject", goal: "Verify post-persistence error handling", workspaceRoot: ws)
        defer { store.stopPollingForTermination() }

        let outcome = await store.sendChatMessageWithOutcome(content: "Persist then fail")
        #expect(!outcome.succeeded)
        #expect(outcome.didPersistUserMessage)
        #expect(!outcome.shouldRestoreDraft)
        #expect(store.selectedChatError == "Agent turn failed")
        #expect(store.selectedChatMessages.filter { $0.senderKind == .user }.count == 1)
        #expect(store.selectedChatMessages.first?.content == "Persist then fail")

        // Pre-persistence failure (unknown project) SHOULD request draft restoration
        let missingOutcome = await store.sendChatMessageWithOutcome(content: "Will fail before save", projectID: UUID())
        #expect(!missingOutcome.succeeded)
        #expect(!missingOutcome.didPersistUserMessage)
        #expect(missingOutcome.shouldRestoreDraft)
    }

    @Test("R1/R3: chatNavigationNonce increments when re-selecting already active direct channel")
    @MainActor
    func chatNavigationNonceIncrementsOnReselection() async throws {
        let (store, _, _, ws) = try makeInMemoryStore()
        defer { try? FileManager.default.removeItem(at: ws) }

        try await store.createProject(
            name: "NonceNavProject",
            goal: "Verify narrow-mode chat reselection signal",
            workspaceRoot: ws,
            starterRoles: [.coder]
        )
        defer { store.stopPollingForTermination() }

        let coder = try #require(store.selectedProjectAgents.first(where: { $0.role == .coder }))

        store.selectAgent(coder.id, openDirectChat: true, openInspector: false)
        let firstNonce = store.chatNavigationNonce
        #expect(store.selectedChatChannel == .direct(agentID: coder.id))

        // Switch away to Tasks secondary tab, then re-select the same already-active agent
        store.secondaryTab = .tasks
        store.selectAgent(coder.id, openDirectChat: true, openInspector: false)
        #expect(store.chatNavigationNonce == firstNonce + 1)

        // Direct channel re-selection via selectChatChannel also increments nonce
        store.selectChatChannel(.direct(agentID: coder.id))
        #expect(store.chatNavigationNonce == firstNonce + 2)
    }

    @Test("R1: Rapid identical double-sends preserve optimistic count and restore draft on pre-persist failure")
    @MainActor
    func rapidIdenticalDoubleSendAndPrePersistDraftRestoration() async throws {
        actor DelayFlag {
            var enabled = false
            func set(_ value: Bool) { enabled = value }
        }
        let delayFlag = DelayFlag()
        let (store, _, _, ws) = try makeInMemoryStore { _, _, _ in
            if await delayFlag.enabled {
                try await Task.sleep(for: .milliseconds(350))
            }
            return []
        }
        defer { try? FileManager.default.removeItem(at: ws) }

        try await store.createProject(
            name: "DoubleSendProject",
            goal: "Verify rapid identical double-sends and pre-persist draft restoration",
            workspaceRoot: ws
        )
        defer { store.stopPollingForTermination() }

        let project = try #require(store.selectedProject)

        // 1. First send of "Ping" succeeds and persists user message #1.
        let outcome1 = await store.sendChatMessageWithOutcome(content: "Ping")
        #expect(outcome1.succeeded)
        #expect(outcome1.didPersistUserMessage)
        #expect(store.selectedChatMessages.filter { $0.senderKind == .user }.count == 1)

        // 2. Immediately send identical "Ping" with invalid relatedTaskID (fails validation BEFORE DB insert).
        // Must report didPersistUserMessage == false and shouldRestoreDraft == true despite #1 being within -2.0s.
        let outcome2 = await store.sendChatMessageWithOutcome(
            content: "Ping",
            relatedTaskID: UUID()
        )
        #expect(!outcome2.succeeded)
        #expect(!outcome2.didPersistUserMessage)
        #expect(outcome2.shouldRestoreDraft)
        #expect(store.selectedChatMessages.filter { $0.senderKind == .user }.count == 1)

        // 3. Immediately send identical "Ping" with a slow hook and inspect mid-flight before AND after DB insert.
        await delayFlag.set(true)
        let sendTask3 = Task {
            await store.sendChatMessageWithOutcome(content: "Ping")
        }

        // Yield once so sendChatMessageWithOutcome appends optimistic #2 before DB insert completes.
        await Task.yield()
        await store.refreshProjectDetails(projectID: project.id, notifyExceptions: false)
        // Before DB insert of #3 finishes, optimistic #2 must remain visible (count == 2, never collapsed to 1).
        // Once DB insert of #3 finishes, count must still be 2 (never duplicated to 3).
        let midCountBeforeOrAtInsert = store.selectedChatMessages.filter { $0.senderKind == .user }.count
        #expect(midCountBeforeOrAtInsert == 2)

        for _ in 0..<30 {
            let persisted = try await store.controlPlane.listChatMessages(projectID: project.id, channel: .crew, limit: 50)
            if persisted.filter({ $0.senderKind == .user }).count >= 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        await store.refreshProjectDetails(projectID: project.id, notifyExceptions: false)
        #expect(store.selectedChatMessages.filter { $0.senderKind == .user }.count == 2)

        let outcome3 = await sendTask3.value
        #expect(outcome3.succeeded)
        #expect(outcome3.didPersistUserMessage)
        #expect(!outcome3.shouldRestoreDraft)
        #expect(store.pendingChatMessagesByProject[project.id] == nil)
        #expect(store.selectedChatMessages.filter { $0.senderKind == .user }.count == 2)
    }

    @Test("R1: unpersistedPendingMessages performs 1-to-1 count-aware and baseline-aware deduplication")
    @MainActor
    func unpersistedPendingMessagesCountAndBaselineDedup() {
        let projectID = UUID()
        let baseTime = Date()
        let persisted1 = ChatMessage(
            projectID: projectID,
            channelKind: .crew,
            senderKind: .user,
            senderName: "You",
            content: "Ping",
            createdAt: baseTime
        )
        let pending1 = ChatMessage(
            projectID: projectID,
            channelKind: .crew,
            senderKind: .user,
            senderName: "You",
            content: "Ping",
            createdAt: baseTime.addingTimeInterval(0.05)
        )
        let pending2 = ChatMessage(
            projectID: projectID,
            channelKind: .crew,
            senderKind: .user,
            senderName: "You",
            content: "Ping",
            createdAt: baseTime.addingTimeInterval(0.10)
        )

        // Two identical pending messages against one persisted message keeps exactly the second pending message.
        let remainingAfterOne = HelmWorkspaceStore.unpersistedPendingMessages(
            [pending1, pending2],
            persisted: [persisted1]
        )
        #expect(remainingAfterOne.map(\.id) == [pending2.id])

        // Pending message whose baseline already includes persisted1 is NOT matched against persisted1 within -2.0s.
        let remainingWithBaseline = HelmWorkspaceStore.unpersistedPendingMessages(
            [pending2],
            persisted: [persisted1],
            baselineIDsByPendingID: [pending2.id: [persisted1.id]]
        )
        #expect(remainingWithBaseline.map(\.id) == [pending2.id])

        // Once a second persisted message arrives outside the baseline, pending2 is matched and pruned.
        let persisted2 = ChatMessage(
            projectID: projectID,
            channelKind: .crew,
            senderKind: .user,
            senderName: "You",
            content: "Ping",
            createdAt: baseTime.addingTimeInterval(0.15)
        )
        let remainingAfterTwo = HelmWorkspaceStore.unpersistedPendingMessages(
            [pending2],
            persisted: [persisted1, persisted2],
            baselineIDsByPendingID: [pending2.id: [persisted1.id]]
        )
        #expect(remainingAfterTwo.isEmpty)
    }

    @Test("R1: Concurrent identical send succeeding does not mask concurrent pre-persist validation failure")
    @MainActor
    func concurrentIdenticalSendDoesNotMaskPrePersistFailure() async throws {
        let (store, _, _, ws) = try makeInMemoryStore { _, _, _ in
            try await Task.sleep(for: .milliseconds(250))
            return []
        }
        defer { try? FileManager.default.removeItem(at: ws) }

        try await store.createProject(
            name: "ConcurrentSendFailureProject",
            goal: "Verify exact messageID prevents concurrent identical send from masking pre-persist failure",
            workspaceRoot: ws
        )
        defer { store.stopPollingForTermination() }

        let project = try #require(store.selectedProject)

        let t1 = Task {
            await store.sendChatMessageWithOutcome(content: "Ping")
        }
        let t2 = Task {
            await store.sendChatMessageWithOutcome(
                content: "Ping",
                relatedTaskID: UUID()
            )
        }

        let o1 = await t1.value
        let o2 = await t2.value

        #expect(o1.succeeded)
        #expect(o1.didPersistUserMessage)
        #expect(!o1.shouldRestoreDraft)

        #expect(!o2.succeeded)
        #expect(!o2.didPersistUserMessage)
        #expect(o2.shouldRestoreDraft)

        #expect(store.pendingChatMessagesByProject[project.id] == nil)
        #expect(store.selectedChatMessages.filter { $0.senderKind == .user }.count == 1)
    }

    @Test("R1: sendingChatChannels remains active until all concurrent same-channel sends finish")
    @MainActor
    func sendingChatChannelsIsRefcountedAcrossConcurrentSends() async throws {
        actor SlowHookGate {
            private var slowEnteredContinuation: CheckedContinuation<Void, Never>?
            private var releaseSlowContinuation: CheckedContinuation<Void, Never>?
            private var slowEntered = false
            private var released = false

            func markSlowEnteredAndWait() async {
                slowEntered = true
                slowEnteredContinuation?.resume()
                slowEnteredContinuation = nil
                if !released {
                    await withCheckedContinuation { cont in
                        releaseSlowContinuation = cont
                    }
                }
            }

            func waitUntilSlowEntered() async {
                if slowEntered { return }
                await withCheckedContinuation { cont in
                    slowEnteredContinuation = cont
                }
            }

            func releaseSlow() {
                released = true
                releaseSlowContinuation?.resume()
                releaseSlowContinuation = nil
            }
        }

        let gate = SlowHookGate()
        let (store, _, _, ws) = try makeInMemoryStore { _, message, _ in
            if message.content == "Slow" {
                await gate.markSlowEnteredAndWait()
            } else {
                try await Task.sleep(for: .milliseconds(50))
            }
            return []
        }
        defer { try? FileManager.default.removeItem(at: ws) }

        try await store.createProject(
            name: "ConcurrentSendingFlagProject",
            goal: "Verify sendingChatChannels is refcounted across overlapping same-channel sends",
            workspaceRoot: ws
        )
        defer { store.stopPollingForTermination() }

        let project = try #require(store.selectedProject)
        let channelKey = "\(project.id.uuidString):\(ChatChannelKind.crew.channelKey)"

        let slowTask = Task {
            await store.sendChatMessageWithOutcome(content: "Slow")
        }
        await gate.waitUntilSlowEntered()

        let fastTask = Task {
            await store.sendChatMessageWithOutcome(content: "Fast")
        }

        let fastOutcome = await fastTask.value
        #expect(fastOutcome.succeeded)
        #expect(store.sendingChatChannels.contains(channelKey))
        #expect(store.isSendingChat(forProject: project.id, channel: .crew))
        #expect(store.isSendingSelectedChat)

        await gate.releaseSlow()
        let slowOutcome = await slowTask.value
        #expect(slowOutcome.succeeded)
        #expect(!store.sendingChatChannels.contains(channelKey))
        #expect(!store.isSendingChat(forProject: project.id, channel: .crew))
        #expect(!store.isSendingSelectedChat)
        #expect(store.selectedChatMessages.filter { $0.senderKind == .user }.count == 2)
    }

    @Test("R1/R3: >210 crew chat messages or agent A work entries do not evict active direct chat or agent B work feed")
    @MainActor
    func over210ProjectWideItemsDoNotEvictActiveDirectChannelOrAgentWorkFeed() async throws {
        let (store, db, cp, ws) = try makeInMemoryStore()
        defer { try? FileManager.default.removeItem(at: ws) }

        try await store.createProject(
            name: "NoEvictionProject",
            goal: "Verify per-channel and per-agent retention past 200 project-wide items",
            workspaceRoot: ws,
            starterRoles: [.researcher, .coder]
        )
        defer { store.stopPollingForTermination() }

        let project = try #require(store.selectedProject)
        let researcher = try #require(store.selectedProjectAgents.first(where: { $0.role == .researcher }))
        let coder = try #require(store.selectedProjectAgents.first(where: { $0.role == .coder }))

        let baseDate = Date(timeIntervalSince1970: 1_700_100_000)

        // Seed 3 older direct messages for researcher and 3 older work entries for coder
        for i in 0..<3 {
            try await db.insertChatMessage(ChatMessage(
                projectID: project.id,
                channelKind: .direct(agentID: researcher.id),
                senderKind: .agent,
                senderAgentID: researcher.id,
                senderName: researcher.name,
                content: "DirectOld_\(i)",
                createdAt: baseDate.addingTimeInterval(Double(i) - 100.0)
            ))
            try await db.insertAgentWorkEntry(AgentWorkEntry(
                projectID: project.id,
                agentID: coder.id,
                agentName: coder.name,
                stepNumber: i + 1,
                phase: .fileEdit,
                summary: "CoderOld_\(i)",
                createdAt: baseDate.addingTimeInterval(Double(i) - 100.0)
            ))
        }

        // Seed 215 newer crew messages and 215 newer researcher work entries
        for i in 0..<215 {
            try await db.insertChatMessage(ChatMessage(
                projectID: project.id,
                channelKind: .crew,
                senderKind: .agent,
                senderAgentID: researcher.id,
                senderName: researcher.name,
                content: "CrewNew_\(i)",
                createdAt: baseDate.addingTimeInterval(Double(i))
            ))
            try await db.insertAgentWorkEntry(AgentWorkEntry(
                projectID: project.id,
                agentID: researcher.id,
                agentName: researcher.name,
                stepNumber: i + 1,
                phase: .reasoning,
                summary: "ResearcherNew_\(i)",
                createdAt: baseDate.addingTimeInterval(Double(i))
            ))
        }

        store.selectChatChannel(.direct(agentID: researcher.id))
        store.setWorkFeedFilter(agentID: coder.id)
        await store.refreshProjectDetails(projectID: project.id, notifyExceptions: false)

        let directMessages = store.selectedChatMessages
        #expect(directMessages.map(\.content) == ["DirectOld_0", "DirectOld_1", "DirectOld_2"])

        let coderFeed = store.selectedWorkFeed
        #expect(coderFeed.map(\.summary) == ["CoderOld_0", "CoderOld_1", "CoderOld_2"])

        // Also ensure controlPlane snapshot stays usable without error
        #expect(cp.projects.contains(where: { $0.id == project.id }))
    }

    private func pngDimensionsAndMeanLuminance(at url: URL) throws -> (width: Int, height: Int, meanLuminance: Double) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "M3WorkspaceUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read PNG at \(url.path)"])
        }
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw NSError(domain: "M3WorkspaceUITests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sum: Double = 0
        var count: Double = 0
        let step = max(1, (width * height) / 4096)
        var idx = 0
        while idx < width * height {
            let offset = idx * 4
            let r = Double(buffer[offset]) / 255.0
            let g = Double(buffer[offset + 1]) / 255.0
            let b = Double(buffer[offset + 2]) / 255.0
            sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
            count += 1
            idx += step
        }
        return (width, height, count > 0 ? sum / count : 0)
    }
}
