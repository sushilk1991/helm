import Foundation
@testable import HelmCore
import SQLite3
import Testing

@Suite("M1 Core Models, DB v3, Chat & Work Feed")
struct M1CorePersistenceTests {
    private func makeTempDir(prefix: String = "HelmM1Tests") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func execRawSQLite(_ db: OpaquePointer, sql: String) throws {
        var errPtr: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errPtr)
        if rc != SQLITE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let errPtr { sqlite3_free(errPtr) }
            throw HelmDatabaseError.execFailed(code: rc, message: msg)
        }
    }

    private func queryInt32(_ db: OpaquePointer, sql: String) throws -> Int32 {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw HelmDatabaseError.prepareFailed(code: rc, message: String(cString: sqlite3_errmsg(db)), sql: sql)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw HelmDatabaseError.stepFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_column_int(stmt, 0)
    }

    private func tableDefaultValues(_ db: OpaquePointer, table: String) throws -> [String: String?] {
        let sql = "PRAGMA table_info(\(table));"
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw HelmDatabaseError.prepareFailed(code: rc, message: String(cString: sqlite3_errmsg(db)), sql: sql)
        }
        defer { sqlite3_finalize(stmt) }
        var result: [String: String?] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(stmt, 1) {
                let name = String(cString: namePtr)
                let dflt: String? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                result[name] = dflt
            }
        }
        return result
    }

    @Test("DB v2->v3 migration upgrades on disk, backfills system_prompt, and sets ALTER TABLE SQL defaults")
    func migrationV2ToV3UpgradesExistingRowsAndSchema() async throws {
        let dir = makeTempDir(prefix: "HelmM1Mig")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("helm_v2.sqlite").path
        let ws = dir.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)

        let projectID = UUID()
        let coderID = UUID()
        let reviewerID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSince1970

        // Create an authentic v2 database on disk before opening with HelmDatabase
        do {
            var rawDB: OpaquePointer?
            let openRC = sqlite3_open_v2(
                dbPath,
                &rawDB,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard openRC == SQLITE_OK, let opened = rawDB else {
                Issue.record("Failed to open raw v2 SQLite DB")
                return
            }
            defer { sqlite3_close_v2(opened) }

            try execRawSQLite(opened, sql: HelmDatabaseSchema.migrationV1SQL)
            try execRawSQLite(opened, sql: HelmDatabaseSchema.migrationV2SQL)
            try execRawSQLite(opened, sql: "PRAGMA user_version = 2;")

            let budgetJSON = String(data: try HelmJSON.makeEncoder().encode(BudgetPolicy()), encoding: .utf8)!
            let coderSeedJSON = String(
                data: try HelmJSON.makeEncoder().encode(AgentCharacterSeed(agentID: coderID, isOrchestrator: false)),
                encoding: .utf8
            )!
            let reviewerSeedJSON = String(
                data: try HelmJSON.makeEncoder().encode(AgentCharacterSeed(agentID: reviewerID, isOrchestrator: false)),
                encoding: .utf8
            )!

            try execRawSQLite(opened, sql: """
                INSERT INTO projects (id, name, goal, workspace_root, status, budget_policy_json, created_at, updated_at)
                VALUES ('\(projectID.uuidString)', 'LegacyV2', 'Upgrade cleanly', '\(ws.absoluteString)', 'idle', '\(budgetJSON)', \(now), \(now));

                INSERT INTO agents (
                    id, project_id, name, role, goal, capabilities_json, backend_kind,
                    model_override, activity_state, character_seed_json, created_at, updated_at,
                    personality, personality_notes
                ) VALUES (
                    '\(coderID.uuidString)', '\(projectID.uuidString)', 'Forge', 'coder',
                    'Ship features', '["codeExec","readSharedState"]', 'mock',
                    NULL, 'idle', '\(coderSeedJSON)', \(now), \(now),
                    'pragmaticBuilder', 'Always run swift test'
                );

                INSERT INTO agents (
                    id, project_id, name, role, goal, capabilities_json, backend_kind,
                    model_override, activity_state, character_seed_json, created_at, updated_at,
                    personality, personality_notes
                ) VALUES (
                    '\(reviewerID.uuidString)', '\(projectID.uuidString)', 'Verifier', 'qa_verifier',
                    'Check regressions', '["codeExec","readSharedState"]', 'mock',
                    NULL, 'idle', '\(reviewerSeedJSON)', \(now), \(now),
                    'adversarialReviewer', ''
                );
                """)
        }

        // Reopen with HelmDatabase (triggers v2 -> v3 migration)
        let db = try HelmDatabase(path: dbPath)
        let migratedProject = try #require(try await db.fetchProject(id: projectID))
        #expect(migratedProject.sandboxTrustPolicy == .standardWorkspace)

        let agents = try await db.listAgents(projectID: projectID)
        #expect(agents.count == 2)

        let coder = try #require(agents.first(where: { $0.id == coderID }))
        let expectedCoderPrompt = AgentProfile.buildSystemPromptTemplate(
            role: .coder,
            personality: .pragmaticBuilder,
            goal: "Ship features",
            notes: "Always run swift test"
        )
        #expect(coder.systemPrompt == expectedCoderPrompt)
        #expect(coder.systemPrompt.contains("Always run swift test"))
        #expect(coder.capabilities == [.codeExec, .readSharedState])

        let verifier = try #require(agents.first(where: { $0.id == reviewerID }))
        let expectedVerifierPrompt = AgentProfile.buildSystemPromptTemplate(
            role: .qaVerifier,
            personality: .adversarialReviewer,
            goal: "Check regressions",
            notes: ""
        )
        #expect(verifier.systemPrompt == expectedVerifierPrompt)

        // Verify schema user_version == 4 and ALTER TABLE columns have explicit SQL DEFAULTs (T5-ADV-04)
        var verifyDB: OpaquePointer?
        sqlite3_open_v2(dbPath, &verifyDB, SQLITE_OPEN_READONLY, nil)
        defer { if let verifyDB { sqlite3_close_v2(verifyDB) } }
        let rawVerify = try #require(verifyDB)
        #expect(try queryInt32(rawVerify, sql: "PRAGMA user_version;") == HelmDatabaseSchema.currentVersion)
        #expect(HelmDatabaseSchema.currentVersion == 4)

        let projectDefaults = try tableDefaultValues(rawVerify, table: "projects")
        let trustDefault = try #require(projectDefaults["sandbox_trust_policy"] ?? nil)
        #expect(trustDefault.contains("standardWorkspace"))

        let agentDefaults = try tableDefaultValues(rawVerify, table: "agents")
        #expect(agentDefaults["system_prompt"] != nil)
        #expect((agentDefaults["system_prompt"] ?? nil) != nil)

        let taskDefaults = try tableDefaultValues(rawVerify, table: "tasks")
        let taskKindDefault = try #require(taskDefaults["task_kind"] ?? nil)
        #expect(taskKindDefault.contains("goal"))

        // New v3 tables work on migrated DB
        let fixedMsgDate = Date(timeIntervalSince1970: 1_700_000_100)
        let msg = ChatMessage(
            projectID: projectID,
            channelKind: .crew,
            senderKind: .user,
            senderName: "You",
            content: "Check migrated project",
            createdAt: fixedMsgDate
        )
        try await db.insertChatMessage(msg)
        let messages = try await db.listChatMessages(projectID: projectID, channel: .crew)
        #expect(messages == [msg])

        let work = AgentWorkEntry(
            projectID: projectID,
            agentID: coderID,
            agentName: "Forge",
            stepNumber: 1,
            phase: .planning,
            summary: "Inspecting workspace",
            createdAt: fixedMsgDate
        )
        try await db.insertAgentWorkEntry(work)
        let feed = try await db.listAgentWorkEntries(projectID: projectID)
        #expect(feed == [work])
    }

    @Test("SandboxTrustPolicy defaults, Codable fallback, and HelmControlPlane.updateProjectTrustPolicy persist")
    @MainActor
    func projectSandboxTrustPolicyCRUDAndControlPlane() async throws {
        let dir = makeTempDir(prefix: "HelmM1Trust")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("trust.sqlite").path
        let ws = dir.appendingPathComponent("ws", isDirectory: true)

        let cp = try HelmControlPlane(databasePath: dbPath)
        let project = try await cp.createProject(name: "TrustProj", goal: "Test policy", workspaceRoot: ws)
        #expect(project.sandboxTrustPolicy == .standardWorkspace)

        let sandboxed = try await cp.updateProjectTrustPolicy(projectID: project.id, policy: .sandboxed)
        #expect(sandboxed.sandboxTrustPolicy == .sandboxed)
        #expect(cp.projects.first(where: { $0.id == project.id })?.sandboxTrustPolicy == .sandboxed)

        let trusted = try await cp.updateProjectTrustPolicy(projectID: project.id, policy: .trustedFullAccess)
        #expect(trusted.sandboxTrustPolicy == .trustedFullAccess)

        await #expect(throws: ControlPlaneError.projectNotFound(UUID(uuidString: "00000000-0000-4000-8000-000000000099")!)) {
            try await cp.updateProjectTrustPolicy(
                projectID: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!,
                policy: .sandboxed
            )
        }

        // Verify persistence after reopening DB
        let reopenedCP = try HelmControlPlane(databasePath: dbPath)
        try await reopenedCP.reloadFromStore()
        let reloaded = try #require(reopenedCP.projects.first(where: { $0.id == project.id }))
        #expect(reloaded.sandboxTrustPolicy == .trustedFullAccess)

        // Verify legacy Project JSON without sandboxTrustPolicy decodes cleanly
        let encoder = HelmJSON.makeEncoder()
        let rawData = try encoder.encode(reloaded)
        var obj = try #require(try JSONSerialization.jsonObject(with: rawData) as? [String: Any])
        obj.removeValue(forKey: "sandboxTrustPolicy")
        let legacyData = try JSONSerialization.data(withJSONObject: obj)
        let decodedLegacy = try HelmJSON.makeDecoder().decode(Project.self, from: legacyData)
        #expect(decodedLegacy.sandboxTrustPolicy == .standardWorkspace)
    }

    @Test("AgentProfile.RolePreset, systemPrompt editing, preservation, and backward-compatible capabilities Codable (T1-F2-05)")
    @MainActor
    func agentSystemPromptRolePresetsAndUpdatePreservation() async throws {
        // Cover all 6 AgentRole cases without .requestHumanDecision
        #expect(AgentProfile.RolePreset.allPresets.count == AgentRole.allCases.count)
        #expect(AgentRoleTemplate.allPresets == AgentProfile.RolePreset.allPresets)
        for role in AgentRole.allCases {
            let preset = AgentProfile.RolePreset.preset(for: role)
            #expect(preset.role == role)
            #expect(!preset.name.isEmpty)
            #expect(!preset.goal.isEmpty)
            #expect(!preset.capabilities.contains(.requestHumanDecision))
            let templated = preset.buildSystemPrompt(notes: "Verify outputs.")
            #expect(templated.contains(role.rawValue))
            #expect(templated.contains(preset.goal))
            #expect(templated.contains("Verify outputs."))
        }

        // Backward-compatible capabilities JSON Codable check (T1-F2-05)
        let legacyAgentJSON = """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "projectID": "22222222-2222-4222-8222-222222222222",
          "name": "LegacyCoder",
          "role": "coder",
          "goal": "Fix bugs",
          "capabilities": ["codeExec", "readSharedState"],
          "backend": "mock",
          "activityState": "idle",
          "createdAt": 1700000000,
          "updatedAt": 1700000000
        }
        """
        let decodedLegacyAgent = try JSONDecoder().decode(AgentProfile.self, from: Data(legacyAgentJSON.utf8))
        #expect(decodedLegacyAgent.capabilities == [.codeExec, .readSharedState])
        #expect(decodedLegacyAgent.systemPrompt.contains("Fix bugs"))

        let reencoded = try JSONEncoder().encode(decodedLegacyAgent)
        let reencodedObj = try #require(try JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        let capsArray = try #require(reencodedObj["capabilities"] as? [String])
        #expect(Set(capsArray) == ["codeExec", "readSharedState"])

        // ControlPlane addAgent + updateAgent systemPrompt persistence & preservation
        let dir = makeTempDir(prefix: "HelmM1Agent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("agents.sqlite").path
        let ws = dir.appendingPathComponent("ws", isDirectory: true)

        let cp = try HelmControlPlane(databasePath: dbPath)
        let project = try await cp.createProject(name: "PromptProj", goal: "Test prompts", workspaceRoot: ws)

        let defaultAgent = try await cp.addAgent(
            projectID: project.id,
            name: "AutoPrompt",
            role: .researcher,
            goal: "Analyze files",
            backend: .mock
        )
        #expect(defaultAgent.systemPrompt.contains("Analyze files"))
        #expect(defaultAgent.systemPrompt.contains(AgentPersonality.methodicalArchitect.promptDirective))

        let customInitial = "You are a focused systems engineer. Always cite exact file paths."
        let customAgent = try await cp.addAgent(
            projectID: project.id,
            name: "CustomPrompt",
            role: .coder,
            goal: "Build modules",
            backend: .mock,
            systemPrompt: customInitial
        )
        #expect(customAgent.systemPrompt == customInitial)

        // Updating backend/goal/personality with systemPrompt: nil preserves existing custom systemPrompt
        let afterBackendChange = try await cp.updateAgent(
            agentID: customAgent.id,
            goal: "Build and test modules",
            backend: .piCLI,
            personality: .adversarialReviewer,
            personalityNotes: "Check edge cases"
        )
        #expect(afterBackendChange.systemPrompt == customInitial)
        #expect(afterBackendChange.backend == .piCLI)

        // Explicit whitespace-only systemPrompt fails validation
        await #expect(throws: ControlPlaneError.invalidInput("Agent system prompt cannot be empty.")) {
            try await cp.updateAgent(agentID: customAgent.id, systemPrompt: "   \n  ")
        }

        // Explicit non-empty systemPrompt updates and survives DB reopen
        let updatedPrompt = "Custom v2: write minimal patches and verify every test."
        let afterPromptEdit = try await cp.updateAgent(agentID: customAgent.id, systemPrompt: updatedPrompt)
        #expect(afterPromptEdit.systemPrompt == updatedPrompt)

        let reopenedCP = try HelmControlPlane(databasePath: dbPath)
        try await reopenedCP.reloadFromStore()
        let persisted = try #require(reopenedCP.agentsByProject[project.id]?.first(where: { $0.id == customAgent.id }))
        #expect(persisted.systemPrompt == updatedPrompt)
    }

    @Test("ChatMessage 1-on-1 & crew CRUD, channel isolation, validation, and ChatDispatchHook")
    @MainActor
    func chatMessagesCrewAndDirectCRUDAndDispatchHook() async throws {
        let dir = makeTempDir(prefix: "HelmM1Chat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("chat.sqlite").path
        let ws = dir.appendingPathComponent("ws", isDirectory: true)

        let agentAID = UUID()
        let parsedDirect = ChatChannelKind(channelKey: "agent:\(agentAID.uuidString)")
        #expect(parsedDirect == .direct(agentID: agentAID))
        #expect(ChatChannelKind(channelKey: "crew") == .crew)
        #expect(ChatChannelKind(channelKey: "invalid") == nil)

        let cp = try HelmControlPlane(databasePath: dbPath)
        let project = try await cp.createProject(name: "ChatProj", goal: "Collaborate", workspaceRoot: ws)
        let agentA = try await cp.addAgent(projectID: project.id, name: "Scout", role: .researcher, goal: "Research", backend: .mock)
        let agentB = try await cp.addAgent(projectID: project.id, name: "Forge", role: .coder, goal: "Code", backend: .mock)

        let crewMsg = try await cp.sendChatMessage(
            projectID: project.id,
            channel: .crew,
            content: "Crew: inspect README.md",
            referencedFiles: ["README.md"]
        )
        #expect(crewMsg.senderKind == .user)
        #expect(crewMsg.senderName == "You")
        #expect(crewMsg.referencedFiles == ["README.md"])

        let task = DelegatedTask(
            projectID: project.id,
            assignedAgentID: agentA.id,
            title: "Inspect README",
            instructions: "Summarize README"
        )
        try await cp.database.insertTask(task)

        let directAMsg = try await cp.sendChatMessage(
            projectID: project.id,
            channel: .direct(agentID: agentA.id),
            content: "Scout: check Package.swift",
            referencedFiles: ["Package.swift"],
            relatedTaskID: task.id
        )
        let directBMsg = try await cp.sendChatMessage(
            projectID: project.id,
            channel: .direct(agentID: agentB.id),
            content: "Forge: build project"
        )

        let crewListed = try await cp.listChatMessages(projectID: project.id, channel: .crew)
        #expect(crewListed.map(\.id) == [crewMsg.id])
        #expect(crewListed.first?.referencedFiles == ["README.md"])

        let directAListed = try await cp.listChatMessages(projectID: project.id, channel: .direct(agentID: agentA.id))
        #expect(directAListed.map(\.id) == [directAMsg.id])
        #expect(directAListed.first?.relatedTaskID == task.id)
        #expect(directAListed.first?.referencedFiles == ["Package.swift"])

        let directBListed = try await cp.listChatMessages(projectID: project.id, channel: .direct(agentID: agentB.id))
        #expect(directBListed.map(\.id) == [directBMsg.id])
        #expect(directBListed.first?.content == "Forge: build project")
        #expect(cp.chatMessagesByProject[project.id]?.count == 3)

        // Deterministic chronological ordering on equal timestamps with limit
        let fixedTime = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970) + 10)
        var tiedIDs: [UUID] = []
        for idx in 1...5 {
            let m = ChatMessage(
                projectID: project.id,
                channelKind: .crew,
                senderKind: .agent,
                senderAgentID: agentA.id,
                senderName: agentA.name,
                content: "Tied_\(idx)",
                createdAt: fixedTime
            )
            tiedIDs.append(m.id)
            try await cp.appendChatMessage(m)
        }
        let latest3Tied = try await cp.listChatMessages(projectID: project.id, channel: .crew, limit: 3)
        #expect(latest3Tied.map(\.content) == ["Tied_3", "Tied_4", "Tied_5"])
        #expect(latest3Tied.map(\.id) == Array(tiedIDs.suffix(3)))

        // Validation errors
        await #expect(throws: ControlPlaneError.invalidInput("Chat message content cannot be empty.")) {
            try await cp.sendChatMessage(projectID: project.id, channel: .crew, content: "   ")
        }
        let foreignAgentID = UUID()
        await #expect(throws: ControlPlaneError.invalidInput("Target agent '\(foreignAgentID.uuidString)' does not belong to project.")) {
            try await cp.sendChatMessage(projectID: project.id, channel: .direct(agentID: foreignAgentID), content: "Hello")
        }

        // ChatDispatchHook returns agent reply and persists without duplicating
        cp.chatDispatchHook = { proj, incoming, _ in
            [
                ChatMessage(
                    projectID: proj.id,
                    channelKind: incoming.channelKind,
                    senderKind: .agent,
                    senderAgentID: agentB.id,
                    senderName: agentB.name,
                    content: "Reply to: \(incoming.content)"
                )
            ]
        }
        let trigger = try await cp.sendChatMessage(
            projectID: project.id,
            channel: .direct(agentID: agentB.id),
            content: "Run swift test"
        )
        let directBAll = try await cp.listChatMessages(projectID: project.id, channel: .direct(agentID: agentB.id))
        #expect(directBAll.count == 3)
        #expect(directBAll[1].id == trigger.id)
        #expect(directBAll[2].content == "Reply to: Run swift test")
        #expect(directBAll[2].senderAgentID == agentB.id)

        // Reload from disk preserves chatMessagesByProject
        let reopenedCP = try HelmControlPlane(databasePath: dbPath)
        try await reopenedCP.reloadFromStore()
        #expect(reopenedCP.chatMessagesByProject[project.id]?.contains(where: { $0.id == directAMsg.id }) == true)
        #expect(reopenedCP.chatMessagesByProject[project.id]?.contains(where: { $0.content == "Reply to: Run swift test" }) == true)
    }

    @Test("AgentWorkEntry CRUD/filtering and >200 chronological listEvents via DB & ControlPlane")
    @MainActor
    func agentWorkFeedQueriesAndOver200ListEvents() async throws {
        let dir = makeTempDir(prefix: "HelmM1WorkFeed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("workfeed.sqlite").path
        let ws = dir.appendingPathComponent("ws", isDirectory: true)

        let cp = try HelmControlPlane(databasePath: dbPath)
        let project = try await cp.createProject(name: "FeedProj", goal: "Track work", workspaceRoot: ws)
        let agentA = try await cp.addAgent(projectID: project.id, name: "Scout", role: .researcher, goal: "Research", backend: .mock)
        let agentB = try await cp.addAgent(projectID: project.id, name: "Forge", role: .coder, goal: "Code", backend: .mock)

        let phases: [AgentWorkPhase] = [.planning, .reasoning, .toolCall, .fileEdit, .completed, .failed]
        let baseTime = Date(timeIntervalSince1970: 1_700_002_000)
        for (idx, phase) in phases.enumerated() {
            let target = (idx % 2 == 0) ? agentA : agentB
            let entry = AgentWorkEntry(
                projectID: project.id,
                agentID: target.id,
                agentName: target.name,
                stepNumber: idx + 1,
                phase: phase,
                summary: "Step \(idx + 1): \(phase.rawValue)",
                toolName: phase == .toolCall ? "read_workspace_file" : nil,
                toolInputSummary: phase == .toolCall ? "README.md" : nil,
                toolOutputSummary: phase == .toolCall ? "24 lines" : nil,
                touchedFiles: phase == .fileEdit ? ["Sources/App.swift"] : [],
                artifactPaths: phase == .completed ? [".helm/report.md"] : [],
                createdAt: baseTime
            )
            try await cp.recordAgentWorkEntry(entry)
        }

        let allFeed = try await cp.listAgentWorkFeed(projectID: project.id)
        #expect(allFeed.count == 6)
        #expect(allFeed.map(\.stepNumber) == [1, 2, 3, 4, 5, 6])
        #expect(cp.workFeedByProject[project.id]?.count == 6)

        let agentAFeed = try await cp.listAgentWorkFeed(projectID: project.id, agentID: agentA.id)
        #expect(agentAFeed.count == 3)
        #expect(agentAFeed.allSatisfy { $0.agentID == agentA.id })

        let latest2 = try await cp.listAgentWorkFeed(projectID: project.id, limit: 2)
        #expect(latest2.map(\.stepNumber) == [5, 6])

        // Reopen from disk
        let reopenedCP = try HelmControlPlane(databasePath: dbPath)
        try await reopenedCP.reloadFromStore()
        #expect(reopenedCP.workFeedByProject[project.id]?.count == 6)

        // >200 chronological RunEvent ordering via both database and controlPlane
        let evtProject = try await cp.createProject(name: "EventsProj", goal: "250 events", workspaceRoot: ws)
        for idx in 1...250 {
            try await cp.database.appendEvent(RunEvent(
                projectID: evtProject.id,
                kind: .heartbeatSteadyOK,
                summary: "EVT_\(idx)",
                trustLevel: .orchestratorVerified
            ))
        }

        // createProject added 1 event + 250 = 251 total
        let cpDefault = try await cp.listEvents(projectID: evtProject.id)
        #expect(cpDefault.count == 251)
        #expect(cpDefault.first?.kind == .projectCreated)
        #expect(cpDefault.last?.summary == "EVT_250")

        let dbDefault = try await cp.database.listEvents(projectID: evtProject.id)
        #expect(dbDefault.count == 251)
        #expect(dbDefault.last?.summary == "EVT_250")

        let latest200 = try await cp.listEvents(projectID: evtProject.id, limit: 200)
        #expect(latest200.count == 200)
        #expect(latest200.first?.summary == "EVT_51")
        #expect(latest200.last?.summary == "EVT_250")
    }

    @Test("SharedStateStore.preparePromptChannels forceFullContext returns raw slices for unchanged digests")
    func sharedStateStoreForceFullContext() async throws {
        let db = try HelmDatabase(path: ":memory:")
        let store = SharedStateStore(database: db)
        let dir = makeTempDir(prefix: "HelmM1Memory")
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = Project(name: "MemProj", goal: "Stateless context", workspaceRoot: dir)
        try await db.insertProject(project)
        let agent = AgentProfile(projectID: project.id, name: "Scout", role: .researcher, goal: "Read", backend: .mock)
        try await db.insertAgent(agent)

        let channels: [PromptChannel: String] = [
            .identity: "Scout identity",
            .projectContext: "Workspace root + files",
            .sharedMemory: "Pinned rules",
            .continuity: "Turn 1 context",
        ]

        let turn1 = try await store.preparePromptChannels(
            projectID: project.id,
            agentID: agent.id,
            rawChannels: channels
        )
        #expect(turn1.allSatisfy { $0.wasChanged && $0.content != nil })

        let turn2Default = try await store.preparePromptChannels(
            projectID: project.id,
            agentID: agent.id,
            rawChannels: channels
        )
        #expect(turn2Default.allSatisfy { !$0.wasChanged && !$0.supersedesPrevious && $0.content == nil })

        let turn3Forced = try await store.preparePromptChannels(
            projectID: project.id,
            agentID: agent.id,
            rawChannels: channels,
            forceFullContext: true
        )
        #expect(turn3Forced.count == 4)
        for slice in turn3Forced {
            #expect(slice.wasChanged == false)
            #expect(slice.supersedesPrevious == false)
            #expect(slice.content == channels[slice.channel])
        }
    }

    @Test("LLMRequest.workingDirectory defaults to nil and preserves explicit workspace URL")
    func llmRequestWorkingDirectory() {
        let agentID = UUID()
        let projectID = UUID()
        let defaultReq = LLMRequest(
            agentID: agentID,
            projectID: projectID,
            stepIndex: 1,
            systemPrompt: "Sys",
            userPrompt: "Hello"
        )
        #expect(defaultReq.workingDirectory == nil)

        let wsURL = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        let scopedReq = LLMRequest(
            agentID: agentID,
            projectID: projectID,
            stepIndex: 1,
            systemPrompt: "Sys",
            userPrompt: "Hello",
            workingDirectory: wsURL
        )
        #expect(scopedReq.workingDirectory == wsURL)
        #expect(defaultReq != scopedReq)
    }

    @Test("Cross-project and non-existent taskID/relatedTaskID and work entry invariants are enforced")
    @MainActor
    func projectScopedTaskValidationAndWorkEntryInvariants() async throws {
        let dir = makeTempDir(prefix: "HelmM1Validation")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("validation.sqlite").path
        let wsA = dir.appendingPathComponent("wsA", isDirectory: true)
        let wsB = dir.appendingPathComponent("wsB", isDirectory: true)

        let cp = try HelmControlPlane(databasePath: dbPath)
        let projectA = try await cp.createProject(name: "ProjA", goal: "Scope A", workspaceRoot: wsA)
        let projectB = try await cp.createProject(name: "ProjB", goal: "Scope B", workspaceRoot: wsB)

        let agentA = try await cp.addAgent(projectID: projectA.id, name: "ScoutA", role: .researcher, goal: "Read A", backend: .mock)
        let agentB = try await cp.addAgent(projectID: projectB.id, name: "ScoutB", role: .researcher, goal: "Read B", backend: .mock)

        let taskB = DelegatedTask(
            projectID: projectB.id,
            assignedAgentID: agentB.id,
            title: "Task in B",
            instructions: "Work in B"
        )
        try await cp.database.insertTask(taskB)
        let missingTaskID = UUID()

        // sendChatMessage rejects cross-project and non-existent relatedTaskID
        await #expect(throws: ControlPlaneError.invalidInput("Related task '\(taskB.id.uuidString)' does not belong to project.")) {
            try await cp.sendChatMessage(
                projectID: projectA.id,
                channel: .crew,
                content: "Cross-project task ref",
                relatedTaskID: taskB.id
            )
        }
        await #expect(throws: ControlPlaneError.invalidInput("Related task '\(missingTaskID.uuidString)' does not belong to project.")) {
            try await cp.sendChatMessage(
                projectID: projectA.id,
                channel: .crew,
                content: "Missing task ref",
                relatedTaskID: missingTaskID
            )
        }

        // appendChatMessage rejects cross-project and non-existent relatedTaskID
        let badAppendCross = ChatMessage(
            projectID: projectA.id,
            channelKind: .crew,
            senderKind: .agent,
            senderAgentID: agentA.id,
            senderName: agentA.name,
            content: "Cross task via append",
            relatedTaskID: taskB.id
        )
        await #expect(throws: ControlPlaneError.invalidInput("Related task '\(taskB.id.uuidString)' does not belong to project.")) {
            try await cp.appendChatMessage(badAppendCross)
        }

        let badAppendMissing = ChatMessage(
            projectID: projectA.id,
            channelKind: .crew,
            senderKind: .agent,
            senderAgentID: agentA.id,
            senderName: agentA.name,
            content: "Missing task via append",
            relatedTaskID: missingTaskID
        )
        await #expect(throws: ControlPlaneError.invalidInput("Related task '\(missingTaskID.uuidString)' does not belong to project.")) {
            try await cp.appendChatMessage(badAppendMissing)
        }
        #expect(try await cp.listChatMessages(projectID: projectA.id).isEmpty)

        // recordAgentWorkEntry rejects cross-project taskID, non-existent taskID, whitespace summary, and negative stepNumber
        let crossWork = AgentWorkEntry(
            projectID: projectA.id,
            agentID: agentA.id,
            agentName: agentA.name,
            taskID: taskB.id,
            stepNumber: 1,
            phase: .planning,
            summary: "Valid summary"
        )
        await #expect(throws: ControlPlaneError.invalidInput("Task '\(taskB.id.uuidString)' does not belong to project.")) {
            try await cp.recordAgentWorkEntry(crossWork)
        }

        let missingTaskWork = AgentWorkEntry(
            projectID: projectA.id,
            agentID: agentA.id,
            agentName: agentA.name,
            taskID: missingTaskID,
            stepNumber: 1,
            phase: .planning,
            summary: "Valid summary"
        )
        await #expect(throws: ControlPlaneError.invalidInput("Task '\(missingTaskID.uuidString)' does not belong to project.")) {
            try await cp.recordAgentWorkEntry(missingTaskWork)
        }

        let emptySummaryWork = AgentWorkEntry(
            projectID: projectA.id,
            agentID: agentA.id,
            agentName: agentA.name,
            stepNumber: 0,
            phase: .reasoning,
            summary: "   \n\t  "
        )
        await #expect(throws: ControlPlaneError.invalidInput("Agent work entry summary cannot be empty.")) {
            try await cp.recordAgentWorkEntry(emptySummaryWork)
        }

        let negativeStepWork = AgentWorkEntry(
            projectID: projectA.id,
            agentID: agentA.id,
            agentName: agentA.name,
            stepNumber: -1,
            phase: .toolCall,
            summary: "Negative step"
        )
        await #expect(throws: ControlPlaneError.invalidInput("Agent work entry step number cannot be negative.")) {
            try await cp.recordAgentWorkEntry(negativeStepWork)
        }

        #expect(try await cp.listAgentWorkFeed(projectID: projectA.id).isEmpty)

        // Valid stepNumber == 0 and valid project task succeed
        let taskA = DelegatedTask(
            projectID: projectA.id,
            assignedAgentID: agentA.id,
            title: "Task in A",
            instructions: "Work in A"
        )
        try await cp.database.insertTask(taskA)
        let validWork = AgentWorkEntry(
            projectID: projectA.id,
            agentID: agentA.id,
            agentName: agentA.name,
            taskID: taskA.id,
            stepNumber: 0,
            phase: .planning,
            summary: "Initial plan",
            createdAt: Date(timeIntervalSince1970: 1_700_005_000)
        )
        try await cp.recordAgentWorkEntry(validWork)
        #expect(try await cp.listAgentWorkFeed(projectID: projectA.id) == [validWork])
    }

    @Test("chatDispatchHook deduplicates beyond 1,000 messages and validates replies")
    @MainActor
    func chatDispatchHookUnboundedDedupAndReplyValidation() async throws {
        let dir = makeTempDir(prefix: "HelmM1Hook")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("hook.sqlite").path
        let wsA = dir.appendingPathComponent("wsA", isDirectory: true)
        let wsB = dir.appendingPathComponent("wsB", isDirectory: true)

        let cp = try HelmControlPlane(databasePath: dbPath)
        let projectA = try await cp.createProject(name: "HookProjA", goal: "Hook A", workspaceRoot: wsA)
        let projectB = try await cp.createProject(name: "HookProjB", goal: "Hook B", workspaceRoot: wsB)
        let agentA = try await cp.addAgent(projectID: projectA.id, name: "CoderA", role: .coder, goal: "Code A", backend: .mock)
        let agentB = try await cp.addAgent(projectID: projectB.id, name: "CoderB", role: .coder, goal: "Code B", backend: .mock)
        let taskB = DelegatedTask(
            projectID: projectB.id,
            assignedAgentID: agentB.id,
            title: "Foreign task",
            instructions: "Foreign"
        )
        try await cp.database.insertTask(taskB)

        // Seed 1,050 messages so the earliest message falls outside the latest 1,000 rows
        let baseDate = Date(timeIntervalSince1970: 1_700_010_000)
        var earliestMessage: ChatMessage?
        for idx in 0..<1_050 {
            let msg = ChatMessage(
                projectID: projectA.id,
                channelKind: .crew,
                senderKind: .agent,
                senderAgentID: agentA.id,
                senderName: agentA.name,
                content: "Seed_\(idx)",
                createdAt: baseDate.addingTimeInterval(Double(idx))
            )
            try await cp.database.insertChatMessage(msg)
            if idx == 0 { earliestMessage = msg }
        }
        let olderPersistedReply = try #require(earliestMessage)

        // Hook persists a new reply itself AND returns both the >1,000-old persisted message and the newly persisted reply,
        // plus an unpersisted valid reply (also verifies point-lookup via fetchChatMessage).
        #expect(try await cp.database.fetchChatMessage(id: olderPersistedReply.id) == olderPersistedReply)
        let newPersistedInsideHook = ChatMessage(
            projectID: projectA.id,
            channelKind: .crew,
            senderKind: .agent,
            senderAgentID: agentA.id,
            senderName: agentA.name,
            content: "Already persisted inside hook",
            createdAt: baseDate.addingTimeInterval(2_000)
        )
        let unpersistedValidReply = ChatMessage(
            projectID: projectA.id,
            channelKind: .crew,
            senderKind: .agent,
            senderAgentID: agentA.id,
            senderName: agentA.name,
            content: "Unpersisted valid reply",
            createdAt: baseDate.addingTimeInterval(2_001)
        )

        cp.chatDispatchHook = { _, _, controlPlane in
            try await controlPlane.appendChatMessage(newPersistedInsideHook)
            return [olderPersistedReply, newPersistedInsideHook, unpersistedValidReply]
        }

        _ = try await cp.sendChatMessage(
            projectID: projectA.id,
            channel: .crew,
            content: "Trigger dedup beyond 1000"
        )

        #expect(try await cp.database.fetchChatMessage(id: newPersistedInsideHook.id) == newPersistedInsideHook)
        #expect(try await cp.database.fetchChatMessage(id: unpersistedValidReply.id) == unpersistedValidReply)
        #expect(cp.chatMessagesByProject[projectA.id]?.contains(where: { $0.id == unpersistedValidReply.id }) == true)
        #expect(cp.chatMessagesByProject[projectA.id]?.contains(where: { $0.id == newPersistedInsideHook.id }) == true)

        // Reject reply targeting another project
        cp.chatDispatchHook = { _, _, _ in
            [
                ChatMessage(
                    projectID: projectB.id,
                    channelKind: .crew,
                    senderKind: .agent,
                    senderAgentID: agentB.id,
                    senderName: agentB.name,
                    content: "Cross-project injection"
                )
            ]
        }
        await #expect(throws: ControlPlaneError.invalidInput(
            "Chat reply project '\(projectB.id.uuidString)' does not match project '\(projectA.id.uuidString)'."
        )) {
            try await cp.sendChatMessage(projectID: projectA.id, channel: .crew, content: "Reject cross-project hook")
        }
        #expect(try await cp.listChatMessages(projectID: projectB.id).isEmpty)

        // Reject reply with empty/whitespace content
        cp.chatDispatchHook = { proj, _, _ in
            [
                ChatMessage(
                    projectID: proj.id,
                    channelKind: .crew,
                    senderKind: .agent,
                    senderAgentID: agentA.id,
                    senderName: agentA.name,
                    content: "   \n  "
                )
            ]
        }
        await #expect(throws: ControlPlaneError.invalidInput("Chat message content cannot be empty.")) {
            try await cp.sendChatMessage(projectID: projectA.id, channel: .crew, content: "Reject empty hook reply")
        }

        // Reject reply with foreign senderAgentID and foreign relatedTaskID
        cp.chatDispatchHook = { proj, _, _ in
            [
                ChatMessage(
                    projectID: proj.id,
                    channelKind: .crew,
                    senderKind: .agent,
                    senderAgentID: agentB.id,
                    senderName: agentB.name,
                    content: "Foreign sender"
                )
            ]
        }
        await #expect(throws: ControlPlaneError.invalidInput("Sender agent '\(agentB.id.uuidString)' does not belong to project.")) {
            try await cp.sendChatMessage(projectID: projectA.id, channel: .crew, content: "Reject foreign sender")
        }

        cp.chatDispatchHook = { proj, _, _ in
            [
                ChatMessage(
                    projectID: proj.id,
                    channelKind: .crew,
                    senderKind: .agent,
                    senderAgentID: agentA.id,
                    senderName: agentA.name,
                    content: "Foreign task",
                    relatedTaskID: taskB.id
                )
            ]
        }
        await #expect(throws: ControlPlaneError.invalidInput("Related task '\(taskB.id.uuidString)' does not belong to project.")) {
            try await cp.sendChatMessage(projectID: projectA.id, channel: .crew, content: "Reject foreign task")
        }
    }
}
