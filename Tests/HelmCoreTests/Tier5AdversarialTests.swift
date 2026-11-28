import Foundation
@testable import HelmBrowser
@testable import HelmCore
@testable import HelmIsolation
import Network
import Testing

// MARK: - Test Doubles

private actor SpyBrowserService: BrowserOCRService {
    private let database: HelmDatabase
    private let observedAgentID: UUID
    private(set) var openCalls: Int = 0
    private(set) var performCalls: [BrowserAction] = []
    private(set) var closeCalls: Int = 0
    private(set) var agentStatesDuringPerform: [AgentActivityState] = []

    init(database: HelmDatabase, observedAgentID: UUID) {
        self.database = database
        self.observedAgentID = observedAgentID
    }

    func openSession(projectID: UUID) async throws -> UUID {
        openCalls += 1
        return UUID()
    }

    func perform(_ action: BrowserAction, sessionID: UUID, timeoutSeconds: TimeInterval) async throws -> BrowserObservation {
        performCalls.append(action)
        if let agent = try? await database.fetchAgent(id: observedAgentID) {
            agentStatesDuringPerform.append(agent.activityState)
        }
        let pngURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("spy_browser_\(UUID().uuidString).png")
        try Data("PNG_SPY".utf8).write(to: pngURL)

        let line = OCRLine(
            text: "ORDER CONFIRMED",
            confidence: 0.99,
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.05),
            cssRect: CGRect(x: 128, y: 120, width: 384, height: 40)
        )
        return BrowserObservation(
            url: "http://127.0.0.1/result",
            title: "Order Confirmed",
            viewportSize: CGSize(width: 1280, height: 800),
            screenshotPNGPath: pngURL,
            ocrLines: [line],
            domElements: [],
            trustTag: .untrustedData,
            latencyMs: 12.0
        )
    }

    func closeSession(_ sessionID: UUID) async {
        closeCalls += 1
    }
}

private struct TimedOutExitZeroSandbox: SandboxExecutor {
    func execute(_ request: ExecutionRequest) async throws -> ExecutionResult {
        ExecutionResult(
            requestID: request.id,
            modeUsed: .seatbeltSandbox,
            exitCode: 0,
            stdout: "partial",
            stderr: "",
            timedOut: true,
            truncatedOutput: false,
            durationMs: 100.0
        )
    }

    func shutdownWorkspace(_ projectID: UUID) async {}
}

private struct EchoSuccessSandbox: SandboxExecutor {
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
            durationMs: 8.0
        )
    }

    func shutdownWorkspace(_ projectID: UUID) async {}
}

private actor DeletingBrowserService: BrowserOCRService {
    private var sessionDirs: [UUID: URL] = [:]
    private(set) var lastTempScreenshotURL: URL?

    func openSession(projectID: UUID) async throws -> UUID {
        let sid = UUID()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("T5_DeletingBrowser_\(sid.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionDirs[sid] = dir
        return sid
    }

    func perform(_ action: BrowserAction, sessionID: UUID, timeoutSeconds: TimeInterval) async throws -> BrowserObservation {
        let dir = sessionDirs[sessionID] ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shotURL = dir.appendingPathComponent("shot_\(UUID().uuidString).png")
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("FAKE_PNG_BODY".utf8)
        try pngBytes.write(to: shotURL)
        lastTempScreenshotURL = shotURL
        return BrowserObservation(
            url: "http://127.0.0.1/persisted",
            title: "Persisted Screenshot Page",
            viewportSize: CGSize(width: 1280, height: 800),
            screenshotPNGPath: shotURL,
            ocrLines: [
                OCRLine(
                    text: "PERSISTED OK",
                    confidence: 0.98,
                    normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.05),
                    cssRect: CGRect(x: 128, y: 120, width: 256, height: 40)
                )
            ],
            domElements: [],
            trustTag: .untrustedData,
            latencyMs: 9.0
        )
    }

    func closeSession(_ sessionID: UUID) async {
        if let dir = sessionDirs.removeValue(forKey: sessionID) {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

private actor MissingScreenshotBrowserService: BrowserOCRService {
    func openSession(projectID: UUID) async throws -> UUID { UUID() }

    func perform(_ action: BrowserAction, sessionID: UUID, timeoutSeconds: TimeInterval) async throws -> BrowserObservation {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does_not_exist_\(UUID().uuidString).png")
        return BrowserObservation(
            url: "http://127.0.0.1/mock",
            title: "Mock Missing Shot",
            viewportSize: CGSize(width: 1280, height: 800),
            screenshotPNGPath: missing,
            ocrLines: [],
            domElements: [],
            trustTag: .untrustedData,
            latencyMs: 3.0
        )
    }

    func closeSession(_ sessionID: UUID) async {}
}

private final class LocalOpenAIServer: @unchecked Sendable {
    let port: UInt16
    let host: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Tier5AdversarialTests.LocalOpenAIServer")

    private init(listener: NWListener, port: UInt16, host: String) {
        self.listener = listener
        self.port = port
        self.host = host
    }

    static func start(
        useIPv6: Bool = false,
        responder: @escaping @Sendable (String) -> String
    ) async throws -> LocalOpenAIServer {
        let params = NWParameters.tcp
        let endpointHost: NWEndpoint.Host = useIPv6 ? "::1" : "127.0.0.1"
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: endpointHost, port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "Tier5AdversarialTests.HTTPQueue")

        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            Self.readFullHTTPRequest(conn: conn, buffer: Data()) { rawReq in
                let assistantJSON = responder(rawReq)
                let responseBodyObj: [String: Any] = [
                    "id": "chatcmpl-tier5",
                    "object": "chat.completion",
                    "choices": [
                        [
                            "index": 0,
                            "message": [
                                "role": "assistant",
                                "content": assistantJSON,
                            ],
                            "finish_reason": "stop",
                        ]
                    ],
                    "usage": ["prompt_tokens": 20, "completion_tokens": 20],
                ]
                let bodyData = (try? JSONSerialization.data(withJSONObject: responseBodyObj)) ?? Data("{}".utf8)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
                var packet = Data(header.utf8)
                packet.append(bodyData)
                conn.send(content: packet, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    if let p = listener.port?.rawValue {
                        cont.resume(returning: p)
                    } else {
                        cont.resume(throwing: LLMProviderError.networkFailure("Missing listener port"))
                    }
                case .failed(let err):
                    once.done = true
                    cont.resume(throwing: err)
                case .cancelled:
                    once.done = true
                    cont.resume(throwing: LLMProviderError.networkFailure("Listener cancelled"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        return LocalOpenAIServer(listener: listener, port: port, host: useIPv6 ? "[::1]" : "127.0.0.1")
    }

    func stop() {
        listener.cancel()
    }

    private static func readFullHTTPRequest(
        conn: NWConnection,
        buffer: Data,
        completion: @escaping @Sendable (String) -> Void
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, _ in
            var acc = buffer
            if let data {
                acc.append(data)
            }
            if let raw = String(data: acc, encoding: .utf8),
               let headerRange = raw.range(of: "\r\n\r\n") {
                let headers = String(raw[..<headerRange.lowerBound])
                let bodyOffset = raw.distance(from: raw.startIndex, to: headerRange.upperBound)
                let contentLength = headers
                    .split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":").dropFirst().joined().trimmingCharacters(in: .whitespaces)) } ?? 0
                let bodyCount = acc.count - headers.utf8.count - 4
                if bodyCount >= contentLength || isComplete {
                    _ = bodyOffset
                    completion(raw)
                    return
                }
            } else if isComplete {
                completion(String(decoding: acc, as: UTF8.self))
                return
            }
            readFullHTTPRequest(conn: conn, buffer: acc, completion: completion)
        }
    }
}

// MARK: - Tier 5 Adversarial Tests

@Suite("Tier 5 Adversarial Hardening & Regression Suite")
struct Tier5AdversarialTests {
    @Test("CRITICAL-1a: AgentWorkerRunner exposes browser_act, transitions to .browsing, tags observation untrustedData, and inserts ArtifactRecord")
    func agentWorkerExposesAndExecutesBrowserAct() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let store = SharedStateStore(database: db)
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("T5_BrowserTool_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let project = Project(name: "BrowserOrch", goal: "Browse and verify", workspaceRoot: ws)
        try await db.insertProject(project)
        let browserAgent = AgentProfile(
            projectID: project.id,
            name: "Lookout",
            role: .browserAnalyst,
            goal: "Browse fixture",
            capabilities: [.browser, .ocr, .readSharedState, .proposeSharedState],
            backend: .mock
        )
        try await db.insertAgent(browserAgent)

        let spy = SpyBrowserService(database: db, observedAgentID: browserAgent.id)
        actor ToolCapture {
            var offeredToolNames: [String] = []
            func set(_ names: [String]) { offeredToolNames = names }
        }
        let capture = ToolCapture()

        let mock = MockLLMProvider(scenario: .customHandler { req in
            if req.userPrompt.contains("DECOMPOSE_GOAL") {
                return LLMResponse(text: """
                {"tasks":[{"temp_id":"t1","title":"Check page","instructions":"Browse /form and click SUBMIT ORDER","assigned_agent_id":"\(browserAgent.id.uuidString)","waiting_on_temp_ids":[]}]}
                """)
            }
            if req.userPrompt.contains("[Execution Transcript]") {
                let args = "{\"summary\":\"Browser observed and clicked SUBMIT ORDER\"}"
                return LLMResponse(
                    text: "{\"tool_calls\":[{\"id\":\"done1\",\"name\":\"complete_task\",\"arguments\":\(args)}]}",
                    toolCalls: [LLMToolCall(id: "done1", name: "complete_task", argumentsJSON: args)]
                )
            }
            await capture.set(req.tools.map(\.name))
            let args = "{\"action\":\"click_ocr\",\"url\":\"http://127.0.0.1/form\",\"query\":\"SUBMIT ORDER\"}"
            return LLMResponse(
                text: "{\"tool_calls\":[{\"id\":\"b1\",\"name\":\"browser_act\",\"arguments\":\(args)}]}",
                toolCalls: [LLMToolCall(id: "b1", name: "browser_act", argumentsJSON: args)]
            )
        })

        let orchestrator = OrchestratorActor(
            projectID: project.id,
            database: db,
            sharedStateStore: store,
            providerRegistry: .makeDefault(mockProvider: mock),
            browserService: spy
        )

        let report = try await orchestrator.run(maxSteps: 6)
        #expect(report.status == .completed)
        #expect(report.alertsSurfaced == 0)

        let offered = await capture.offeredToolNames
        #expect(offered.contains("browser_act"))

        let openCount = await spy.openCalls
        let closeCount = await spy.closeCalls
        let performed = await spy.performCalls
        let statesDuring = await spy.agentStatesDuringPerform
        #expect(openCount == 1)
        #expect(closeCount == 1)
        #expect(performed == [.navigate(url: "http://127.0.0.1/form"), .clickOCRText(query: "SUBMIT ORDER")])
        #expect(statesDuring == [.browsing, .browsing])

        let finalAgent = try #require(try await db.fetchAgent(id: browserAgent.id))
        #expect(finalAgent.activityState == .completed)

        let hasUntrustedObs = report.sharedState.contains { entry in
            entry.category == .observation && entry.trustLevel == .untrustedData
        }
        let hasBrowserArtifact = report.artifacts.contains { artifact in
            artifact.kind == "browser_screenshot" && artifact.mimeType == "image/png"
        }
        #expect(hasUntrustedObs)
        #expect(hasBrowserArtifact)

        let events = try await db.listEvents(projectID: project.id)
        let hasToolExecutedEvent = events.contains { event in
            event.kind == .toolExecuted && event.trustLevel == .untrustedData
        }
        #expect(hasToolExecutedEvent)
    }

    @Test("CRITICAL-1b: HelmCLIRunner run executes run_command via ExecutionRouter without M1 stub error")
    func helmCLIRunWiresExecutionRouter() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("T5_CLIRun_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("cli_t5.sqlite").path
        let wsDir = dir.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)

        let createOut = await HelmCLIRunner.run(arguments: [
            "project", "create", "--name", "CLISandbox", "--goal", "Execute shell command", "--workspace", wsDir.path, "--db", dbPath,
        ])
        #expect(createOut.exitCode == 0)
        let project = try HelmJSON.makeDecoder().decode(Project.self, from: Data(createOut.stdout.utf8))

        let agentOut = await HelmCLIRunner.run(arguments: [
            "agent", "add", "--project", project.id.uuidString,
            "--name", "Runner", "--role", "coder", "--goal", "Run command",
            "--backend", "http", "--capabilities", "codeExec,readSharedState", "--db", dbPath,
        ])
        #expect(agentOut.exitCode == 0)
        let agent = try HelmJSON.makeDecoder().decode(AgentProfile.self, from: Data(agentOut.stdout.utf8))

        let server = try await LocalOpenAIServer.start { rawReq in
            if rawReq.contains("DECOMPOSE_GOAL") {
                return "{\"tasks\":[{\"temp_id\":\"t1\",\"title\":\"Write marker\",\"instructions\":\"Run echo\",\"assigned_agent_id\":\"\(agent.id.uuidString)\",\"waiting_on_temp_ids\":[]}]}"
            }
            if rawReq.contains("[Execution Transcript]") {
                return "{\"thought\":\"done\",\"tool_calls\":[{\"id\":\"done1\",\"name\":\"complete_task\",\"arguments\":{\"summary\":\"T5_EXEC_OK\"}}]}"
            }
            return "{\"thought\":\"run cmd\",\"tool_calls\":[{\"id\":\"r1\",\"name\":\"run_command\",\"arguments\":{\"command\":\"printf 'T5_EXEC_OK' > t5_marker.txt && cat t5_marker.txt\"}}]}"
        }
        defer { server.stop() }

        let runOut = await HelmCLIRunner.run(
            arguments: ["run", "--project", project.id.uuidString, "--max-steps", "6", "--db", dbPath],
            environment: ["HELM_DIRECT_HTTP_URL": "http://\(server.host):\(server.port)/v1/chat/completions"],
            sandboxExecutorFactory: { ExecutionRouter() },
            browserServiceFactory: { BrowseReadActTool() }
        )
        #expect(runOut.exitCode == 0)
        let report = try HelmJSON.makeDecoder().decode(ProjectRunReport.self, from: Data(runOut.stdout.utf8))
        #expect(report.status == .completed)
        #expect(report.exceptions.isEmpty)
        let marker = try String(contentsOf: wsDir.appendingPathComponent("t5_marker.txt"), encoding: .utf8)
        #expect(marker == "T5_EXEC_OK")
    }

    @Test("MAJOR-1: HelmControlPlane double-start and pauseProject serialize task teardown without racing to .paused")
    func controlPlaneDoubleStartAndPauseSerialized() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("T5_DoubleStart_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let mock = MockLLMProvider(scenario: .customHandler { req in
            if req.userPrompt.contains("DECOMPOSE_GOAL") {
                return LLMResponse(text: """
                {"tasks":[{"temp_id":"t1","title":"Slow Step","instructions":"Wait 200ms then finish","assigned_agent_id":"","waiting_on_temp_ids":[]}]}
                """)
            }
            try await Task.sleep(for: .milliseconds(200))
            let args = "{\"summary\":\"Completed cleanly\"}"
            return LLMResponse(
                text: "{\"tool_calls\":[{\"id\":\"c1\",\"name\":\"complete_task\",\"arguments\":\(args)}]}",
                toolCalls: [LLMToolCall(id: "c1", name: "complete_task", argumentsJSON: args)]
            )
        })

        let cp = await MainActor.run {
            HelmControlPlane(database: db, providerRegistry: .makeDefault(mockProvider: mock))
        }
        let project = try await cp.createProject(name: "DoubleStart", goal: "No race", workspaceRoot: ws)
        _ = try await cp.addAgent(projectID: project.id, name: "Worker", role: .coder, goal: "Run", backend: .mock)

        // Rapid double-start must cancel first run, wait for unwind, and complete cleanly
        try await cp.startProject(projectID: project.id)
        try await Task.sleep(for: .milliseconds(40))
        try await cp.startProject(projectID: project.id)

        let deadline = Date().addingTimeInterval(4.0)
        var finalProject: Project?
        while Date() < deadline {
            finalProject = try await db.fetchProject(id: project.id)
            if finalProject?.status == .completed || finalProject?.status == .held || finalProject?.status == .failed {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(finalProject?.status == .completed)
        let tasks = try await db.listTasks(projectID: project.id)
        #expect(tasks.count == 1)
        #expect(tasks[0].status == .done)

        // Start then pause mid-flight must reliably settle in .paused without trailing overwrite
        let p2 = try await cp.createProject(name: "StartPause", goal: "Pause cleanly", workspaceRoot: ws)
        _ = try await cp.addAgent(projectID: p2.id, name: "Worker2", role: .coder, goal: "Run", backend: .mock)
        try await cp.startProject(projectID: p2.id)
        try await Task.sleep(for: .milliseconds(40))
        try await cp.pauseProject(projectID: p2.id)
        try await Task.sleep(for: .milliseconds(250))

        let p2After = try #require(try await db.fetchProject(id: p2.id))
        #expect(p2After.status == .paused)
    }

    @Test("MAJOR-3: OrchestratorActor.decomposeGoal enforces stepTimeoutSeconds via LLMTimeoutRace")
    func decomposeGoalEnforcesStepTimeout() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let store = SharedStateStore(database: db)
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("T5_DecomposeTimeout_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let project = Project(
            name: "DecomposeTimeout",
            goal: "Time out fast",
            workspaceRoot: ws,
            budgetPolicy: BudgetPolicy(stepTimeoutSeconds: 0.25, coordinatorStallSeconds: 5.0)
        )
        try await db.insertProject(project)
        let worker = AgentProfile(projectID: project.id, name: "Worker", role: .coder, goal: "Run", backend: .mock)
        try await db.insertAgent(worker)

        let slowMock = MockLLMProvider(scenario: .customHandler { _ in
            try await Task.sleep(for: .seconds(2.0))
            return LLMResponse(text: "{\"tasks\":[]}")
        })

        let orchestrator = OrchestratorActor(
            projectID: project.id,
            database: db,
            sharedStateStore: store,
            providerRegistry: .makeDefault(mockProvider: slowMock)
        )

        let start = ContinuousClock.now
        let report = try await orchestrator.run(maxSteps: 4)
        let elapsed = ContinuousClock.now - start
        let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        #expect(elapsedSec < 1.2)
        #expect(report.status == .held)
        #expect(report.exceptions.count == 1)
        #expect(report.exceptions.first?.kind == .stall)
    }

    @Test("MAJOR-4: AgentWorkerRunner treats ExecutionResult(exitCode: 0, timedOut: true) as failure and escalates to hold")
    func timedOutExitZeroTreatedAsFailure() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let store = SharedStateStore(database: db)
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("T5_TimedOutExit0_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let project = Project(
            name: "TimedOutExit0",
            goal: "Detect timedOut even on exit 0",
            workspaceRoot: ws,
            budgetPolicy: BudgetPolicy(maxConsecutiveToolFailures: 2)
        )
        try await db.insertProject(project)
        let worker = AgentProfile(
            projectID: project.id,
            name: "Coder",
            role: .coder,
            goal: "Run cmd",
            capabilities: [.codeExec, .readSharedState],
            backend: .mock
        )
        try await db.insertAgent(worker)

        let cmdMock = MockLLMProvider(scenario: .customHandler { req in
            if req.userPrompt.contains("DECOMPOSE_GOAL") {
                return LLMResponse(text: """
                {"tasks":[{"temp_id":"t1","title":"Run Cmd","instructions":"Execute","assigned_agent_id":"\(worker.id.uuidString)","waiting_on_temp_ids":[]}]}
                """)
            }
            let args = "{\"command\":\"echo partial\"}"
            return LLMResponse(
                text: "{\"tool_calls\":[{\"id\":\"r1\",\"name\":\"run_command\",\"arguments\":\(args)}]}",
                toolCalls: [LLMToolCall(id: "r1", name: "run_command", argumentsJSON: args)]
            )
        })

        let orchestrator = OrchestratorActor(
            projectID: project.id,
            database: db,
            sharedStateStore: store,
            providerRegistry: .makeDefault(mockProvider: cmdMock),
            sandboxExecutor: TimedOutExitZeroSandbox()
        )

        let report = try await orchestrator.run(maxSteps: 6)
        #expect(report.status == .held)
        #expect(report.alertsSurfaced == 1)
        #expect(report.steadyHeartbeats == 0)
        #expect(report.tasks.allSatisfy { $0.status != .done })
    }

    @Test("MINOR-5: DirectHTTPProvider exempts IPv6 loopback [::1] and honors HELM_LLM_BASE_URL fallback")
    func directHTTPAcceptsIPv6LoopbackAndBaseURL() async throws {
        let pBase = DirectHTTPProvider(environment: ["HELM_LLM_BASE_URL": "http://[::1]:59999"])
        #expect(pBase.endpointURL.absoluteString == "http://[::1]:59999/v1/chat/completions")

        let server = try await LocalOpenAIServer.start(useIPv6: true) { _ in
            "{\"thought\":\"ipv6\",\"final_response\":\"IPV6_LOOPBACK_OK\",\"steady_ok\":true}"
        }
        defer { server.stop() }

        let provider = DirectHTTPProvider(
            apiKeyProvider: { nil },
            environment: ["HELM_LLM_BASE_URL": "http://[::1]:\(server.port)"]
        )
        let req = LLMRequest(
            agentID: UUID(),
            projectID: UUID(),
            stepIndex: 0,
            systemPrompt: "Sys",
            userPrompt: "Ping"
        )
        let res = try await provider.complete(req)
        #expect(res.text.contains("IPV6_LOOPBACK_OK"))
    }

    @Test("NEW-BUG-1: HelmDatabase.listEvents returns latest limit events in chronological order past 200 events")
    func listEventsReturnsLatestLimitChronological() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let store = SharedStateStore(database: db)
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("T5_Over200_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let project = Project(name: "Over200Events", goal: "Retain newest events", workspaceRoot: ws)
        try await db.insertProject(project)
        let coder = AgentProfile(
            projectID: project.id,
            name: "Forge",
            role: .coder,
            goal: "Execute command",
            capabilities: [.codeExec, .readSharedState],
            backend: .mock
        )
        try await db.insertAgent(coder)

        // Insert 215 historical heartbeat events before running a command task
        for idx in 1...215 {
            try await db.appendEvent(RunEvent(
                projectID: project.id,
                kind: .heartbeatSteadyOK,
                summary: "HIST_EVENT_\(idx)",
                trustLevel: .orchestratorVerified
            ))
        }

        let mock = MockLLMProvider(scenario: .customHandler { req in
            if req.userPrompt.contains("DECOMPOSE_GOAL") {
                return LLMResponse(text: """
                {"tasks":[{"temp_id":"t1","title":"Run cmd","instructions":"Execute","assigned_agent_id":"\(coder.id.uuidString)","waiting_on_temp_ids":[]}]}
                """)
            }
            if req.userPrompt.contains("[Execution Transcript]") {
                let args = "{\"summary\":\"CORE_OVER_200_OK\"}"
                return LLMResponse(
                    text: "{\"tool_calls\":[{\"id\":\"done1\",\"name\":\"complete_task\",\"arguments\":\(args)}]}",
                    toolCalls: [LLMToolCall(id: "done1", name: "complete_task", argumentsJSON: args)]
                )
            }
            let args = "{\"command\":\"echo CORE_OVER_200_OK\"}"
            return LLMResponse(
                text: "{\"tool_calls\":[{\"id\":\"c1\",\"name\":\"run_command\",\"arguments\":\(args)}]}",
                toolCalls: [LLMToolCall(id: "c1", name: "run_command", argumentsJSON: args)]
            )
        })

        let orchestrator = OrchestratorActor(
            projectID: project.id,
            database: db,
            sharedStateStore: store,
            providerRegistry: .makeDefault(mockProvider: mock),
            sandboxExecutor: EchoSuccessSandbox(output: "CORE_OVER_200_OK")
        )
        let report = try await orchestrator.run(maxSteps: 6)
        #expect(report.status == .completed)

        let latest200 = try await db.listEvents(projectID: project.id, limit: 200)
        #expect(latest200.count == 200)
        #expect(!latest200.contains(where: { $0.summary == "HIST_EVENT_1" }))
        #expect(latest200.contains(where: { $0.kind == .toolExecuted }))
        #expect(latest200.last?.kind == .projectCompleted)

        let toolEvent = try #require(latest200.last(where: { $0.kind == .toolExecuted }))
        let payloadData = try #require(toolEvent.payloadJSON?.data(using: .utf8))
        let execResult = try HelmJSON.makeDecoder().decode(ExecutionResult.self, from: payloadData)
        #expect(execResult.stdout == "CORE_OVER_200_OK")
    }

    @Test("NEW-BUG-2: browser_act persists screenshot to workspace before closeSession deletes temp dir and handles missing file gracefully")
    func browserActPersistsScreenshotToWorkspaceBeforeClose() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let store = SharedStateStore(database: db)
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("T5_PersistShot_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let project = Project(name: "PersistShot", goal: "Persist browser screenshot", workspaceRoot: ws)
        try await db.insertProject(project)
        let lookout = AgentProfile(
            projectID: project.id,
            name: "Lookout",
            role: .browserAnalyst,
            goal: "Browse page",
            capabilities: [.browser, .ocr, .readSharedState, .proposeSharedState],
            backend: .mock
        )
        try await db.insertAgent(lookout)

        let browser = DeletingBrowserService()
        let mock = MockLLMProvider(scenario: .customHandler { req in
            if req.userPrompt.contains("DECOMPOSE_GOAL") {
                return LLMResponse(text: """
                {"tasks":[{"temp_id":"t1","title":"Browse","instructions":"Navigate","assigned_agent_id":"\(lookout.id.uuidString)","waiting_on_temp_ids":[]}]}
                """)
            }
            if req.userPrompt.contains("[Execution Transcript]") {
                let args = "{\"summary\":\"Persisted screenshot\"}"
                return LLMResponse(
                    text: "{\"tool_calls\":[{\"id\":\"done1\",\"name\":\"complete_task\",\"arguments\":\(args)}]}",
                    toolCalls: [LLMToolCall(id: "done1", name: "complete_task", argumentsJSON: args)]
                )
            }
            let args = "{\"action\":\"navigate\",\"url\":\"http://127.0.0.1/persisted\"}"
            return LLMResponse(
                text: "{\"tool_calls\":[{\"id\":\"b1\",\"name\":\"browser_act\",\"arguments\":\(args)}]}",
                toolCalls: [LLMToolCall(id: "b1", name: "browser_act", argumentsJSON: args)]
            )
        })

        let orchestrator = OrchestratorActor(
            projectID: project.id,
            database: db,
            sharedStateStore: store,
            providerRegistry: .makeDefault(mockProvider: mock),
            browserService: browser
        )
        let report = try await orchestrator.run(maxSteps: 6)
        #expect(report.status == .completed)

        let tempShot = try #require(await browser.lastTempScreenshotURL)
        #expect(!FileManager.default.fileExists(atPath: tempShot.path))

        let artifact = try #require(report.artifacts.first(where: { $0.kind == "browser_screenshot" }))
        #expect(artifact.relativePath.hasPrefix(".helm/artifacts/browser/"))
        let wsArtifactURL = ws.appendingPathComponent(artifact.relativePath)
        #expect(FileManager.default.fileExists(atPath: wsArtifactURL.path))
        #expect(artifact.byteSize > 0)

        let events = try await db.listEvents(projectID: project.id, limit: 200)
        let toolEvent = try #require(events.last(where: { $0.kind == .toolExecuted }))
        let obsData = try #require(toolEvent.payloadJSON?.data(using: .utf8))
        let obs = try HelmJSON.makeDecoder().decode(BrowserObservation.self, from: obsData)
        #expect(FileManager.default.fileExists(atPath: obs.screenshotPNGPath.path))
        #expect(obs.screenshotPNGPath.path.contains(".helm/artifacts/browser/"))

        // Graceful fallback when mock BrowserOCRService does not write a screenshot file
        let p2 = Project(name: "MissingShot", goal: "Handle missing PNG", workspaceRoot: ws)
        try await db.insertProject(p2)
        let a2 = AgentProfile(
            projectID: p2.id,
            name: "Lookout2",
            role: .browserAnalyst,
            goal: "Browse",
            capabilities: [.browser, .ocr, .readSharedState, .proposeSharedState],
            backend: .mock
        )
        try await db.insertAgent(a2)
        let mock2 = MockLLMProvider(scenario: .customHandler { req in
            if req.userPrompt.contains("DECOMPOSE_GOAL") {
                return LLMResponse(text: """
                {"tasks":[{"temp_id":"t1","title":"Browse","instructions":"Navigate","assigned_agent_id":"\(a2.id.uuidString)","waiting_on_temp_ids":[]}]}
                """)
            }
            if req.userPrompt.contains("[Execution Transcript]") {
                let args = "{\"summary\":\"Handled missing screenshot\"}"
                return LLMResponse(
                    text: "{\"tool_calls\":[{\"id\":\"done2\",\"name\":\"complete_task\",\"arguments\":\(args)}]}",
                    toolCalls: [LLMToolCall(id: "done2", name: "complete_task", argumentsJSON: args)]
                )
            }
            let args = "{\"action\":\"navigate\",\"url\":\"http://127.0.0.1/mock\"}"
            return LLMResponse(
                text: "{\"tool_calls\":[{\"id\":\"b2\",\"name\":\"browser_act\",\"arguments\":\(args)}]}",
                toolCalls: [LLMToolCall(id: "b2", name: "browser_act", argumentsJSON: args)]
            )
        })
        let orch2 = OrchestratorActor(
            projectID: p2.id,
            database: db,
            sharedStateStore: store,
            providerRegistry: .makeDefault(mockProvider: mock2),
            browserService: MissingScreenshotBrowserService()
        )
        let report2 = try await orch2.run(maxSteps: 6)
        #expect(report2.status == .completed)
    }

    @Test("NEW-BUG-3: HelmControlPlane.pauseProject preserves .held when open exceptions exist and simulateCondition serializes via activeRunTasks")
    func pauseProjectPreservesHeldAndSimulateConditionSerialized() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("T5_SimVsPause_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let slowMock = MockLLMProvider(scenario: .customHandler { req in
            if req.userPrompt.contains("DECOMPOSE_GOAL") {
                return LLMResponse(text: """
                {"tasks":[{"temp_id":"t1","title":"Slow","instructions":"Wait","assigned_agent_id":"","waiting_on_temp_ids":[]}]}
                """)
            }
            try await Task.sleep(for: .milliseconds(250))
            let args = "{\"summary\":\"Done\"}"
            return LLMResponse(
                text: "{\"tool_calls\":[{\"id\":\"c1\",\"name\":\"complete_task\",\"arguments\":\(args)}]}",
                toolCalls: [LLMToolCall(id: "c1", name: "complete_task", argumentsJSON: args)]
            )
        })

        let cp = await MainActor.run {
            HelmControlPlane(database: db, providerRegistry: .makeDefault(mockProvider: slowMock))
        }
        let project = try await cp.createProject(name: "SimPause", goal: "Preserve held", workspaceRoot: ws)
        _ = try await cp.addAgent(projectID: project.id, name: "Coder", role: .coder, goal: "Run", backend: .mock)

        try await cp.simulateCondition(projectID: project.id, kind: .drift)
        let openAfterSim = try await db.listExceptions(projectID: project.id, openOnly: true)
        #expect(openAfterSim.count == 1)
        let projAfterSim = try #require(try await db.fetchProject(id: project.id))
        #expect(projAfterSim.status == .held)

        // pauseProject must NOT overwrite .held -> .paused while open exceptions exist
        try await cp.pauseProject(projectID: project.id)
        let projAfterPause = try #require(try await db.fetchProject(id: project.id))
        let openAfterPause = try await db.listExceptions(projectID: project.id, openOnly: true)
        #expect(openAfterPause.count == 1)
        #expect(projAfterPause.status == .held)

        // Also test simulateCondition cancelling an active startProject and being tracked in activeRunTasks
        let p2 = try await cp.createProject(name: "SimRace", goal: "Serialize activeRunTasks", workspaceRoot: ws)
        _ = try await cp.addAgent(projectID: p2.id, name: "Worker", role: .coder, goal: "Run", backend: .mock)
        try await cp.startProject(projectID: p2.id)
        try await Task.sleep(for: .milliseconds(30))

        async let simCall: Void = cp.simulateCondition(projectID: p2.id, kind: .drift)
        try await Task.sleep(for: .milliseconds(10))
        try await cp.pauseProject(projectID: p2.id)
        try await simCall

        let p2Final = try #require(try await db.fetchProject(id: p2.id))
        let p2Open = try await db.listExceptions(projectID: p2.id, openOnly: true)
        if p2Open.isEmpty {
            #expect(p2Final.status == .paused)
        } else {
            #expect(p2Final.status == .held)
        }
    }
}
