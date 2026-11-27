import Foundation
@testable import HelmAppCore
@testable import HelmBrowser
@testable import HelmCore
@testable import HelmIsolation
import Testing

private struct AppTier5EchoSandbox: SandboxExecutor {
    let output: String

    func execute(_ request: ExecutionRequest) async throws -> ExecutionResult {
        ExecutionResult(
            requestID: request.id,
            modeUsed: .seatbeltSandbox,
            exitCode: 0,
            stdout: output,
            stderr: "",
            timedOut: false,
            truncatedOutput: false,
            durationMs: 5.0
        )
    }

    func shutdownWorkspace(_ projectID: UUID) async {}
}

@Suite("HelmAppCore Tier 5 UI State & Helper Tests")
struct HelmAppTier5Tests {
    @Test("MINOR-1: HelmWorkspaceStore.resolveException restarts 0-task project after stall hold")
    @MainActor
    func resolveExceptionRestartsZeroTaskProject() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("HelmAppT5_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let ocr = VisionOCRService()
        let router = ExecutionRouter()
        let browser = BrowseReadActTool(ocrService: ocr)
        let cp = HelmControlPlane(
            database: db,
            providerRegistry: .makeDefault(),
            sandboxExecutor: router,
            browserService: browser
        )
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

        try await store.createProject(name: "ZeroTaskRestart", goal: "Recover from 0-task stall", workspaceRoot: ws)
        let project = try #require(store.selectedProject)
        _ = try await cp.addAgent(projectID: project.id, name: "Coder", role: .coder, goal: "Build", backend: .mock)
        await store.reloadAll()

        await store.simulateCondition(.stall)
        #expect(store.selectedProjectOpenExceptions.count == 1)
        #expect(store.selectedProjectTasks.isEmpty)

        let alert = store.selectedProjectOpenExceptions[0]
        await store.resolveException(alert, resolution: .retry)

        // Wait briefly for the restarted project to settle to .completed
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            await store.reloadAll()
            if store.selectedProject?.status == .completed {
                break
            }
            try await Task.sleep(for: .milliseconds(30))
        }

        #expect(store.selectedProject?.status == .completed)
        #expect(store.selectedProjectOpenExceptions.isEmpty)
        store.stopPollingForTermination()
    }

    @Test("MINOR-2: AgentRolePreset.apply updates unedited defaults across presets and preserves user edits")
    func addAgentPresetSwitching() {
        var name = ""
        var goal = ""
        var caps: Set<AgentCapability> = []
        var lastAutoName = ""
        var lastAutoGoal = ""

        // Initial apply (.researcher)
        AgentRolePreset.apply(
            role: .researcher,
            name: &name,
            goal: &goal,
            capabilities: &caps,
            lastAutoName: &lastAutoName,
            lastAutoGoal: &lastAutoGoal
        )
        #expect(name == "Chart Researcher")
        #expect(goal.contains("specifications"))
        #expect(!caps.contains(.codeExec))

        // Switch to .coder without editing -> both name & goal update
        AgentRolePreset.apply(
            role: .coder,
            name: &name,
            goal: &goal,
            capabilities: &caps,
            lastAutoName: &lastAutoName,
            lastAutoGoal: &lastAutoGoal
        )
        #expect(name == "Forge Coder")
        #expect(goal.contains("sandbox"))
        #expect(caps.contains(.codeExec))

        // User edits name only, then switches to .browserAnalyst -> custom name preserved, goal & caps updated
        name = "Custom Lookout"
        AgentRolePreset.apply(
            role: .browserAnalyst,
            name: &name,
            goal: &goal,
            capabilities: &caps,
            lastAutoName: &lastAutoName,
            lastAutoGoal: &lastAutoGoal
        )
        #expect(name == "Custom Lookout")
        #expect(goal.contains("OCR/DOM"))
        #expect(caps.contains(.browser))
        #expect(caps.contains(.ocr))
    }

    @Test("AgentCharacterSeed generates 1000 unique tuples across all crowns, eyes, and hues")
    func characterSeedDiversity1000() {
        struct Tuple: Hashable {
            let crown: Int
            let eye: Int
            let body: UInt16
            let hue: Int
        }
        var seen: Set<Tuple> = []
        var crowns: Set<Int> = []
        var eyes: Set<Int> = []
        var hues: Set<Int> = []

        for _ in 0..<1000 {
            let seed = AgentCharacterSeed(agentID: UUID(), isOrchestrator: false)
            seen.insert(Tuple(crown: seed.crownIndex, eye: seed.eyeIndex, body: seed.bodyMask, hue: seed.hueIndex))
            crowns.insert(seed.crownIndex)
            eyes.insert(seed.eyeIndex)
            hues.insert(seed.hueIndex)
        }

        #expect(seen.count == 1000)
        #expect(crowns.count == 8)
        #expect(eyes.count == 6)
        #expect(hues.count == 6)
    }

    @Test("HeadlessSnapshotRunner validates --snapshot-dir flags and rejects file path as snapshot directory")
    @MainActor
    func headlessSnapshotRunnerFlagValidation() async throws {
        #expect(HeadlessSnapshotRunner.parseSnapshotDir(arguments: ["Helm"]) == .notRequested)
        #expect(HeadlessSnapshotRunner.parseSnapshotDir(arguments: ["Helm", "--snapshot-dir", "/tmp/out"]) == .valid("/tmp/out"))
        #expect(HeadlessSnapshotRunner.parseSnapshotDir(arguments: ["Helm", "--snapshot-dir=/tmp/out2"]) == .valid("/tmp/out2"))

        if case .invalid = HeadlessSnapshotRunner.parseSnapshotDir(arguments: ["Helm", "--snapshot-dir"]) {
            // expected
        } else {
            Issue.record("Expected .invalid for missing --snapshot-dir value")
        }

        if case .invalid = HeadlessSnapshotRunner.parseSnapshotDir(arguments: ["Helm", "--snapshot-dir=   "]) {
            // expected
        } else {
            Issue.record("Expected .invalid for empty --snapshot-dir= value")
        }

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("helm_snap_not_dir_\(UUID().uuidString)")
        try Data("not a dir".utf8).write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        await #expect(throws: Error.self) {
            try await HeadlessSnapshotRunner.run(snapshotDirectory: tmpFile, reduceMotion: true)
        }
    }

    @Test("NEW-BUG-1: HelmWorkspaceStore.reloadAll surfaces latest ExecutionResult when project has >210 events")
    @MainActor
    func storeReloadAllPopulatesExecutionResultPast200Events() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("HelmAppOver200_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let ocr = VisionOCRService()
        let router = ExecutionRouter()
        let browser = BrowseReadActTool(ocrService: ocr)
        let mockSandbox = AppTier5EchoSandbox(output: "APP_OVER_200_OK")

        let mockLLM = MockLLMProvider(scenario: .customHandler { req in
            if req.userPrompt.contains("DECOMPOSE_GOAL") {
                return LLMResponse(text: """
                {"tasks":[{"temp_id":"t1","title":"Run cmd","instructions":"Execute","assigned_agent_id":"","waiting_on_temp_ids":[]}]}
                """)
            }
            let args = "{\"command\":\"echo APP_OVER_200_OK\"}"
            return LLMResponse(
                text: "{\"tool_calls\":[{\"id\":\"c1\",\"name\":\"run_command\",\"arguments\":\(args)}]}",
                toolCalls: [LLMToolCall(id: "c1", name: "run_command", argumentsJSON: args)]
            )
        })

        let cp = HelmControlPlane(
            database: db,
            providerRegistry: .makeDefault(mockProvider: mockLLM),
            sandboxExecutor: mockSandbox,
            browserService: browser
        )
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

        try await store.createProject(name: "Over200UI", goal: "Verify latest events in store", workspaceRoot: ws)
        let project = try #require(store.selectedProject)
        _ = try await cp.addAgent(
            projectID: project.id,
            name: "Forge",
            role: .coder,
            goal: "Run command",
            backend: .mock,
            capabilities: [.codeExec, .readSharedState]
        )

        for idx in 1...215 {
            try await db.appendEvent(RunEvent(
                projectID: project.id,
                kind: .heartbeatSteadyOK,
                summary: "HIST_UI_\(idx)",
                trustLevel: .orchestratorVerified
            ))
        }

        let report = try await cp.runProjectUntilSettled(projectID: project.id, maxSteps: 6)
        #expect(report.status == .completed)

        await store.reloadAll()
        #expect(store.selectedProjectEvents.count == 200)
        #expect(store.selectedProjectEvents.contains(where: { $0.kind == .toolExecuted }))
        let latestExec = try #require(store.selectedLatestExecutionResult)
        #expect(latestExec.stdout == "APP_OVER_200_OK")
        store.stopPollingForTermination()
    }

    @Test("NEW-BUG-3: HelmWorkspaceStore.pauseSelectedProject preserves .held when drift exception is open")
    @MainActor
    func storePausePreservesHeld() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("HelmAppPauseHeld_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let ocr = VisionOCRService()
        let router = ExecutionRouter()
        let browser = BrowseReadActTool(ocrService: ocr)
        let cp = HelmControlPlane(
            database: db,
            providerRegistry: .makeDefault(),
            sandboxExecutor: router,
            browserService: browser
        )
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

        try await store.createProject(name: "PauseHeldUI", goal: "Preserve held", workspaceRoot: ws)
        let project = try #require(store.selectedProject)
        _ = try await cp.addAgent(projectID: project.id, name: "Coder", role: .coder, goal: "Run", backend: .mock)
        await store.reloadAll()

        await store.simulateCondition(.drift)
        #expect(store.selectedProject?.status == .held)
        #expect(store.selectedProjectOpenExceptions.count == 1)

        await store.pauseSelectedProject()
        #expect(store.selectedProject?.status == .held)
        #expect(store.selectedProjectOpenExceptions.count == 1)
        store.stopPollingForTermination()
    }

    @Test("HelmSemVer and AppUpdateManager parse GitHub releases and compare versions accurately")
    @MainActor
    func updateManagerParsesReleaseAndComparesSemVer() throws {
        let v010 = try #require(HelmSemVer(parsing: "v0.1.0"))
        let v011 = try #require(HelmSemVer(parsing: "0.1.1"))
        let v020 = try #require(HelmSemVer(parsing: "v0.2.0-beta.1"))
        let v100 = try #require(HelmSemVer(parsing: "1.0.0"))
        #expect(v010 < v011)
        #expect(v011 < v020)
        #expect(v020 < v100)
        #expect(HelmSemVer(parsing: "not-a-version") == nil)

        let payload = """
        {
          "tag_name": "v0.2.0",
          "name": "Helm v0.2.0",
          "body": "Improved autonomous workflows.",
          "html_url": "https://github.com/sushilk1991/helm/releases/tag/v0.2.0",
          "assets": [
            {
              "name": "Helm-0.2.0-arm64.dmg",
              "browser_download_url": "https://github.com/sushilk1991/helm/releases/download/v0.2.0/Helm-0.2.0-arm64.dmg"
            },
            {
              "name": "Helm-0.2.0-arm64.dmg.sha256",
              "browser_download_url": "https://github.com/sushilk1991/helm/releases/download/v0.2.0/Helm-0.2.0-arm64.dmg.sha256"
            }
          ]
        }
        """
        let info = try AppUpdateManager.parseGitHubRelease(data: Data(payload.utf8))
        #expect(info.version == HelmSemVer(major: 0, minor: 2, patch: 0))
        #expect(info.dmgURL?.lastPathComponent == "Helm-0.2.0-arm64.dmg")
        #expect(info.sha256URL?.lastPathComponent == "Helm-0.2.0-arm64.dmg.sha256")
        #expect(info.notes == "Improved autonomous workflows.")
    }

    @Test("Agent personality, PiCLI backend, auto repo naming, and updateAgent persist durably")
    @MainActor
    func agentPersonalityAndPiCLIEndToEnd() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("awesome-repo-\(UUID().uuidString.prefix(5))")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let ocr = VisionOCRService()
        let router = ExecutionRouter()
        let browser = BrowseReadActTool(ocrService: ocr)
        let cp = HelmControlPlane(
            database: db,
            providerRegistry: .makeDefault(),
            sandboxExecutor: router,
            browserService: browser
        )
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

        // Empty project name automatically derives repo folder name
        try await store.createProject(name: "", goal: "Ship features", workspaceRoot: ws, leadPersonality: .methodicalArchitect)
        let project = try #require(store.selectedProject)
        #expect(project.name == ws.lastPathComponent)

        let lead = try #require(store.selectedProjectAgents.first(where: { $0.role == .orchestrator }))
        #expect(lead.personality == .methodicalArchitect)

        // Update Lead personality, notes, backend (Pi CLI), and permissions
        try await store.updateAgent(
            agentID: lead.id,
            backend: .piCLI,
            personality: .adversarialReviewer,
            personalityNotes: "Be concise and verify every diff.",
            capabilities: [.readSharedState, .proposeSharedState, .delegateTasks, .codeExec]
        )

        let refreshedLead = try #require(store.selectedProjectAgents.first(where: { $0.id == lead.id }))
        #expect(refreshedLead.personality == .adversarialReviewer)
        #expect(refreshedLead.personalityNotes == "Be concise and verify every diff.")
        #expect(refreshedLead.backend == .piCLI)
        #expect(refreshedLead.capabilities.contains(.codeExec))

        // Verify PiCLIProvider parses Pi JSONL stream and plain text cleanly
        let piJSONL = """
        {"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hello "}}
        {"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"PI_OK"}],"usage":{"input":12,"output":4}}}
        """
        let parsed = try PiCLIProvider.parsePiOutput(piJSONL, hasTools: false)
        #expect(parsed.text == "PI_OK")
        #expect(parsed.usage?.inputTokens == 12)
        #expect(LLMBackendKind.parse("pycli") == .piCLI)
        #expect(LLMBackendKind.parse("pi") == .piCLI)
        store.stopPollingForTermination()
    }
}
