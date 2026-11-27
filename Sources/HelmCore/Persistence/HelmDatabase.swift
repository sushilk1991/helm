import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum HelmDatabaseError: Error, Sendable, LocalizedError, Equatable {
    case openFailed(code: Int32, message: String)
    case prepareFailed(code: Int32, message: String, sql: String)
    case stepFailed(code: Int32, message: String)
    case bindFailed(code: Int32, message: String)
    case execFailed(code: Int32, message: String)
    case notFound(String)
    case constraintViolation(String)
    case invalidData(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let c, let m): return "SQLite open failed (\(c)): \(m)"
        case .prepareFailed(let c, let m, let sql): return "SQLite prepare failed (\(c)): \(m) [SQL: \(sql)]"
        case .stepFailed(let c, let m): return "SQLite step failed (\(c)): \(m)"
        case .bindFailed(let c, let m): return "SQLite bind failed (\(c)): \(m)"
        case .execFailed(let c, let m): return "SQLite exec failed (\(c)): \(m)"
        case .notFound(let msg): return "Record not found: \(msg)"
        case .constraintViolation(let msg): return "Database constraint violation: \(msg)"
        case .invalidData(let msg): return "Invalid persisted data: \(msg)"
        }
    }
}

private final class SQLiteConnectionBox: @unchecked Sendable {
    let db: OpaquePointer

    init(_ db: OpaquePointer) {
        self.db = db
    }

    deinit {
        sqlite3_close_v2(db)
    }
}

public actor HelmDatabase {
    private let box: SQLiteConnectionBox
    public let path: String
    private let encoder = HelmJSON.makeEncoder(prettyPrinted: false)
    private let decoder = HelmJSON.makeDecoder()
    private var transactionDepth: Int = 0

    public init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            let url = URL(fileURLWithPath: path)
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close_v2(handle) }
            throw HelmDatabaseError.openFailed(code: rc, message: msg)
        }

        self.box = SQLiteConnectionBox(opened)

        try Self.execRaw(on: opened, sql: """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            PRAGMA foreign_keys=ON;
            PRAGMA busy_timeout=5000;
            """)

        let currentVersion = try Self.queryInt32Scalar(on: opened, sql: "PRAGMA user_version;") ?? 0
        if currentVersion < HelmDatabaseSchema.currentVersion {
            try Self.execRaw(on: opened, sql: "BEGIN IMMEDIATE;")
            do {
                if currentVersion < 1 {
                    try Self.execRaw(on: opened, sql: HelmDatabaseSchema.migrationV1SQL)
                }
                if currentVersion < 2 {
                    try Self.execRaw(on: opened, sql: HelmDatabaseSchema.migrationV2SQL)
                }
                try Self.execRaw(on: opened, sql: "PRAGMA user_version = \(HelmDatabaseSchema.currentVersion);")
                try Self.execRaw(on: opened, sql: "COMMIT;")
            } catch {
                try? Self.execRaw(on: opened, sql: "ROLLBACK;")
                throw error
            }
        }
    }

    public static func defaultDatabasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("Helm/helm.sqlite").path
    }

    public func journalMode() throws -> String {
        let stmt = try prepare("PRAGMA journal_mode;")
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else {
            throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
        }
        return columnText(stmt, index: 0) ?? ""
    }

    public func inTransaction<T: Sendable>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try exec("BEGIN IMMEDIATE;")
        transactionDepth = 1
        do {
            let result = try body()
            try exec("COMMIT;")
            transactionDepth = 0
            return result
        } catch {
            transactionDepth = 0
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Projects

    public func insertProject(_ project: Project) throws {
        let budgetJSON = try encodeJSONString(project.budgetPolicy)
        let sql = """
        INSERT INTO projects (id, name, goal, workspace_root, status, budget_policy_json, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: project.id.uuidString)
        try bindText(stmt, index: 2, value: project.name)
        try bindText(stmt, index: 3, value: project.goal)
        try bindText(stmt, index: 4, value: project.workspaceRoot.absoluteString)
        try bindText(stmt, index: 5, value: project.status.rawValue)
        try bindText(stmt, index: 6, value: budgetJSON)
        try bindDouble(stmt, index: 7, value: project.createdAt.timeIntervalSince1970)
        try bindDouble(stmt, index: 8, value: project.updatedAt.timeIntervalSince1970)
        try stepDone(stmt)
    }

    public func fetchProject(id: UUID) throws -> Project? {
        let stmt = try prepare("SELECT id, name, goal, workspace_root, status, budget_policy_json, created_at, updated_at FROM projects WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: id.uuidString)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else {
            throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
        }
        return try decodeProjectRow(stmt)
    }

    public func listProjects() throws -> [Project] {
        let stmt = try prepare("SELECT id, name, goal, workspace_root, status, budget_policy_json, created_at, updated_at FROM projects ORDER BY created_at ASC;")
        defer { sqlite3_finalize(stmt) }
        var out: [Project] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
            }
            out.append(try decodeProjectRow(stmt))
        }
        return out
    }

    public func updateProjectStatus(id: UUID, status: ProjectStatus, updatedAt: Date = Date()) throws {
        let stmt = try prepare("UPDATE projects SET status = ?, updated_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: status.rawValue)
        try bindDouble(stmt, index: 2, value: updatedAt.timeIntervalSince1970)
        try bindText(stmt, index: 3, value: id.uuidString)
        try stepDone(stmt)
        if sqlite3_changes(box.db) == 0 {
            throw HelmDatabaseError.notFound("Project \(id.uuidString)")
        }
    }

    // MARK: - Agents

    public func insertAgent(_ agent: AgentProfile) throws {
        let capsJSON = try encodeJSONString(Array(agent.capabilities).sorted { $0.rawValue < $1.rawValue })
        let seedJSON = try encodeJSONString(agent.characterSeed)
        let sql = """
        INSERT INTO agents (
            id, project_id, name, role, goal, capabilities_json, backend_kind,
            model_override, activity_state, character_seed_json, created_at, updated_at,
            personality, personality_notes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: agent.id.uuidString)
        try bindText(stmt, index: 2, value: agent.projectID.uuidString)
        try bindText(stmt, index: 3, value: agent.name)
        try bindText(stmt, index: 4, value: agent.role.rawValue)
        try bindText(stmt, index: 5, value: agent.goal)
        try bindText(stmt, index: 6, value: capsJSON)
        try bindText(stmt, index: 7, value: agent.backend.rawValue)
        try bindOptionalText(stmt, index: 8, value: agent.modelOverride)
        try bindText(stmt, index: 9, value: agent.activityState.rawValue)
        try bindText(stmt, index: 10, value: seedJSON)
        try bindDouble(stmt, index: 11, value: agent.createdAt.timeIntervalSince1970)
        try bindDouble(stmt, index: 12, value: agent.updatedAt.timeIntervalSince1970)
        try bindText(stmt, index: 13, value: agent.personality.rawValue)
        try bindText(stmt, index: 14, value: agent.personalityNotes)
        try stepDone(stmt)
    }

    public func fetchAgent(id: UUID) throws -> AgentProfile? {
        let sql = """
        SELECT id, project_id, name, role, goal, capabilities_json, backend_kind,
               model_override, activity_state, character_seed_json, created_at, updated_at,
               personality, personality_notes
        FROM agents WHERE id = ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: id.uuidString)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else {
            throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
        }
        return try decodeAgentRow(stmt)
    }

    public func listAgents(projectID: UUID) throws -> [AgentProfile] {
        let sql = """
        SELECT id, project_id, name, role, goal, capabilities_json, backend_kind,
               model_override, activity_state, character_seed_json, created_at, updated_at,
               personality, personality_notes
        FROM agents WHERE project_id = ? ORDER BY created_at ASC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: projectID.uuidString)
        var out: [AgentProfile] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
            }
            out.append(try decodeAgentRow(stmt))
        }
        return out
    }

    public func updateAgent(_ agent: AgentProfile) throws {
        let capsJSON = try encodeJSONString(Array(agent.capabilities).sorted { $0.rawValue < $1.rawValue })
        let sql = """
        UPDATE agents
        SET name = ?, goal = ?, capabilities_json = ?, backend_kind = ?,
            model_override = ?, personality = ?, personality_notes = ?, updated_at = ?
        WHERE id = ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: agent.name)
        try bindText(stmt, index: 2, value: agent.goal)
        try bindText(stmt, index: 3, value: capsJSON)
        try bindText(stmt, index: 4, value: agent.backend.rawValue)
        try bindOptionalText(stmt, index: 5, value: agent.modelOverride)
        try bindText(stmt, index: 6, value: agent.personality.rawValue)
        try bindText(stmt, index: 7, value: agent.personalityNotes)
        try bindDouble(stmt, index: 8, value: agent.updatedAt.timeIntervalSince1970)
        try bindText(stmt, index: 9, value: agent.id.uuidString)
        try stepDone(stmt)
        if sqlite3_changes(box.db) == 0 {
            throw HelmDatabaseError.notFound("Agent \(agent.id.uuidString)")
        }
    }

    public func updateAgentState(id: UUID, state: AgentActivityState, updatedAt: Date = Date()) throws {
        let stmt = try prepare("UPDATE agents SET activity_state = ?, updated_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: state.rawValue)
        try bindDouble(stmt, index: 2, value: updatedAt.timeIntervalSince1970)
        try bindText(stmt, index: 3, value: id.uuidString)
        try stepDone(stmt)
    }

    // MARK: - Tasks

    public func insertTask(_ task: DelegatedTask) throws {
        let waitingJSON = try encodeJSONString(task.waitingOn)
        let artifactsJSON = try encodeJSONString(task.artifactPaths)
        let sql = """
        INSERT INTO tasks (
            id, project_id, parent_task_id, assigned_agent_id, created_by_agent_id,
            title, instructions, status, waiting_on_json, attempt_count, max_attempts,
            has_external_side_effect, result_summary, error_summary, artifact_paths_json,
            created_at, updated_at, started_at, completed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: task.id.uuidString)
        try bindText(stmt, index: 2, value: task.projectID.uuidString)
        try bindOptionalText(stmt, index: 3, value: task.parentTaskID?.uuidString)
        try bindText(stmt, index: 4, value: task.assignedAgentID.uuidString)
        try bindOptionalText(stmt, index: 5, value: task.createdByAgentID?.uuidString)
        try bindText(stmt, index: 6, value: task.title)
        try bindText(stmt, index: 7, value: task.instructions)
        try bindText(stmt, index: 8, value: task.status.rawValue)
        try bindText(stmt, index: 9, value: waitingJSON)
        try bindInt(stmt, index: 10, value: task.attemptCount)
        try bindInt(stmt, index: 11, value: task.maxAttempts)
        try bindInt(stmt, index: 12, value: task.hasExternalSideEffect ? 1 : 0)
        try bindOptionalText(stmt, index: 13, value: task.resultSummary)
        try bindOptionalText(stmt, index: 14, value: task.errorSummary)
        try bindText(stmt, index: 15, value: artifactsJSON)
        try bindDouble(stmt, index: 16, value: task.createdAt.timeIntervalSince1970)
        try bindDouble(stmt, index: 17, value: task.updatedAt.timeIntervalSince1970)
        try bindOptionalDouble(stmt, index: 18, value: task.startedAt?.timeIntervalSince1970)
        try bindOptionalDouble(stmt, index: 19, value: task.completedAt?.timeIntervalSince1970)
        try stepDone(stmt)
    }

    public func fetchTask(id: UUID) throws -> DelegatedTask? {
        let sql = """
        SELECT id, project_id, parent_task_id, assigned_agent_id, created_by_agent_id,
               title, instructions, status, waiting_on_json, attempt_count, max_attempts,
               has_external_side_effect, result_summary, error_summary, artifact_paths_json,
               created_at, updated_at, started_at, completed_at
        FROM tasks WHERE id = ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: id.uuidString)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else {
            throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
        }
        return try decodeTaskRow(stmt)
    }

    public func listTasks(projectID: UUID, status: TaskStatus? = nil) throws -> [DelegatedTask] {
        let sql: String
        if status != nil {
            sql = """
            SELECT id, project_id, parent_task_id, assigned_agent_id, created_by_agent_id,
                   title, instructions, status, waiting_on_json, attempt_count, max_attempts,
                   has_external_side_effect, result_summary, error_summary, artifact_paths_json,
                   created_at, updated_at, started_at, completed_at
            FROM tasks WHERE project_id = ? AND status = ? ORDER BY created_at ASC;
            """
        } else {
            sql = """
            SELECT id, project_id, parent_task_id, assigned_agent_id, created_by_agent_id,
                   title, instructions, status, waiting_on_json, attempt_count, max_attempts,
                   has_external_side_effect, result_summary, error_summary, artifact_paths_json,
                   created_at, updated_at, started_at, completed_at
            FROM tasks WHERE project_id = ? ORDER BY created_at ASC;
            """
        }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: projectID.uuidString)
        if let status {
            try bindText(stmt, index: 2, value: status.rawValue)
        }
        var out: [DelegatedTask] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
            }
            out.append(try decodeTaskRow(stmt))
        }
        return out
    }

    public func updateTask(_ task: DelegatedTask) throws {
        let waitingJSON = try encodeJSONString(task.waitingOn)
        let artifactsJSON = try encodeJSONString(task.artifactPaths)
        let sql = """
        UPDATE tasks
        SET assigned_agent_id = ?, title = ?, instructions = ?, status = ?,
            waiting_on_json = ?, attempt_count = ?, max_attempts = ?,
            has_external_side_effect = ?, result_summary = ?, error_summary = ?,
            artifact_paths_json = ?, updated_at = ?, started_at = ?, completed_at = ?
        WHERE id = ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: task.assignedAgentID.uuidString)
        try bindText(stmt, index: 2, value: task.title)
        try bindText(stmt, index: 3, value: task.instructions)
        try bindText(stmt, index: 4, value: task.status.rawValue)
        try bindText(stmt, index: 5, value: waitingJSON)
        try bindInt(stmt, index: 6, value: task.attemptCount)
        try bindInt(stmt, index: 7, value: task.maxAttempts)
        try bindInt(stmt, index: 8, value: task.hasExternalSideEffect ? 1 : 0)
        try bindOptionalText(stmt, index: 9, value: task.resultSummary)
        try bindOptionalText(stmt, index: 10, value: task.errorSummary)
        try bindText(stmt, index: 11, value: artifactsJSON)
        try bindDouble(stmt, index: 12, value: task.updatedAt.timeIntervalSince1970)
        try bindOptionalDouble(stmt, index: 13, value: task.startedAt?.timeIntervalSince1970)
        try bindOptionalDouble(stmt, index: 14, value: task.completedAt?.timeIntervalSince1970)
        try bindText(stmt, index: 15, value: task.id.uuidString)
        try stepDone(stmt)
    }

    // MARK: - Shared State

    public func fetchSharedState(
        projectID: UUID,
        scope: MemoryScope,
        ownerAgentID: UUID?,
        key: String
    ) throws -> SharedStateEntry? {
        let sql: String
        if scope == .agentPrivate {
            sql = """
            SELECT id, project_id, scope, owner_agent_id, category, state_key, title, content,
                   trust_level, provenance_json, content_sha256, pinned, access_count,
                   last_accessed_at, supersedes_entry_id, created_at, updated_at
            FROM shared_state
            WHERE project_id = ? AND scope = ? AND owner_agent_id = ? AND state_key = ?
            LIMIT 1;
            """
        } else {
            sql = """
            SELECT id, project_id, scope, owner_agent_id, category, state_key, title, content,
                   trust_level, provenance_json, content_sha256, pinned, access_count,
                   last_accessed_at, supersedes_entry_id, created_at, updated_at
            FROM shared_state
            WHERE project_id = ? AND scope = ? AND state_key = ?
            LIMIT 1;
            """
        }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: projectID.uuidString)
        try bindText(stmt, index: 2, value: scope.rawValue)
        if scope == .agentPrivate {
            try bindOptionalText(stmt, index: 3, value: ownerAgentID?.uuidString)
            try bindText(stmt, index: 4, value: key)
        } else {
            try bindText(stmt, index: 3, value: key)
        }
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else {
            throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
        }
        return try decodeSharedStateRow(stmt)
    }

    public func upsertSharedState(_ entry: SharedStateEntry) throws -> SharedStateEntry {
        return try inTransaction {
            let existing = try fetchSharedState(
                projectID: entry.projectID,
                scope: entry.scope,
                ownerAgentID: entry.ownerAgentID,
                key: entry.key
            )
            let provJSON = try encodeJSONString(entry.provenance)
            if let existing {
                let updated = SharedStateEntry(
                    id: existing.id,
                    projectID: entry.projectID,
                    scope: entry.scope,
                    ownerAgentID: entry.ownerAgentID,
                    category: entry.category,
                    key: entry.key,
                    title: entry.title,
                    content: entry.content,
                    trustLevel: entry.trustLevel,
                    provenance: entry.provenance,
                    pinned: entry.pinned,
                    accessCount: existing.accessCount,
                    lastAccessedAt: entry.lastAccessedAt,
                    createdAt: existing.createdAt,
                    updatedAt: entry.updatedAt,
                    contentSHA256: entry.contentSHA256,
                    supersedesEntryID: existing.id
                )
                let sql = """
                UPDATE shared_state
                SET owner_agent_id = ?, category = ?, title = ?, content = ?, trust_level = ?,
                    provenance_json = ?, content_sha256 = ?, pinned = ?, last_accessed_at = ?,
                    supersedes_entry_id = ?, updated_at = ?
                WHERE id = ?;
                """
                let stmt = try prepare(sql)
                defer { sqlite3_finalize(stmt) }
                try bindOptionalText(stmt, index: 1, value: updated.ownerAgentID?.uuidString)
                try bindText(stmt, index: 2, value: updated.category.rawValue)
                try bindText(stmt, index: 3, value: updated.title)
                try bindText(stmt, index: 4, value: updated.content)
                try bindText(stmt, index: 5, value: updated.trustLevel.rawValue)
                try bindText(stmt, index: 6, value: provJSON)
                try bindText(stmt, index: 7, value: updated.contentSHA256)
                try bindInt(stmt, index: 8, value: updated.pinned ? 1 : 0)
                try bindDouble(stmt, index: 9, value: updated.lastAccessedAt.timeIntervalSince1970)
                try bindOptionalText(stmt, index: 10, value: updated.supersedesEntryID?.uuidString)
                try bindDouble(stmt, index: 11, value: updated.updatedAt.timeIntervalSince1970)
                try bindText(stmt, index: 12, value: updated.id.uuidString)
                try stepDone(stmt)
                return updated
            } else {
                let sql = """
                INSERT INTO shared_state (
                    id, project_id, scope, owner_agent_id, category, state_key, title, content,
                    trust_level, provenance_json, content_sha256, pinned, access_count,
                    last_accessed_at, supersedes_entry_id, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
                let stmt = try prepare(sql)
                defer { sqlite3_finalize(stmt) }
                try bindText(stmt, index: 1, value: entry.id.uuidString)
                try bindText(stmt, index: 2, value: entry.projectID.uuidString)
                try bindText(stmt, index: 3, value: entry.scope.rawValue)
                try bindOptionalText(stmt, index: 4, value: entry.ownerAgentID?.uuidString)
                try bindText(stmt, index: 5, value: entry.category.rawValue)
                try bindText(stmt, index: 6, value: entry.key)
                try bindText(stmt, index: 7, value: entry.title)
                try bindText(stmt, index: 8, value: entry.content)
                try bindText(stmt, index: 9, value: entry.trustLevel.rawValue)
                try bindText(stmt, index: 10, value: provJSON)
                try bindText(stmt, index: 11, value: entry.contentSHA256)
                try bindInt(stmt, index: 12, value: entry.pinned ? 1 : 0)
                try bindInt(stmt, index: 13, value: entry.accessCount)
                try bindDouble(stmt, index: 14, value: entry.lastAccessedAt.timeIntervalSince1970)
                try bindOptionalText(stmt, index: 15, value: entry.supersedesEntryID?.uuidString)
                try bindDouble(stmt, index: 16, value: entry.createdAt.timeIntervalSince1970)
                try bindDouble(stmt, index: 17, value: entry.updatedAt.timeIntervalSince1970)
                try stepDone(stmt)
                return entry
            }
        }
    }

    public func listSharedState(
        projectID: UUID,
        scope: MemoryScope? = nil,
        ownerAgentID: UUID? = nil
    ) throws -> [SharedStateEntry] {
        var clauses = ["project_id = ?"]
        if scope != nil { clauses.append("scope = ?") }
        if ownerAgentID != nil { clauses.append("owner_agent_id = ?") }
        let sql = """
        SELECT id, project_id, scope, owner_agent_id, category, state_key, title, content,
               trust_level, provenance_json, content_sha256, pinned, access_count,
               last_accessed_at, supersedes_entry_id, created_at, updated_at
        FROM shared_state
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY updated_at DESC, id ASC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        try bindText(stmt, index: idx, value: projectID.uuidString)
        idx += 1
        if let scope {
            try bindText(stmt, index: idx, value: scope.rawValue)
            idx += 1
        }
        if let ownerAgentID {
            try bindText(stmt, index: idx, value: ownerAgentID.uuidString)
        }
        var out: [SharedStateEntry] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
            }
            out.append(try decodeSharedStateRow(stmt))
        }
        return out
    }

    public func touchSharedStateAccess(ids: [UUID], accessedAt: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        try inTransaction {
            let stmt = try prepare("UPDATE shared_state SET access_count = access_count + 1, last_accessed_at = ? WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                try bindDouble(stmt, index: 1, value: accessedAt.timeIntervalSince1970)
                try bindText(stmt, index: 2, value: id.uuidString)
                try stepDone(stmt)
            }
        }
    }

    // MARK: - Prompt Channel Digests

    public func fetchPromptChannelDigests(projectID: UUID, agentID: UUID) throws -> [String: String] {
        let stmt = try prepare("SELECT channel, digest FROM prompt_channel_digests WHERE project_id = ? AND agent_id = ?;")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: projectID.uuidString)
        try bindText(stmt, index: 2, value: agentID.uuidString)
        var out: [String: String] = [:]
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
            }
            if let ch = columnText(stmt, index: 0), let dg = columnText(stmt, index: 1) {
                out[ch] = dg
            }
        }
        return out
    }

    public func upsertPromptChannelDigest(
        projectID: UUID,
        agentID: UUID,
        channel: String,
        digest: String,
        updatedAt: Date = Date()
    ) throws {
        let sql = """
        INSERT INTO prompt_channel_digests (project_id, agent_id, channel, digest, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(project_id, agent_id, channel)
        DO UPDATE SET digest = excluded.digest, updated_at = excluded.updated_at;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: projectID.uuidString)
        try bindText(stmt, index: 2, value: agentID.uuidString)
        try bindText(stmt, index: 3, value: channel)
        try bindText(stmt, index: 4, value: digest)
        try bindDouble(stmt, index: 5, value: updatedAt.timeIntervalSince1970)
        try stepDone(stmt)
    }

    public func clearPromptChannelDigests(projectID: UUID, agentID: UUID) throws {
        let stmt = try prepare("DELETE FROM prompt_channel_digests WHERE project_id = ? AND agent_id = ?;")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: projectID.uuidString)
        try bindText(stmt, index: 2, value: agentID.uuidString)
        try stepDone(stmt)
    }

    // MARK: - Events

    public func appendEvent(_ event: RunEvent) throws {
        let sql = """
        INSERT INTO events (id, project_id, agent_id, task_id, kind, summary, payload_json, trust_level, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: event.id.uuidString)
        try bindText(stmt, index: 2, value: event.projectID.uuidString)
        try bindOptionalText(stmt, index: 3, value: event.agentID?.uuidString)
        try bindOptionalText(stmt, index: 4, value: event.taskID?.uuidString)
        try bindText(stmt, index: 5, value: event.kind.rawValue)
        try bindText(stmt, index: 6, value: event.summary)
        try bindOptionalText(stmt, index: 7, value: event.payloadJSON)
        try bindText(stmt, index: 8, value: event.trustLevel.rawValue)
        try bindDouble(stmt, index: 9, value: event.createdAt.timeIntervalSince1970)
        try stepDone(stmt)
    }

    public func fetchEvent(id: UUID) throws -> RunEvent? {
        let stmt = try prepare("SELECT id, project_id, agent_id, task_id, kind, summary, payload_json, trust_level, created_at FROM events WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: id.uuidString)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else {
            throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
        }
        return try decodeEventRow(stmt)
    }

    public func listEvents(projectID: UUID, limit: Int = 500) throws -> [RunEvent] {
        let sql = """
        SELECT id, project_id, agent_id, task_id, kind, summary, payload_json, trust_level, created_at
        FROM (
            SELECT seq, id, project_id, agent_id, task_id, kind, summary, payload_json, trust_level, created_at
            FROM events
            WHERE project_id = ?
            ORDER BY seq DESC
            LIMIT ?
        )
        ORDER BY seq ASC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: projectID.uuidString)
        try bindInt(stmt, index: 2, value: max(0, limit))
        var out: [RunEvent] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
            }
            out.append(try decodeEventRow(stmt))
        }
        return out
    }

    // MARK: - Exceptions

    public func upsertOpenException(_ alert: ExceptionAlert) throws -> ExceptionAlert {
        try inTransaction {
            if let existing = try fetchOpenException(projectID: alert.projectID, dedupKey: alert.dedupKey) {
                return existing
            }
            let optionsJSON = try encodeJSONString(alert.suggestedOptions)
            let resolutionJSON: String? = try alert.resolution.map { try encodeJSONString($0) }
            let sql = """
            INSERT INTO exceptions (
                id, project_id, task_id, agent_id, kind, severity, status, dedup_key,
                title, summary, diagnostic_summary, suggested_options_json, evidence_json,
                resolution_json, created_at, resolved_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, index: 1, value: alert.id.uuidString)
            try bindText(stmt, index: 2, value: alert.projectID.uuidString)
            try bindOptionalText(stmt, index: 3, value: alert.taskID?.uuidString)
            try bindOptionalText(stmt, index: 4, value: alert.agentID?.uuidString)
            try bindText(stmt, index: 5, value: alert.kind.rawValue)
            try bindText(stmt, index: 6, value: alert.severity.rawValue)
            try bindText(stmt, index: 7, value: alert.status.rawValue)
            try bindText(stmt, index: 8, value: alert.dedupKey)
            try bindText(stmt, index: 9, value: alert.title)
            try bindText(stmt, index: 10, value: alert.summary)
            try bindText(stmt, index: 11, value: alert.diagnosticSummary)
            try bindText(stmt, index: 12, value: optionsJSON)
            try bindOptionalText(stmt, index: 13, value: alert.evidenceJSON)
            try bindOptionalText(stmt, index: 14, value: resolutionJSON)
            try bindDouble(stmt, index: 15, value: alert.createdAt.timeIntervalSince1970)
            try bindOptionalDouble(stmt, index: 16, value: alert.resolvedAt?.timeIntervalSince1970)
            try stepDone(stmt)
            return alert
        }
    }

    public func fetchException(id: UUID) throws -> ExceptionAlert? {
        let sql = """
        SELECT id, project_id, task_id, agent_id, kind, severity, status, dedup_key,
               title, summary, diagnostic_summary, suggested_options_json, evidence_json,
               resolution_json, created_at, resolved_at
        FROM exceptions WHERE id = ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: id.uuidString)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else {
            throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
        }
        return try decodeExceptionRow(stmt)
    }

    public func fetchOpenException(projectID: UUID, dedupKey: String) throws -> ExceptionAlert? {
        let sql = """
        SELECT id, project_id, task_id, agent_id, kind, severity, status, dedup_key,
               title, summary, diagnostic_summary, suggested_options_json, evidence_json,
               resolution_json, created_at, resolved_at
        FROM exceptions WHERE project_id = ? AND dedup_key = ? AND status = 'open'
        LIMIT 1;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: projectID.uuidString)
        try bindText(stmt, index: 2, value: dedupKey)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else {
            throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
        }
        return try decodeExceptionRow(stmt)
    }

    public func listExceptions(projectID: UUID, openOnly: Bool = false) throws -> [ExceptionAlert] {
        let sql = """
        SELECT id, project_id, task_id, agent_id, kind, severity, status, dedup_key,
               title, summary, diagnostic_summary, suggested_options_json, evidence_json,
               resolution_json, created_at, resolved_at
        FROM exceptions
        WHERE project_id = ? \(openOnly ? "AND status = 'open'" : "")
        ORDER BY created_at ASC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: projectID.uuidString)
        var out: [ExceptionAlert] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
            }
            out.append(try decodeExceptionRow(stmt))
        }
        return out
    }

    // MARK: - Durable Hold & Resolution Transactions

    public func triggerDurableHold(alert: ExceptionAlert) throws -> ExceptionAlert {
        try inTransaction {
            if let existing = try fetchOpenException(projectID: alert.projectID, dedupKey: alert.dedupKey) {
                try updateProjectStatus(id: alert.projectID, status: .held)
                return existing
            }
            let persisted = try upsertOpenException(alert)
            if let taskID = persisted.taskID, var task = try fetchTask(id: taskID) {
                if task.status != .outcomeUnknown {
                    task.status = .needsHuman
                }
                task.errorSummary = persisted.summary
                task.updatedAt = Date()
                try updateTask(task)
            }
            if let agentID = persisted.agentID {
                try updateAgentState(id: agentID, state: .exception)
            }
            try updateProjectStatus(id: persisted.projectID, status: .held)
            try appendEvent(RunEvent(
                projectID: persisted.projectID,
                agentID: persisted.agentID,
                taskID: persisted.taskID,
                kind: .exceptionRaised,
                summary: "[\(persisted.kind.rawValue)] \(persisted.summary)",
                trustLevel: .orchestratorVerified
            ))
            try appendEvent(RunEvent(
                projectID: persisted.projectID,
                agentID: persisted.agentID,
                taskID: persisted.taskID,
                kind: .projectHeld,
                summary: "Project held for exception \(persisted.id.uuidString)",
                trustLevel: .orchestratorVerified
            ))
            return persisted
        }
    }

    private func applyResolution(
        _ resolution: ExceptionResolution,
        to task: inout DelegatedTask,
        includeBlockedAndFailed: Bool,
        resolvedAt: Date
    ) {
        let shouldRequeue: Bool
        if includeBlockedAndFailed {
            shouldRequeue = task.status == .needsHuman || task.status == .outcomeUnknown || task.status == .blocked || task.status == .failed
        } else {
            shouldRequeue = task.status == .needsHuman || task.status == .outcomeUnknown
        }

        switch resolution {
        case .approve:
            if shouldRequeue {
                task.status = .queued
            }
            task.errorSummary = nil
        case .redirect(let note):
            if shouldRequeue {
                task.status = .queued
            }
            task.instructions += "\n[Human Redirect Guidance]: \(note)"
            task.errorSummary = nil
        case .retry:
            if shouldRequeue {
                task.status = .queued
            }
            task.attemptCount = 0
            task.errorSummary = nil
        case .abort:
            task.status = .cancelled
        }
        task.updatedAt = resolvedAt
    }

    public func resolveDurableException(
        id: UUID,
        resolution: ExceptionResolution,
        resolvedAt: Date = Date()
    ) throws -> ExceptionAlert {
        try inTransaction {
            guard var alert = try fetchException(id: id) else {
                throw HelmDatabaseError.notFound("Exception \(id.uuidString)")
            }
            guard alert.status == .open else {
                throw HelmDatabaseError.constraintViolation("Exception \(id.uuidString) is already \(alert.status.rawValue)")
            }

            let resolutionJSON = try encodeJSONString(resolution)
            let stmt = try prepare("UPDATE exceptions SET status = 'resolved', resolution_json = ?, resolved_at = ? WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, index: 1, value: resolutionJSON)
            try bindDouble(stmt, index: 2, value: resolvedAt.timeIntervalSince1970)
            try bindText(stmt, index: 3, value: id.uuidString)
            try stepDone(stmt)

            alert.status = .resolved
            alert.resolution = resolution
            alert.resolvedAt = resolvedAt

            if let taskID = alert.taskID, var task = try fetchTask(id: taskID) {
                applyResolution(resolution, to: &task, includeBlockedAndFailed: true, resolvedAt: resolvedAt)
                try updateTask(task)
            }

            let remainingOpen = try listExceptions(projectID: alert.projectID, openOnly: true)
            let tasksWithOtherOpenAlerts = Set(remainingOpen.compactMap(\.taskID))

            if alert.taskID == nil || remainingOpen.isEmpty {
                for var task in try listTasks(projectID: alert.projectID) {
                    guard task.id != alert.taskID,
                          !tasksWithOtherOpenAlerts.contains(task.id),
                          task.status == .needsHuman || task.status == .outcomeUnknown else {
                        continue
                    }
                    applyResolution(resolution, to: &task, includeBlockedAndFailed: false, resolvedAt: resolvedAt)
                    try updateTask(task)
                }
            }

            if case .redirect(let note) = resolution {
                let entry = SharedStateEntry(
                    projectID: alert.projectID,
                    scope: .projectShared,
                    ownerAgentID: nil,
                    category: .decision,
                    key: "human.redirect.\(alert.id.uuidString.prefix(8))",
                    title: "Human Redirect Decision",
                    content: note,
                    trustLevel: .humanAuthoritative,
                    provenance: ProvenanceRecord(source: .humanOwner),
                    pinned: true
                )
                _ = try upsertSharedState(entry)
            }

            let targetAgentState: AgentActivityState = resolution == .abort ? .paused : .idle
            if let agentID = alert.agentID {
                try updateAgentState(id: agentID, state: targetAgentState, updatedAt: resolvedAt)
            }
            if remainingOpen.isEmpty {
                for agent in try listAgents(projectID: alert.projectID) where agent.activityState == .exception && agent.id != alert.agentID {
                    try updateAgentState(id: agent.id, state: targetAgentState, updatedAt: resolvedAt)
                }
            }

            switch resolution {
            case .abort:
                try updateProjectStatus(id: alert.projectID, status: .paused, updatedAt: resolvedAt)
            case .approve, .redirect, .retry:
                if remainingOpen.isEmpty {
                    try updateProjectStatus(id: alert.projectID, status: .idle, updatedAt: resolvedAt)
                }
            }

            try appendEvent(RunEvent(
                projectID: alert.projectID,
                agentID: alert.agentID,
                taskID: alert.taskID,
                kind: .exceptionResolved,
                summary: "Resolved \(alert.kind.rawValue) via \(resolution.actionName)",
                trustLevel: .humanAuthoritative
            ))

            return alert
        }
    }

    // MARK: - Artifacts

    public func insertArtifact(_ artifact: ArtifactRecord) throws {
        let sql = """
        INSERT INTO artifacts (id, project_id, agent_id, task_id, kind, relative_path, mime_type, byte_size, sha256, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: artifact.id.uuidString)
        try bindText(stmt, index: 2, value: artifact.projectID.uuidString)
        try bindOptionalText(stmt, index: 3, value: artifact.agentID?.uuidString)
        try bindOptionalText(stmt, index: 4, value: artifact.taskID?.uuidString)
        try bindText(stmt, index: 5, value: artifact.kind)
        try bindText(stmt, index: 6, value: artifact.relativePath)
        try bindOptionalText(stmt, index: 7, value: artifact.mimeType)
        try bindInt64(stmt, index: 8, value: artifact.byteSize)
        try bindText(stmt, index: 9, value: artifact.sha256)
        try bindDouble(stmt, index: 10, value: artifact.createdAt.timeIntervalSince1970)
        try stepDone(stmt)
    }

    public func listArtifacts(projectID: UUID) throws -> [ArtifactRecord] {
        let sql = """
        SELECT id, project_id, agent_id, task_id, kind, relative_path, mime_type, byte_size, sha256, created_at
        FROM artifacts WHERE project_id = ? ORDER BY created_at ASC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: projectID.uuidString)
        var out: [ArtifactRecord] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
            }
            guard
                let idStr = columnText(stmt, index: 0), let id = UUID(uuidString: idStr),
                let projStr = columnText(stmt, index: 1), let projID = UUID(uuidString: projStr),
                let kind = columnText(stmt, index: 4),
                let relPath = columnText(stmt, index: 5),
                let sha = columnText(stmt, index: 8)
            else {
                throw HelmDatabaseError.invalidData("Malformed artifact row")
            }
            let agentID = columnText(stmt, index: 2).flatMap(UUID.init(uuidString:))
            let taskID = columnText(stmt, index: 3).flatMap(UUID.init(uuidString:))
            let mime = columnText(stmt, index: 6)
            let size = sqlite3_column_int64(stmt, 7)
            let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
            out.append(ArtifactRecord(
                id: id,
                projectID: projID,
                agentID: agentID,
                taskID: taskID,
                kind: kind,
                relativePath: relPath,
                mimeType: mime,
                byteSize: size,
                sha256: sha,
                createdAt: created
            ))
        }
        return out
    }

    // MARK: - Boot Crash Recovery

    public func reconcileOrphanedRunsOnBoot(now: Date = Date()) throws -> Int {
        try inTransaction {
            var reconciledCount = 0
            let projects = try listProjects()
            for project in projects {
                let tasks = try listTasks(projectID: project.id)
                for var task in tasks where task.status == .running {
                    reconciledCount += 1
                    if task.hasExternalSideEffect {
                        task.status = .outcomeUnknown
                        task.errorSummary = "Previous run exited while external side-effect task was active; outcome unknown."
                        task.updatedAt = now
                        try updateTask(task)
                        let alert = ExceptionAlert(
                            projectID: project.id,
                            taskID: task.id,
                            agentID: task.assignedAgentID,
                            kind: .humanDecision,
                            severity: .critical,
                            title: "Recovered Interrupted Side-Effect Task",
                            summary: "Task '\(task.title)' was interrupted after an external side effect; outcome unknown.",
                            dedupKey: "boot_recovery:\(task.id.uuidString)"
                        )
                        _ = try triggerDurableHold(alert: alert)
                    } else {
                        task.status = .queued
                        task.updatedAt = now
                        try updateTask(task)
                    }
                    try appendEvent(RunEvent(
                        projectID: project.id,
                        agentID: task.assignedAgentID,
                        taskID: task.id,
                        kind: .recoveryReconciled,
                        summary: "Reconciled orphaned running task '\(task.title)' -> \(task.status.rawValue)",
                        trustLevel: .orchestratorVerified,
                        createdAt: now
                    ))
                }

                let agents = try listAgents(projectID: project.id)
                let openExceptions = try listExceptions(projectID: project.id, openOnly: true)
                for agent in agents where agent.activityState != .idle && agent.activityState != .completed && agent.activityState != .exception {
                    let nextState: AgentActivityState = openExceptions.contains(where: { $0.agentID == agent.id }) ? .exception : .idle
                    try updateAgentState(id: agent.id, state: nextState, updatedAt: now)
                }

                if project.status == .running {
                    let nextProjStatus: ProjectStatus = openExceptions.isEmpty ? .paused : .held
                    try updateProjectStatus(id: project.id, status: nextProjStatus, updatedAt: now)
                    try appendEvent(RunEvent(
                        projectID: project.id,
                        kind: .recoveryReconciled,
                        summary: "Boot reconciliation transitioned running project to \(nextProjStatus.rawValue)",
                        trustLevel: .orchestratorVerified,
                        createdAt: now
                    ))
                    reconciledCount += 1
                }
            }
            return reconciledCount
        }
    }

    // MARK: - Low-level SQLite Helpers

    private func exec(_ sql: String) throws {
        try Self.execRaw(on: box.db, sql: sql)
    }

    private static func execRaw(on db: OpaquePointer, sql: String) throws {
        var errPtr: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errPtr)
        if rc != SQLITE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let errPtr { sqlite3_free(errPtr) }
            throw HelmDatabaseError.execFailed(code: rc, message: msg)
        }
    }

    private static func queryInt32Scalar(on db: OpaquePointer, sql: String) throws -> Int32? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            throw HelmDatabaseError.prepareFailed(code: rc, message: String(cString: sqlite3_errmsg(db)), sql: sql)
        }
        defer { sqlite3_finalize(prepared) }
        let stepRC = sqlite3_step(prepared)
        if stepRC == SQLITE_ROW {
            return sqlite3_column_int(prepared, 0)
        }
        return nil
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(box.db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            throw HelmDatabaseError.prepareFailed(code: rc, message: lastErrorMessage(), sql: sql)
        }
        return prepared
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return }
        if rc == SQLITE_CONSTRAINT {
            throw HelmDatabaseError.constraintViolation(lastErrorMessage())
        }
        throw HelmDatabaseError.stepFailed(code: rc, message: lastErrorMessage())
    }

    private func bindText(_ stmt: OpaquePointer, index: Int32, value: String) throws {
        let rc = value.withCString { cStr in
            sqlite3_bind_text(stmt, index, cStr, -1, sqliteTransient)
        }
        guard rc == SQLITE_OK else {
            throw HelmDatabaseError.bindFailed(code: rc, message: lastErrorMessage())
        }
    }

    private func bindOptionalText(_ stmt: OpaquePointer, index: Int32, value: String?) throws {
        if let value {
            try bindText(stmt, index: index, value: value)
        } else {
            let rc = sqlite3_bind_null(stmt, index)
            guard rc == SQLITE_OK else {
                throw HelmDatabaseError.bindFailed(code: rc, message: lastErrorMessage())
            }
        }
    }

    private func bindInt(_ stmt: OpaquePointer, index: Int32, value: Int) throws {
        let rc = sqlite3_bind_int64(stmt, index, Int64(value))
        guard rc == SQLITE_OK else {
            throw HelmDatabaseError.bindFailed(code: rc, message: lastErrorMessage())
        }
    }

    private func bindInt64(_ stmt: OpaquePointer, index: Int32, value: Int64) throws {
        let rc = sqlite3_bind_int64(stmt, index, value)
        guard rc == SQLITE_OK else {
            throw HelmDatabaseError.bindFailed(code: rc, message: lastErrorMessage())
        }
    }

    private func bindDouble(_ stmt: OpaquePointer, index: Int32, value: Double) throws {
        let rc = sqlite3_bind_double(stmt, index, value)
        guard rc == SQLITE_OK else {
            throw HelmDatabaseError.bindFailed(code: rc, message: lastErrorMessage())
        }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer, index: Int32, value: Double?) throws {
        if let value {
            try bindDouble(stmt, index: index, value: value)
        } else {
            let rc = sqlite3_bind_null(stmt, index)
            guard rc == SQLITE_OK else {
                throw HelmDatabaseError.bindFailed(code: rc, message: lastErrorMessage())
            }
        }
    }

    private func columnText(_ stmt: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: cStr)
    }

    private func columnOptionalDouble(_ stmt: OpaquePointer, index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(box.db))
    }

    private func encodeJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let str = String(data: data, encoding: .utf8) else {
            throw HelmDatabaseError.invalidData("Failed to encode UTF-8 JSON")
        }
        return str
    }

    private func decodeJSONString<T: Decodable>(_ type: T.Type, from str: String) throws -> T {
        guard let data = str.data(using: .utf8) else {
            throw HelmDatabaseError.invalidData("Invalid UTF-8 JSON")
        }
        return try decoder.decode(type, from: data)
    }

    // MARK: - Row Decoders

    private func decodeProjectRow(_ stmt: OpaquePointer) throws -> Project {
        guard
            let idStr = columnText(stmt, index: 0), let id = UUID(uuidString: idStr),
            let name = columnText(stmt, index: 1),
            let goal = columnText(stmt, index: 2),
            let wsStr = columnText(stmt, index: 3),
            let statusStr = columnText(stmt, index: 4), let status = ProjectStatus(rawValue: statusStr),
            let budgetJSON = columnText(stmt, index: 5)
        else {
            throw HelmDatabaseError.invalidData("Malformed project row")
        }
        let wsURL = URL(string: wsStr) ?? URL(fileURLWithPath: wsStr)
        let budget = try decodeJSONString(BudgetPolicy.self, from: budgetJSON)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        return Project(
            id: id,
            name: name,
            goal: goal,
            workspaceRoot: wsURL,
            status: status,
            budgetPolicy: budget,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func decodeAgentRow(_ stmt: OpaquePointer) throws -> AgentProfile {
        guard
            let idStr = columnText(stmt, index: 0), let id = UUID(uuidString: idStr),
            let projStr = columnText(stmt, index: 1), let projectID = UUID(uuidString: projStr),
            let name = columnText(stmt, index: 2),
            let roleStr = columnText(stmt, index: 3), let role = AgentRole(rawValue: roleStr),
            let goal = columnText(stmt, index: 4),
            let capsJSON = columnText(stmt, index: 5),
            let backendStr = columnText(stmt, index: 6), let backend = LLMBackendKind(rawValue: backendStr),
            let stateStr = columnText(stmt, index: 8), let state = AgentActivityState(rawValue: stateStr),
            let seedJSON = columnText(stmt, index: 9)
        else {
            throw HelmDatabaseError.invalidData("Malformed agent row")
        }
        let modelOverride = columnText(stmt, index: 7)
        let capsList = try decodeJSONString([AgentCapability].self, from: capsJSON)
        let seed = try decodeJSONString(AgentCharacterSeed.self, from: seedJSON)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
        let personality = columnText(stmt, index: 12).flatMap(AgentPersonality.init(rawValue:))
            ?? AgentPersonality.defaultForRole(role)
        let personalityNotes = columnText(stmt, index: 13) ?? ""
        return AgentProfile(
            id: id,
            projectID: projectID,
            name: name,
            role: role,
            goal: goal,
            personality: personality,
            personalityNotes: personalityNotes,
            capabilities: Set(capsList),
            backend: backend,
            modelOverride: modelOverride,
            activityState: state,
            characterSeed: seed,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func decodeTaskRow(_ stmt: OpaquePointer) throws -> DelegatedTask {
        guard
            let idStr = columnText(stmt, index: 0), let id = UUID(uuidString: idStr),
            let projStr = columnText(stmt, index: 1), let projectID = UUID(uuidString: projStr),
            let assignedStr = columnText(stmt, index: 3), let assignedID = UUID(uuidString: assignedStr),
            let title = columnText(stmt, index: 5),
            let instructions = columnText(stmt, index: 6),
            let statusStr = columnText(stmt, index: 7), let status = TaskStatus(rawValue: statusStr),
            let waitingJSON = columnText(stmt, index: 8),
            let artifactsJSON = columnText(stmt, index: 14)
        else {
            throw HelmDatabaseError.invalidData("Malformed task row")
        }
        let parentID = columnText(stmt, index: 2).flatMap(UUID.init(uuidString:))
        let createdByID = columnText(stmt, index: 4).flatMap(UUID.init(uuidString:))
        let waitingOn = try decodeJSONString([UUID].self, from: waitingJSON)
        let attempts = Int(sqlite3_column_int64(stmt, 9))
        let maxAttempts = Int(sqlite3_column_int64(stmt, 10))
        let hasExternal = sqlite3_column_int64(stmt, 11) != 0
        let resultSummary = columnText(stmt, index: 12)
        let errorSummary = columnText(stmt, index: 13)
        let artifactPaths = try decodeJSONString([String].self, from: artifactsJSON)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 15))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 16))
        let startedAt = columnOptionalDouble(stmt, index: 17).map(Date.init(timeIntervalSince1970:))
        let completedAt = columnOptionalDouble(stmt, index: 18).map(Date.init(timeIntervalSince1970:))
        return DelegatedTask(
            id: id,
            projectID: projectID,
            parentTaskID: parentID,
            assignedAgentID: assignedID,
            createdByAgentID: createdByID,
            title: title,
            instructions: instructions,
            status: status,
            waitingOn: waitingOn,
            attemptCount: attempts,
            maxAttempts: maxAttempts,
            hasExternalSideEffect: hasExternal,
            resultSummary: resultSummary,
            errorSummary: errorSummary,
            artifactPaths: artifactPaths,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func decodeSharedStateRow(_ stmt: OpaquePointer) throws -> SharedStateEntry {
        guard
            let idStr = columnText(stmt, index: 0), let id = UUID(uuidString: idStr),
            let projStr = columnText(stmt, index: 1), let projectID = UUID(uuidString: projStr),
            let scopeStr = columnText(stmt, index: 2), let scope = MemoryScope(rawValue: scopeStr),
            let catStr = columnText(stmt, index: 4), let category = SharedStateCategory(rawValue: catStr),
            let key = columnText(stmt, index: 5),
            let title = columnText(stmt, index: 6),
            let content = columnText(stmt, index: 7),
            let trustStr = columnText(stmt, index: 8), let trust = TrustLevel(rawValue: trustStr),
            let provJSON = columnText(stmt, index: 9),
            let sha = columnText(stmt, index: 10)
        else {
            throw HelmDatabaseError.invalidData("Malformed shared_state row")
        }
        let ownerID = columnText(stmt, index: 3).flatMap(UUID.init(uuidString:))
        let provenance = try decodeJSONString(ProvenanceRecord.self, from: provJSON)
        let pinned = sqlite3_column_int64(stmt, 11) != 0
        let accessCount = Int(sqlite3_column_int64(stmt, 12))
        let lastAccessed = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))
        let supersedes = columnText(stmt, index: 14).flatMap(UUID.init(uuidString:))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 15))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 16))
        return SharedStateEntry(
            id: id,
            projectID: projectID,
            scope: scope,
            ownerAgentID: ownerID,
            category: category,
            key: key,
            title: title,
            content: content,
            trustLevel: trust,
            provenance: provenance,
            pinned: pinned,
            accessCount: accessCount,
            lastAccessedAt: lastAccessed,
            createdAt: createdAt,
            updatedAt: updatedAt,
            contentSHA256: sha,
            supersedesEntryID: supersedes
        )
    }

    private func decodeEventRow(_ stmt: OpaquePointer) throws -> RunEvent {
        guard
            let idStr = columnText(stmt, index: 0), let id = UUID(uuidString: idStr),
            let projStr = columnText(stmt, index: 1), let projectID = UUID(uuidString: projStr),
            let kindStr = columnText(stmt, index: 4), let kind = RunEventKind(rawValue: kindStr),
            let summary = columnText(stmt, index: 5),
            let trustStr = columnText(stmt, index: 7), let trust = TrustLevel(rawValue: trustStr)
        else {
            throw HelmDatabaseError.invalidData("Malformed event row")
        }
        let agentID = columnText(stmt, index: 2).flatMap(UUID.init(uuidString:))
        let taskID = columnText(stmt, index: 3).flatMap(UUID.init(uuidString:))
        let payloadJSON = columnText(stmt, index: 6)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        return RunEvent(
            id: id,
            projectID: projectID,
            agentID: agentID,
            taskID: taskID,
            kind: kind,
            summary: summary,
            payloadJSON: payloadJSON,
            trustLevel: trust,
            createdAt: createdAt
        )
    }

    private func decodeExceptionRow(_ stmt: OpaquePointer) throws -> ExceptionAlert {
        guard
            let idStr = columnText(stmt, index: 0), let id = UUID(uuidString: idStr),
            let projStr = columnText(stmt, index: 1), let projectID = UUID(uuidString: projStr),
            let kindStr = columnText(stmt, index: 4), let kind = ExceptionKind(rawValue: kindStr),
            let sevStr = columnText(stmt, index: 5), let severity = ExceptionSeverity(rawValue: sevStr),
            let statusStr = columnText(stmt, index: 6), let status = ExceptionStatus(rawValue: statusStr),
            let dedupKey = columnText(stmt, index: 7),
            let title = columnText(stmt, index: 8),
            let summary = columnText(stmt, index: 9),
            let diag = columnText(stmt, index: 10),
            let optionsJSON = columnText(stmt, index: 11)
        else {
            throw HelmDatabaseError.invalidData("Malformed exception row")
        }
        let taskID = columnText(stmt, index: 2).flatMap(UUID.init(uuidString:))
        let agentID = columnText(stmt, index: 3).flatMap(UUID.init(uuidString:))
        let options = try decodeJSONString([String].self, from: optionsJSON)
        let evidenceJSON = columnText(stmt, index: 12)
        let resolution: ExceptionResolution? = try columnText(stmt, index: 13).map {
            try decodeJSONString(ExceptionResolution.self, from: $0)
        }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14))
        let resolvedAt = columnOptionalDouble(stmt, index: 15).map(Date.init(timeIntervalSince1970:))
        return ExceptionAlert(
            id: id,
            projectID: projectID,
            taskID: taskID,
            agentID: agentID,
            kind: kind,
            severity: severity,
            title: title,
            summary: summary,
            diagnosticSummary: diag,
            suggestedOptions: options,
            evidenceJSON: evidenceJSON,
            dedupKey: dedupKey,
            status: status,
            resolution: resolution,
            createdAt: createdAt,
            resolvedAt: resolvedAt
        )
    }
}
