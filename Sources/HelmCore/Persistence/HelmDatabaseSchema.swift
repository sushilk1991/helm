import Foundation

public enum HelmDatabaseSchema {
    public static let currentVersion: Int32 = 2

    public static let migrationV2SQL: String = """
    ALTER TABLE agents ADD COLUMN personality TEXT NOT NULL DEFAULT 'pragmaticBuilder';
    ALTER TABLE agents ADD COLUMN personality_notes TEXT NOT NULL DEFAULT '';
    """

    public static let migrationV1SQL: String = """
    CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        goal TEXT NOT NULL,
        workspace_root TEXT NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('idle','running','paused','held','completed','failed')),
        budget_policy_json TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS agents (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        role TEXT NOT NULL,
        goal TEXT NOT NULL,
        capabilities_json TEXT NOT NULL,
        backend_kind TEXT NOT NULL,
        model_override TEXT,
        activity_state TEXT NOT NULL CHECK (activity_state IN ('idle','thinking','browsing','executing','waiting','exception','paused','completed')),
        character_seed_json TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(project_id, name)
    );
    CREATE INDEX IF NOT EXISTS idx_agents_project ON agents(project_id);

    CREATE TABLE IF NOT EXISTS tasks (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        parent_task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
        assigned_agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
        created_by_agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
        title TEXT NOT NULL,
        instructions TEXT NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('queued','running','blocked','needsHuman','done','failed','cancelled','outcomeUnknown')),
        waiting_on_json TEXT NOT NULL DEFAULT '[]',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        max_attempts INTEGER NOT NULL DEFAULT 3,
        has_external_side_effect INTEGER NOT NULL DEFAULT 0,
        result_summary TEXT,
        error_summary TEXT,
        artifact_paths_json TEXT NOT NULL DEFAULT '[]',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        started_at REAL,
        completed_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_tasks_project_status ON tasks(project_id, status);

    CREATE TABLE IF NOT EXISTS shared_state (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        scope TEXT NOT NULL CHECK (scope IN ('agentPrivate','projectShared')),
        owner_agent_id TEXT REFERENCES agents(id) ON DELETE CASCADE,
        category TEXT NOT NULL CHECK (category IN ('rule','fact','decision','artifactRef','continuity','observation')),
        state_key TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        trust_level TEXT NOT NULL CHECK (trust_level IN ('untrustedData','agentGenerated','orchestratorVerified','humanAuthoritative')),
        provenance_json TEXT NOT NULL,
        content_sha256 TEXT NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0,
        access_count INTEGER NOT NULL DEFAULT 0,
        last_accessed_at REAL NOT NULL,
        supersedes_entry_id TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_shared_state_lookup ON shared_state(project_id, scope, state_key);

    CREATE TABLE IF NOT EXISTS events (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE,
        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
        task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
        kind TEXT NOT NULL,
        summary TEXT NOT NULL,
        payload_json TEXT,
        trust_level TEXT NOT NULL CHECK (trust_level IN ('untrustedData','agentGenerated','orchestratorVerified','humanAuthoritative')),
        created_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_events_project_seq ON events(project_id, seq);

    CREATE TABLE IF NOT EXISTS exceptions (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
        agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
        kind TEXT NOT NULL CHECK (kind IN ('stall','loop','drift','budget','humanDecision','coordinatorStalled','providerFailure')),
        severity TEXT NOT NULL CHECK (severity IN ('attention','critical')),
        status TEXT NOT NULL CHECK (status IN ('open','resolved','dismissed')),
        dedup_key TEXT NOT NULL,
        title TEXT NOT NULL,
        summary TEXT NOT NULL,
        diagnostic_summary TEXT NOT NULL,
        suggested_options_json TEXT NOT NULL DEFAULT '[]',
        evidence_json TEXT,
        resolution_json TEXT,
        created_at REAL NOT NULL,
        resolved_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_exceptions_project_status ON exceptions(project_id, status);

    CREATE TABLE IF NOT EXISTS artifacts (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
        task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
        kind TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        mime_type TEXT,
        byte_size INTEGER NOT NULL DEFAULT 0,
        sha256 TEXT NOT NULL,
        created_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_artifacts_project ON artifacts(project_id);

    CREATE TABLE IF NOT EXISTS prompt_channel_digests (
        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
        channel TEXT NOT NULL,
        digest TEXT NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY (project_id, agent_id, channel)
    );
    """
}
