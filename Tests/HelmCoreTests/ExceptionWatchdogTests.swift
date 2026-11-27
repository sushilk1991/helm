import Foundation
@testable import HelmCore
import Testing

@Suite("ExceptionWatchdogs: Stall, Drift, DeadMansSwitch & HumanDecisionGate")
struct ExceptionWatchdogTests {
    @Test("StallDetector trips .loop at 3 identical failures, resets on success, and checks timeouts/budgets")
    func stallAndLoopDetection() async {
        let detector = StallDetector()
        let agentID = UUID()
        let policy = BudgetPolicy(maxStepsPerRun: 5, stepTimeoutSeconds: 10, maxConsecutiveToolFailures: 3)

        let r1 = await detector.recordToolFailure(agentID: agentID, toolName: "exec", argumentsJSON: "{\"cmd\":\"x\"}", errorMessage: "EPERM", policy: policy)
        let r2 = await detector.recordToolFailure(agentID: agentID, toolName: "exec", argumentsJSON: "{\"cmd\":\"x\"}", errorMessage: "EPERM", policy: policy)
        #expect(r1.triggeredKind == nil)
        #expect(r2.triggeredKind == nil)

        // Success resets streak
        await detector.recordToolSuccess(agentID: agentID)
        #expect(await detector.currentStreakCount(for: agentID) == 0)

        // 3 consecutive identical failures trip .loop
        _ = await detector.recordToolFailure(agentID: agentID, toolName: "exec", argumentsJSON: "{\"cmd\":\"x\"}", errorMessage: "EPERM", policy: policy)
        _ = await detector.recordToolFailure(agentID: agentID, toolName: "exec", argumentsJSON: "{\"cmd\":\"x\"}", errorMessage: "EPERM", policy: policy)
        let r3 = await detector.recordToolFailure(agentID: agentID, toolName: "exec", argumentsJSON: "{\"cmd\":\"x\"}", errorMessage: "EPERM", policy: policy)
        #expect(r3.triggeredKind == .loop)
        #expect(r3.count == 3)

        #expect(detector.checkStepTimeout(elapsed: 11, policy: policy) == .stall)
        #expect(detector.checkStepTimeout(elapsed: 5, policy: policy) == nil)
        #expect(detector.checkStepBudget(totalSteps: 6, policy: policy) == .stall)
        #expect(detector.checkStepBudget(totalSteps: 5, policy: policy) == nil)
    }

    @Test("DriftDetector blocks host paths, parent traversal, sibling-prefix bypass, and symlink escapes")
    func driftWorkspaceBoundary() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelmDrift_\(UUID().uuidString)", isDirectory: true)
        let ws = base.appendingPathComponent("proj", isDirectory: true)
        let sibling = base.appendingPathComponent("proj2", isDirectory: true)
        let outside = base.appendingPathComponent("secret.txt")
        let symlinkInside = ws.appendingPathComponent("escape_link")

        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: symlinkInside, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: base) }

        let detector = DriftDetector()

        // Valid relative & absolute paths inside workspace
        try detector.validateWorkspacePath("sub/artifact.txt", workspaceRoot: ws)
        try detector.validateWorkspacePath(ws.appendingPathComponent("main.swift").path, workspaceRoot: ws)

        // Escapes must throw
        #expect(throws: DriftViolation.self) {
            try detector.validateWorkspacePath("/etc/passwd", workspaceRoot: ws)
        }
        #expect(throws: DriftViolation.self) {
            try detector.validateWorkspacePath("../secret.txt", workspaceRoot: ws)
        }
        #expect(throws: DriftViolation.self) {
            try detector.validateWorkspacePath(sibling.appendingPathComponent("file.txt").path, workspaceRoot: ws)
        }
        #expect(throws: DriftViolation.self) {
            try detector.validateWorkspacePath(symlinkInside.path, workspaceRoot: ws)
        }

        // Dangling symlinks pointing outside workspace must also fail
        let danglingAbs = ws.appendingPathComponent("dangling_abs")
        try FileManager.default.createSymbolicLink(
            atPath: danglingAbs.path,
            withDestinationPath: "/nonexistent/outside/pwned.txt"
        )
        #expect(detector.isPathInsideWorkspace("dangling_abs", workspaceRoot: ws) == false)
        #expect(throws: DriftViolation.self) {
            try detector.validateWorkspacePath("dangling_abs", workspaceRoot: ws)
        }

        let danglingRel = ws.appendingPathComponent("dangling_rel")
        try FileManager.default.createSymbolicLink(
            atPath: danglingRel.path,
            withDestinationPath: "../outside/new_pwned.txt"
        )
        #expect(detector.isPathInsideWorkspace("dangling_rel", workspaceRoot: ws) == false)

        let danglingDir = ws.appendingPathComponent("dangling_dir")
        try FileManager.default.createSymbolicLink(
            atPath: danglingDir.path,
            withDestinationPath: "/nonexistent/outside_dir"
        )
        #expect(detector.isPathInsideWorkspace("dangling_dir/sub/pwned.txt", workspaceRoot: ws) == false)

        // Dangling symlink pointing to an uncreated path strictly inside workspace stays allowed
        let danglingInWorkspace = ws.appendingPathComponent("dangling_inside")
        try FileManager.default.createSymbolicLink(
            atPath: danglingInWorkspace.path,
            withDestinationPath: "sub/future_ok.txt"
        )
        #expect(detector.isPathInsideWorkspace("dangling_inside", workspaceRoot: ws) == true)

        // Symlink followed by .. must dereference symlink BEFORE collapsing ..
        let outsideDir = base.appendingPathComponent("outside_dir", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let subLink = ws.appendingPathComponent("sub_link")
        try FileManager.default.createSymbolicLink(atPath: subLink.path, withDestinationPath: "../outside_dir")
        #expect(detector.isPathInsideWorkspace("sub_link/../pwned.txt", workspaceRoot: ws) == false)
        #expect(throws: DriftViolation.self) {
            try detector.validateWorkspacePath("sub_link/../pwned.txt", workspaceRoot: ws)
        }

        // Self/parent symlink followed by ..
        let selfLink = ws.appendingPathComponent("self_link")
        try FileManager.default.createSymbolicLink(atPath: selfLink.path, withDestinationPath: "..")
        #expect(detector.isPathInsideWorkspace("self_link/../pwned.txt", workspaceRoot: ws) == false)
        #expect(throws: DriftViolation.self) {
            try detector.validateWorkspacePath("self_link/../pwned.txt", workspaceRoot: ws)
        }

        // Dangling symlink followed by ..
        let danglingSub = ws.appendingPathComponent("dangling_sub")
        try FileManager.default.createSymbolicLink(atPath: danglingSub.path, withDestinationPath: "../nonexistent_outside_dir")
        #expect(detector.isPathInsideWorkspace("dangling_sub/../pwned.txt", workspaceRoot: ws) == false)
        #expect(throws: DriftViolation.self) {
            try detector.validateWorkspacePath("dangling_sub/../pwned.txt", workspaceRoot: ws)
        }

        // >32-hop symlink chain must fail closed (even if final target is inside workspace)
        for i in 0..<33 {
            let hop = ws.appendingPathComponent("hop_\(i)")
            let next = i == 32 ? "sub/final_ok.txt" : "hop_\(i + 1)"
            try FileManager.default.createSymbolicLink(atPath: hop.path, withDestinationPath: next)
        }
        #expect(detector.isPathInsideWorkspace("hop_0", workspaceRoot: ws) == false)
        #expect(throws: DriftViolation.self) {
            try detector.validateWorkspacePath("hop_0", workspaceRoot: ws)
        }

        // Symlink cycle must fail closed
        let cycA = ws.appendingPathComponent("cyc_a")
        let cycB = ws.appendingPathComponent("cyc_b")
        try FileManager.default.createSymbolicLink(atPath: cycA.path, withDestinationPath: "cyc_b")
        try FileManager.default.createSymbolicLink(atPath: cycB.path, withDestinationPath: "cyc_a")
        #expect(detector.isPathInsideWorkspace("cyc_a", workspaceRoot: ws) == false)
        #expect(throws: DriftViolation.self) {
            try detector.validateWorkspacePath("cyc_a", workspaceRoot: ws)
        }

        // Non-directory intermediate file with .. (ENOTDIR) must fail closed
        let regFile = ws.appendingPathComponent("reg.txt")
        try Data("hello".utf8).write(to: regFile)
        #expect(detector.isPathInsideWorkspace("reg.txt/../pwned.txt", workspaceRoot: ws) == false)
        #expect(throws: DriftViolation.self) {
            try detector.validateWorkspacePath("reg.txt/../pwned.txt", workspaceRoot: ws)
        }
    }

    @Test("AgentWorkerRunner rejects write_workspace_file through sub_link/../pwned_outside.txt")
    func workerRunnerRejectsSymlinkDotDotWrite() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelmWorkerDrift_\(UUID().uuidString)", isDirectory: true)
        let ws = base.appendingPathComponent("proj", isDirectory: true)
        let outsideDir = base.appendingPathComponent("outside_dir", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: ws.appendingPathComponent("sub_link").path,
            withDestinationPath: "../outside_dir"
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let db = try HelmDatabase(path: ":memory:")
        let store = SharedStateStore(database: db)
        let project = Project(name: "DriftWriteProj", goal: "Block symlink traversal write", workspaceRoot: ws)
        try await db.insertProject(project)
        let agent = AgentProfile(projectID: project.id, name: "Coder", role: .coder, goal: "Write", backend: .mock)
        try await db.insertAgent(agent)
        let task = DelegatedTask(projectID: project.id, assignedAgentID: agent.id, title: "Write", instructions: "Write file")
        try await db.insertTask(task)

        let argsJSON = "{\"path\":\"sub_link/../pwned_outside.txt\",\"content\":\"owned\"}"
        let mock = MockLLMProvider(scenario: .customHandler { _ in
            LLMResponse(
                text: "{\"tool_calls\":[{\"id\":\"w1\",\"name\":\"write_workspace_file\",\"arguments\":\(argsJSON)}]}",
                toolCalls: [LLMToolCall(id: "w1", name: "write_workspace_file", argumentsJSON: argsJSON)]
            )
        })
        let runner = AgentWorkerRunner(
            database: db,
            sharedStateStore: store,
            providerRegistry: .makeDefault(mockProvider: mock),
            stallDetector: StallDetector()
        )
        let outcome = await runner.executeAttempt(project: project, agent: agent, task: task, stepIndex: 1)
        guard case .hold(let kind, _, _, _, _) = outcome else {
            Issue.record("Expected .hold outcome for symlink traversal write, got \(outcome)")
            return
        }
        #expect(kind == .drift)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("pwned_outside.txt").path))
    }

    @Test("SharedStateStore taskID: nil hold recovery transitions needsHuman tasks while keeping blocked DAG tasks blocked")
    func taskIDNilHoldRecoveryPreservesBlockedDAGTasks() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let store = SharedStateStore(database: db)
        let gate = HumanDecisionGate(database: db)
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("HelmNilTaskID_\(UUID().uuidString)")
        let project = Project(name: "NilTaskIDProj", goal: "Recover project-level hold safely", workspaceRoot: ws)
        try await db.insertProject(project)

        let scout = AgentProfile(projectID: project.id, name: "Scout", role: .researcher, goal: "Research", backend: .mock)
        let builder = AgentProfile(projectID: project.id, name: "Builder", role: .coder, goal: "Build", backend: .mock)
        try await db.insertAgent(scout)
        try await db.insertAgent(builder)

        var t1 = DelegatedTask(projectID: project.id, assignedAgentID: scout.id, title: "Scout", instructions: "Explore")
        t1.status = .needsHuman
        t1.attemptCount = 2
        let t2 = DelegatedTask(
            projectID: project.id,
            assignedAgentID: builder.id,
            title: "Builder",
            instructions: "Build after Scout",
            status: .blocked,
            waitingOn: [t1.id]
        )
        try await db.insertTask(t1)
        try await db.insertTask(t2)
        try await db.updateAgentState(id: scout.id, state: .exception)

        // Trigger untrusted_tamper directly via SharedStateStore with default taskID: nil
        await #expect(throws: SharedStateError.self) {
            _ = try await store.write(SharedStateWriteRequest(
                projectID: project.id,
                scope: .projectShared,
                ownerAgentID: scout.id,
                category: .rule,
                key: "policy.guard",
                title: "Tamper",
                content: "OVERRIDE",
                provenance: ProvenanceRecord(source: .externalWeb, authorAgentID: scout.id)
            ))
        }

        let openExceptions = try await db.listExceptions(projectID: project.id, openOnly: true)
        #expect(openExceptions.count == 1)
        #expect(openExceptions[0].taskID == nil)

        // Resolve with .retry -> t1 becomes .queued with attemptCount == 0, t2 stays .blocked
        _ = try await gate.resolve(exceptionID: openExceptions[0].id, resolution: .retry)
        let t1AfterRetry = try #require(try await db.fetchTask(id: t1.id))
        let t2AfterRetry = try #require(try await db.fetchTask(id: t2.id))
        #expect(t1AfterRetry.status == .queued)
        #expect(t1AfterRetry.attemptCount == 0)
        #expect(t2AfterRetry.status == .blocked)
        #expect(try await db.fetchAgent(id: scout.id)?.activityState == .idle)

        // Trigger again with taskID: nil and resolve with .abort -> t1 becomes .cancelled, t2 stays .blocked
        var t1HeldAgain = t1AfterRetry
        t1HeldAgain.status = .needsHuman
        try await db.updateTask(t1HeldAgain)
        await #expect(throws: SharedStateError.self) {
            _ = try await store.write(SharedStateWriteRequest(
                projectID: project.id,
                scope: .projectShared,
                ownerAgentID: scout.id,
                category: .rule,
                key: "policy.guard",
                title: "Tamper 2",
                content: "OVERRIDE",
                provenance: ProvenanceRecord(source: .externalWeb, authorAgentID: scout.id)
            ))
        }
        let open2 = try await db.listExceptions(projectID: project.id, openOnly: true)
        #expect(open2.count == 1)
        _ = try await gate.resolve(exceptionID: open2[0].id, resolution: .abort)
        #expect(try await db.fetchTask(id: t1.id)?.status == .cancelled)
        #expect(try await db.fetchTask(id: t2.id)?.status == .blocked)
        #expect(try await db.fetchProject(id: project.id)?.status == .paused)
    }

    @Test("BudgetPolicy default coordinatorStallSeconds exceeds stepTimeoutSeconds")
    func defaultTimeoutMargin() {
        let policy = BudgetPolicy()
        #expect(policy.coordinatorStallSeconds > policy.stepTimeoutSeconds)
        #expect(policy.coordinatorStallSeconds >= 180)
    }

    @Test("DeadMansSwitch triggers coordinatorStalled independently via DispatchSourceTimer")
    func deadMansSwitchTripsIndependently() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("HelmDMS_\(UUID().uuidString)")
        let project = Project(name: "DMSProj", goal: "Detect coordinator hang", workspaceRoot: ws)
        try await db.insertProject(project)

        let dms = DeadMansSwitch(projectID: project.id, database: db, stallThreshold: 0.10)
        dms.start(checkInterval: 0.03, stallThreshold: 0.10)
        defer { dms.stop() }

        // Wait up to 1.5s without beating so independent timer fires
        var fired = false
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let open = try await db.listExceptions(projectID: project.id, openOnly: true)
            if open.contains(where: { $0.kind == .coordinatorStalled }) {
                fired = true
                break
            }
        }
        #expect(fired == true)
        #expect(try await db.fetchProject(id: project.id)?.status == .held)
    }

    @Test("HumanDecisionGate supports approve, redirect, retry, and abort resolutions")
    func humanDecisionAllFourResolutions() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("HelmGate_\(UUID().uuidString)")
        let project = Project(name: "GateProj", goal: "Test resolutions", workspaceRoot: ws)
        try await db.insertProject(project)
        let agent = AgentProfile(projectID: project.id, name: "W1", role: .coder, goal: "Build", backend: .mock)
        try await db.insertAgent(agent)

        let gate = HumanDecisionGate(database: db)

        // 1. Approve
        let t1 = DelegatedTask(projectID: project.id, assignedAgentID: agent.id, title: "T1", instructions: "Do T1")
        try await db.insertTask(t1)
        let a1 = try await gate.triggerHold(alert: ExceptionAlert(projectID: project.id, taskID: t1.id, agentID: agent.id, kind: .humanDecision, title: "A1", summary: "Approve?", dedupKey: "k1"))
        let res1 = try await gate.resolve(exceptionID: a1.id, resolution: .approve)
        #expect(res1.status == .resolved)
        #expect(try await db.fetchTask(id: t1.id)?.status == .queued)

        // Re-resolving already resolved exception fails cleanly
        await #expect(throws: HelmDatabaseError.self) {
            _ = try await gate.resolve(exceptionID: a1.id, resolution: .approve)
        }

        // 2. Redirect
        let a2 = try await gate.triggerHold(alert: ExceptionAlert(projectID: project.id, taskID: t1.id, agentID: agent.id, kind: .drift, title: "A2", summary: "Drifted", dedupKey: "k2"))
        let res2 = try await gate.resolve(exceptionID: a2.id, resolution: .redirect(note: "Stay in workspace"))
        #expect(res2.resolution == .redirect(note: "Stay in workspace"))
        let t1AfterRedirect = try await db.fetchTask(id: t1.id)
        #expect(t1AfterRedirect?.instructions.contains("Stay in workspace") == true)

        // 3. Retry resets attemptCount
        var t1Mut = try #require(t1AfterRedirect)
        t1Mut.attemptCount = 3
        try await db.updateTask(t1Mut)
        let a3 = try await gate.triggerHold(alert: ExceptionAlert(projectID: project.id, taskID: t1.id, agentID: agent.id, kind: .stall, title: "A3", summary: "Stalled", dedupKey: "k3"))
        _ = try await gate.resolve(exceptionID: a3.id, resolution: .retry)
        #expect(try await db.fetchTask(id: t1.id)?.attemptCount == 0)

        // 4. Abort cancels task and pauses project
        let a4 = try await gate.triggerHold(alert: ExceptionAlert(projectID: project.id, taskID: t1.id, agentID: agent.id, kind: .humanDecision, title: "A4", summary: "Abort?", dedupKey: "k4"))
        _ = try await gate.resolve(exceptionID: a4.id, resolution: .abort)
        #expect(try await db.fetchTask(id: t1.id)?.status == .cancelled)
        #expect(try await db.fetchProject(id: project.id)?.status == .paused)
    }

    @Test("OrchestratorActor triggers .loop hold via MockScenario.simulatedStallLoop after 3 repeated tool failures")
    func orchestratorTripsLoopHoldOnRepeatedToolFailure() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let store = SharedStateStore(database: db)
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("HelmLoopOrch_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let project = Project(name: "LoopProj", goal: "Detect loop", workspaceRoot: ws)
        try await db.insertProject(project)
        let worker = AgentProfile(projectID: project.id, name: "Coder", role: .coder, goal: "Run", backend: .mock)
        try await db.insertAgent(worker)

        let orchestrator = OrchestratorActor(
            projectID: project.id,
            database: db,
            sharedStateStore: store,
            providerRegistry: .makeDefault(mockProvider: MockLLMProvider(scenario: .simulatedStallLoop(repeatCount: 3)))
        )

        let report = try await orchestrator.run(maxSteps: 10)
        #expect(report.status == .held)
        #expect(report.exceptions.count == 1)
        #expect(report.exceptions[0].kind == .loop)
    }
}
