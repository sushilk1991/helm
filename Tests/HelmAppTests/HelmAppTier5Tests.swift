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

        for i in 0..<1000 {
            let uuid = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", i + 1))!
            let seed = AgentCharacterSeed(agentID: uuid, isOrchestrator: false)
            seen.insert(Tuple(crown: seed.crownIndex, eye: seed.eyeIndex, body: seed.bodyMask, hue: seed.hueIndex))
            crowns.insert(seed.crownIndex)
            eyes.insert(seed.eyeIndex)
            hues.insert(seed.hueIndex)
        }

        #expect(seen.count >= 998)
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

    private actor ToolCapturingProvider: LLMProvider {
        let kind: LLMBackendKind = .mock
        private(set) var capturedToolNames: [[String]] = []

        func complete(_ request: LLMRequest) async throws -> LLMResponse {
            capturedToolNames.append(request.tools.map(\.name))
            return LLMResponse(text: "DONE_WITHOUT_UNAUTHORIZED_TOOL")
        }
    }

    @Test("v0.1.3: AgyCLIProvider parsing, capability-filtered tools, approve grants capability, and safe update checkpoint")
    @MainActor
    func agyCapabilityAndSafeUpdateEndToEnd() async throws {
        // 1. Antigravity CLI (agy) parsing & alias matching
        #expect(LLMBackendKind.parse("agy") == .agyCLI)
        #expect(LLMBackendKind.parse("antigravity") == .agyCLI)
        #expect(LLMBackendKind.parse("tigravity") == .agyCLI)

        let agyJSON = """
        {"result":"AGY_READY","is_error":false,"usage":{"input_tokens":21,"output_tokens":9}}
        """
        let agyResp = try AgyCLIProvider.parseAgyOutput(agyJSON, hasTools: false)
        #expect(agyResp.text == "AGY_READY")
        #expect(agyResp.usage?.inputTokens == 21)
        #expect(agyResp.usage?.outputTokens == 9)

        let agyPlain = try AgyCLIProvider.parseAgyOutput("PLAIN_AGY_REPLY", hasTools: false)
        #expect(agyPlain.text == "PLAIN_AGY_REPLY")

        // 2. Capability-filtered tool schemas prevent unauthorized run_command calls
        let db = try HelmDatabase(path: ":memory:")
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("HelmV013_\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let capturing = ToolCapturingProvider()
        let registry = LLMProviderRegistry(providers: [.mock: capturing, .agyCLI: AgyCLIProvider()])
        let ocr = VisionOCRService()
        let router = ExecutionRouter()
        let browser = BrowseReadActTool(ocrService: ocr)
        let cp = HelmControlPlane(
            database: db,
            providerRegistry: registry,
            sandboxExecutor: router,
            browserService: browser
        )

        let project = try await cp.createProject(name: "CapFilter", goal: "Browse safely", workspaceRoot: ws)
        let browserAgent = try await cp.addAgent(
            projectID: project.id,
            name: "Lookout Browser",
            role: .browserAnalyst,
            goal: "Browse docs",
            backend: .mock,
            capabilities: [.browser, .ocr, .readSharedState, .proposeSharedState, .requestHumanDecision]
        )
        let task = DelegatedTask(
            projectID: project.id,
            assignedAgentID: browserAgent.id,
            title: "Audit public page",
            instructions: "Inspect public page"
        )
        let runner = AgentWorkerRunner(
            database: db,
            sharedStateStore: cp.sharedStateStore,
            providerRegistry: registry,
            sandboxExecutor: router,
            browserService: browser,
            stallDetector: StallDetector()
        )
        let outcome = await runner.executeAttempt(project: project, agent: browserAgent, task: task, stepIndex: 0)
        if case .completed = outcome {
            // Expected
        } else {
            Issue.record("Expected completed outcome, got \(outcome)")
        }
        let captured = await capturing.capturedToolNames
        let seenTools = try #require(captured.first)
        #expect(!seenTools.contains("run_command"))
        #expect(seenTools.contains("browser_act"))

        // 3. Approving an Unauthorized Capability Request grants the missing capability
        let capException = ExceptionAlert(
            projectID: project.id,
            taskID: nil,
            agentID: browserAgent.id,
            kind: .drift,
            severity: .critical,
            title: "Unauthorized Capability Request",
            summary: "Agent 'Lookout Browser' attempted 'run_command' without 'codeExec' capability.",
            dedupKey: "cap:\(browserAgent.id.uuidString)"
        )
        let gate = HumanDecisionGate(database: db)
        _ = try await gate.triggerHold(alert: capException)
        _ = try await cp.resolveException(exceptionID: capException.id, resolution: .approve)
        let updatedAgent = try #require(try await db.fetchAgent(id: browserAgent.id))
        #expect(updatedAgent.capabilities.contains(.codeExec))

        // 4. Safe update checkpoint preserves active projects for post-update resume
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
        await store.reloadAll()
        try await db.updateProjectStatus(id: project.id, status: .running)
        await store.reloadAll()
        #expect(store.runningProjectCount == 1)

        await store.checkpointAndPauseForUpdate()
        let pausedProject = try #require(try await db.fetchProject(id: project.id))
        #expect(pausedProject.status == .paused)
        let savedIDs = UserDefaults.standard.stringArray(forKey: "helm.v1.resumeAfterUpdateProjectIDs") ?? []
        #expect(savedIDs.contains(project.id.uuidString))
        UserDefaults.standard.removeObject(forKey: "helm.v1.resumeAfterUpdateProjectIDs")
        store.stopPollingForTermination()
    }

    @Test("CLIAuthService parsing, URL/device-code extraction, isolated env, and LLMAuthErrorDetector")
    func cliAuthServiceParsingAndErrorDetection() throws {
        // 1. Claude auth status JSON (loggedIn = true & false)
        let claudeLoggedInJSON = """
        {
          "loggedIn": true,
          "authMethod": "claude.ai",
          "email": "developer@example.com",
          "orgName": "Example Studio",
          "subscriptionType": "max",
          "planTier": "max_20x",
          "loginExpiresAt": "2027-01-01T00:00:00Z",
          "configDirectory": "/tmp/example-claude-config"
        }
        """
        let claudeSignedIn = CLIAuthService.parseClaudeAuthStatusJSON(claudeLoggedInJSON, profileMode: .helmIsolated)
        #expect(claudeSignedIn.isSignedIn)
        #expect(claudeSignedIn.badgeTitle == "Signed In")
        let claudeID = try #require(claudeSignedIn.identity)
        #expect(claudeID.provider == .claude)
        #expect(claudeID.email == "developer@example.com")
        #expect(claudeID.accountLabel == "Example Studio")
        #expect(claudeID.planTier == "max_20x")
        #expect(claudeID.authMethod == "claude.ai")
        #expect(claudeID.expiresAt == "2027-01-01T00:00:00Z")
        #expect(claudeID.profileMode == .helmIsolated)
        #expect(claudeID.configDirectory == "/tmp/example-claude-config")

        let claudeLoggedOut = CLIAuthService.parseClaudeAuthStatusJSON(#"{"loggedIn":false}"#, profileMode: .system)
        if case .signedOut(let detail) = claudeLoggedOut {
            #expect(detail?.contains("Claude") == true)
        } else {
            Issue.record("Expected .signedOut for loggedIn=false, got \(claudeLoggedOut)")
        }

        // 2. Codex login status parsing
        let codexChatGPT = CLIAuthService.parseCodexLoginStatus("Logged in using ChatGPT\n", exitCode: 0, profileMode: .system)
        #expect(codexChatGPT.isSignedIn)
        #expect(codexChatGPT.identity?.authMethod == "chatgpt")
        #expect(codexChatGPT.identity?.summary.contains("ChatGPT") == true)

        let codexAPIKey = CLIAuthService.parseCodexLoginStatus("Logged in using API key", exitCode: 0, profileMode: .helmIsolated)
        #expect(codexAPIKey.isSignedIn)
        #expect(codexAPIKey.identity?.authMethod == "api_key")

        let codexSignedOut = CLIAuthService.parseCodexLoginStatus("Not logged in", exitCode: 1, profileMode: .system)
        #expect(!codexSignedOut.isSignedIn)
        #expect(codexSignedOut.badgeTitle == "Signed Out")

        // 3. Antigravity (agy) models output parsing
        let agyModels = """
        ID\tNAME
        gemini-2.5-pro\tGemini 2.5 Pro
        claude-sonnet-4-5\tClaude Sonnet 4.5
        """
        let agySignedIn = CLIAuthService.parseAgyModelsOutput(agyModels, exitCode: 0, profileMode: .system)
        #expect(agySignedIn.isSignedIn)
        #expect(agySignedIn.identity?.summary == "Antigravity authenticated (2 models)")

        let agySignedOut = CLIAuthService.parseAgyModelsOutput("", exitCode: 1, profileMode: .system)
        #expect(!agySignedOut.isSignedIn)
        #expect(agySignedOut.badgeTitle == "Signed Out")

        // 4. URL extraction with ANSI escape codes & trailing punctuation
        let ansiLine = "\u{001B}[32mOpen browser:\u{001B}[0m (https://auth.example.com/oauth?state=abc123&scope=read)."
        let extractedURL = CLIAuthService.extractFirstURL(from: ansiLine)
        #expect(extractedURL?.absoluteString == "https://auth.example.com/oauth?state=abc123&scope=read")

        let localhostLine = "Callback ready at http://127.0.0.1:1455/auth/callback,"
        #expect(CLIAuthService.extractFirstURL(from: localhostLine)?.absoluteString == "http://127.0.0.1:1455/auth/callback")

        // 5. Device code extraction (ignores URLs & UUIDs)
        let devicePrompt = "\u{001B}[1mVisit https://auth.example.com/CODE-9999 and enter code WXYZ-1234 (req 550e8400-e29b-41d4-a716-446655440000)\u{001B}[0m"
        #expect(CLIAuthService.extractDeviceCode(from: devicePrompt) == "WXYZ-1234")
        #expect(CLIAuthService.extractDeviceCode(from: "Enter code ABCD-12345 to authorize.") == "ABCD-12345")
        #expect(CLIAuthService.extractDeviceCode(from: "Visit https://auth.example.com/ABCD-EFGH only") == nil)

        // 6. Auth error detection
        #expect(LLMAuthErrorDetector.detectRequiredAuthProvider(from: "Error: Not logged in · Please run claude auth login", backend: .claudeCLI) == .claude)
        #expect(LLMAuthErrorDetector.detectRequiredAuthProvider(from: "HTTP 401 Unauthorized: run codex login", backend: .codexCLI) == .codex)
        #expect(LLMAuthErrorDetector.detectRequiredAuthProvider(from: "Authentication required - please sign in", backend: .agyCLI) == .agy)
        #expect(LLMAuthErrorDetector.detectRequiredAuthProvider(from: "No credentials found / invalid API key", backend: .piCLI) == .pi)
        #expect(LLMAuthErrorDetector.detectRequiredAuthProvider(from: "Syntax error on line 4010", backend: .claudeCLI) == nil)
        #expect(LLMAuthErrorDetector.detectRequiredAuthProvider(from: "Not logged in", backend: .mock) == nil)

        // 7. Isolated profile environment variables
        let claudeEnv = CLIAuthService.authEnvironment(for: .claude, profileMode: .helmIsolated, baseEnvironment: [:])
        #expect(claudeEnv["CLAUDE_CONFIG_DIR"]?.hasSuffix("/Library/Application Support/Helm/auth/claude") == true)
        #expect(claudeEnv["PATH"]?.contains("/opt/homebrew/bin") == true)

        let codexEnv = CLIAuthService.authEnvironment(for: .codex, profileMode: .helmIsolated, baseEnvironment: [:])
        #expect(codexEnv["CODEX_HOME"]?.hasSuffix("/Library/Application Support/Helm/auth/codex") == true)

        let piEnv = CLIAuthService.authEnvironment(for: .pi, profileMode: .helmIsolated, baseEnvironment: [:])
        #expect(piEnv["PI_CODING_AGENT_DIR"]?.hasSuffix("/Library/Application Support/Helm/auth/pi") == true)

        let systemEnv = CLIAuthService.authEnvironment(for: .claude, profileMode: .system, baseEnvironment: claudeEnv)
        #expect(systemEnv["CLAUDE_CONFIG_DIR"] == nil)
    }
}
