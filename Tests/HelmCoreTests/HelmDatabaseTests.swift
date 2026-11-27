import Foundation
@testable import HelmCore
import Testing

@Suite("HelmDatabase WAL & Durability")
struct HelmDatabaseTests {
    private func makeTempDBPath() -> (dir: URL, dbPath: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelmDBTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("helm.sqlite").path)
    }

    @Test("WAL mode enabled and CRUD works across all core tables")
    func walModeAndCRUD() async throws {
        let (dir, dbPath) = makeTempDBPath()
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try HelmDatabase(path: dbPath)
        let mode = try await db.journalMode()
        #expect(mode.lowercased() == "wal")

        let ws = dir.appendingPathComponent("ws", isDirectory: true)
        let project = Project(name: "Harbor", goal: "Build & Verify", workspaceRoot: ws)
        try await db.insertProject(project)
        let fetchedProj = try await db.fetchProject(id: project.id)
        #expect(fetchedProj?.name == "Harbor")

        let agent = AgentProfile(
            projectID: project.id,
            name: "Builder",
            role: .coder,
            goal: "Write Swift",
            backend: .mock
        )
        try await db.insertAgent(agent)
        let agents = try await db.listAgents(projectID: project.id)
        #expect(agents.count == 1)
        #expect(agents[0].characterSeed == agent.characterSeed)

        let task = DelegatedTask(
            projectID: project.id,
            assignedAgentID: agent.id,
            title: "Compile",
            instructions: "Run swift build"
        )
        try await db.insertTask(task)
        #expect(try await db.fetchTask(id: task.id)?.title == "Compile")

        let artifact = ArtifactRecord(
            projectID: project.id,
            agentID: agent.id,
            taskID: task.id,
            kind: "log",
            relativePath: "build.log",
            mimeType: "text/plain",
            byteSize: 128,
            sha256: String(repeating: "a", count: 64)
        )
        try await db.insertArtifact(artifact)
        #expect(try await db.listArtifacts(projectID: project.id).count == 1)

        // Exception deduplication by dedupKey
        let alert1 = ExceptionAlert(
            projectID: project.id,
            kind: .stall,
            title: "Stall",
            summary: "First stall",
            dedupKey: "stall:same"
        )
        let alert2 = ExceptionAlert(
            projectID: project.id,
            kind: .stall,
            title: "Stall",
            summary: "Duplicate stall",
            dedupKey: "stall:same"
        )
        _ = try await db.upsertOpenException(alert1)
        _ = try await db.upsertOpenException(alert2)
        #expect(try await db.listExceptions(projectID: project.id, openOnly: true).count == 1)
    }

    @Test("Boot crash recovery reconciles orphaned running tasks and side-effect holds")
    func bootCrashRecovery() async throws {
        let (dir, dbPath) = makeTempDBPath()
        defer { try? FileManager.default.removeItem(at: dir) }

        let projID: UUID
        let idempotentTaskID: UUID
        let sideEffectTaskID: UUID

        do {
            let db = try HelmDatabase(path: dbPath)
            let project = Project(name: "CrashProj", goal: "Recover", workspaceRoot: dir, status: .running)
            projID = project.id
            try await db.insertProject(project)

            let agent = AgentProfile(projectID: projID, name: "Worker", role: .coder, goal: "Run", backend: .mock)
            try await db.insertAgent(agent)

            let t1 = DelegatedTask(
                projectID: projID,
                assignedAgentID: agent.id,
                title: "ReadOnlyStep",
                instructions: "Analyze",
                status: .running,
                hasExternalSideEffect: false
            )
            let t2 = DelegatedTask(
                projectID: projID,
                assignedAgentID: agent.id,
                title: "DeployStep",
                instructions: "Mutate external state",
                status: .running,
                hasExternalSideEffect: true
            )
            idempotentTaskID = t1.id
            sideEffectTaskID = t2.id
            try await db.insertTask(t1)
            try await db.insertTask(t2)
        }

        // Reopen fresh DB instance simulating restart
        let reopened = try HelmDatabase(path: dbPath)
        let reconciled = try await reopened.reconcileOrphanedRunsOnBoot()
        #expect(reconciled >= 2)

        let t1After = try await reopened.fetchTask(id: idempotentTaskID)
        let t2After = try await reopened.fetchTask(id: sideEffectTaskID)
        #expect(t1After?.status == .queued)
        #expect(t2After?.status == .outcomeUnknown)

        let projAfter = try await reopened.fetchProject(id: projID)
        #expect(projAfter?.status == .held)
        let exceptions = try await reopened.listExceptions(projectID: projID, openOnly: true)
        #expect(exceptions.count == 1)
        let events = try await reopened.listEvents(projectID: projID)
        #expect(events.contains(where: { $0.kind == .recoveryReconciled }))
    }

    @Test("Durable Held pause survives DB close and reopen")
    func durableHeldSurvivesRestart() async throws {
        let (dir, dbPath) = makeTempDBPath()
        defer { try? FileManager.default.removeItem(at: dir) }

        let projID: UUID
        let excID: UUID
        let taskID: UUID

        do {
            let db = try HelmDatabase(path: dbPath)
            let project = Project(name: "HoldProj", goal: "Gate", workspaceRoot: dir)
            projID = project.id
            try await db.insertProject(project)
            let agent = AgentProfile(projectID: projID, name: "A1", role: .researcher, goal: "Check", backend: .mock)
            try await db.insertAgent(agent)
            let task = DelegatedTask(projectID: projID, assignedAgentID: agent.id, title: "GateTask", instructions: "Wait")
            taskID = task.id
            try await db.insertTask(task)

            let gate = HumanDecisionGate(database: db)
            let alert = ExceptionAlert(
                projectID: projID,
                taskID: taskID,
                agentID: agent.id,
                kind: .humanDecision,
                title: "Confirm",
                summary: "Need approval",
                dedupKey: "gate:1"
            )
            excID = alert.id
            _ = try await gate.triggerHold(alert: alert)
        }

        let reopened = try HelmDatabase(path: dbPath)
        #expect(try await reopened.fetchProject(id: projID)?.status == .held)
        #expect(try await reopened.fetchTask(id: taskID)?.status == .needsHuman)
        let openExceptions = try await reopened.listExceptions(projectID: projID, openOnly: true)
        #expect(openExceptions.count == 1)
        #expect(openExceptions[0].id == excID)
    }
}
