import CryptoKit
import Foundation

public enum AgentRole: String, Codable, Sendable, CaseIterable {
    case orchestrator
    case researcher
    case coder
    case browserAnalyst = "browser_analyst"
    case qaVerifier = "qa_verifier"
    case specialist

    public static func parse(_ raw: String) -> AgentRole {
        let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch norm {
        case "orchestrator": return .orchestrator
        case "researcher": return .researcher
        case "coder", "builder": return .coder
        case "browser_analyst", "browseranalyst", "browser": return .browserAnalyst
        case "qa_verifier", "qaverifier", "qa", "verifier": return .qaVerifier
        default: return .specialist
        }
    }
}

public enum AgentPersonality: String, Codable, Sendable, CaseIterable, Hashable {
    case calmCommander
    case pragmaticBuilder
    case methodicalArchitect
    case adversarialReviewer
    case creativeExplorer
    case rapidOperator

    public static func defaultForRole(_ role: AgentRole) -> AgentPersonality {
        switch role {
        case .orchestrator: return .calmCommander
        case .coder: return .pragmaticBuilder
        case .researcher: return .methodicalArchitect
        case .qaVerifier: return .adversarialReviewer
        case .browserAnalyst: return .rapidOperator
        case .specialist: return .creativeExplorer
        }
    }

    public var displayName: String {
        switch self {
        case .calmCommander: return "Calm Commander"
        case .pragmaticBuilder: return "Pragmatic Builder"
        case .methodicalArchitect: return "Methodical Architect"
        case .adversarialReviewer: return "Adversarial Reviewer"
        case .creativeExplorer: return "Creative Explorer"
        case .rapidOperator: return "Rapid Operator"
        }
    }

    public var tagline: String {
        switch self {
        case .calmCommander: return "Concise coordinator; delegates cleanly and escalates only real blockers."
        case .pragmaticBuilder: return "Direct and execution-focused; favors minimal, working, tested changes."
        case .methodicalArchitect: return "Thinks from first principles; verifies edge cases and invariants before acting."
        case .adversarialReviewer: return "Skeptical verifier; hunts subtle bugs, regressions, and weak assumptions."
        case .creativeExplorer: return "Explores novel angles, prototypes fresh ideas, and surfaces alternatives."
        case .rapidOperator: return "Action-first and crisp; optimizes for fast web/tool turnaround."
        }
    }

    public var promptDirective: String {
        switch self {
        case .calmCommander:
            return "Operate as a calm, decisive lead. Decompose work cleanly, keep status concise, self-correct routine friction, and interrupt the human only for genuine blockers or irreversible decisions."
        case .pragmaticBuilder:
            return "Operate as a pragmatic builder. Favor lean, clean, working implementations verified by real execution rather than speculation or over-engineering."
        case .methodicalArchitect:
            return "Operate as a methodical architect. Analyze requirements and constraints from first principles, cite verified evidence, and check edge cases before committing to an approach."
        case .adversarialReviewer:
            return "Operate as an adversarial reviewer. Question assumptions, look for failure modes, boundary bugs, and security/reliability gaps, and require empirical proof."
        case .creativeExplorer:
            return "Operate as a creative explorer. Generate distinct high-leverage ideas, challenge stale defaults, and present clear trade-offs."
        case .rapidOperator:
            return "Operate as a rapid operator. Execute targeted checks and web/tool actions efficiently with tight latency and crisp summaries."
        }
    }

    public static func parse(_ raw: String) -> AgentPersonality? {
        let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch norm {
        case "calmcommander", "calm", "commander", "lead": return .calmCommander
        case "pragmaticbuilder", "pragmatic", "builder": return .pragmaticBuilder
        case "methodicalarchitect", "methodical", "architect": return .methodicalArchitect
        case "adversarialreviewer", "adversarial", "skeptical", "reviewer": return .adversarialReviewer
        case "creativeexplorer", "creative", "explorer": return .creativeExplorer
        case "rapidoperator", "rapid", "fast", "operator": return .rapidOperator
        default: return nil
        }
    }
}

public enum AgentCapability: String, Codable, Sendable, Hashable, CaseIterable {
    case codeExec
    case browser
    case ocr
    case readSharedState
    case proposeSharedState
    case delegateTasks
    case requestHumanDecision

    public static func parse(_ raw: String) -> AgentCapability? {
        let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch norm {
        case "codeexec", "code_exec", "code": return .codeExec
        case "browser": return .browser
        case "ocr": return .ocr
        case "readsharedstate", "read_shared_state": return .readSharedState
        case "proposesharedstate", "propose_shared_state": return .proposeSharedState
        case "delegatetasks", "delegate_tasks": return .delegateTasks
        case "requesthumandecision", "request_human_decision": return .requestHumanDecision
        default: return nil
        }
    }
}

public enum AgentActivityState: String, Codable, Sendable, CaseIterable {
    case idle
    case thinking
    case browsing
    case executing
    case waiting
    case exception
    case paused
    case completed
}

public enum LLMBackendKind: String, Codable, Sendable, CaseIterable {
    case mock
    case claudeCLI = "claude"
    case codexCLI = "codex"
    case agyCLI = "agy"
    case piCLI = "pi"
    case directHTTP = "http"
    case foundationModels = "foundation"

    public static func parse(_ raw: String) -> LLMBackendKind? {
        let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch norm {
        case "mock": return .mock
        case "claude", "claudecli", "claude_cli": return .claudeCLI
        case "codex", "codexcli", "codex_cli": return .codexCLI
        case "agy", "agycli", "agy_cli", "antigravity": return .agyCLI
        case "pi", "picli", "pi_cli", "pycli", "py_cli", "pyagent", "piagent": return .piCLI
        case "http", "directhttp", "direct_http": return .directHTTP
        case "foundation", "foundationmodels", "foundation_models": return .foundationModels
        default: return nil
        }
    }
}

public struct AgentCharacterSeed: Codable, Sendable, Equatable, Hashable {
    public let agentID: UUID
    public let isOrchestrator: Bool
    public let hexDigest: String
    /// 0..<8 for worker silhouettes/crowns; Orchestrator renders dedicated Compass Crest.
    public let crownIndex: Int
    /// 0..<6 eye/visor glyph index
    public let eyeIndex: Int
    /// 15-bit symmetric 3x5 left+center body mask (cols 0..2 mirrored across col 2 to 5x5)
    public let bodyMask: UInt16
    /// 0..<6 Harbor Chartroom hue index
    public let hueIndex: Int

    public init(agentID: UUID, isOrchestrator: Bool) {
        self.agentID = agentID
        self.isOrchestrator = isOrchestrator
        let digest = Array(SHA256.hash(data: Data(agentID.uuidString.utf8)))
        self.hexDigest = digest.map { String(format: "%02x", $0) }.joined()
        self.crownIndex = Int(digest[0] % 8)
        self.eyeIndex = Int(digest[1] % 6)
        let rawMask = ((UInt16(digest[2]) << 8) | UInt16(digest[3])) & 0x7FFF
        self.bodyMask = (rawMask & 0x7FFF) == 0 ? 0x0420 : rawMask
        self.hueIndex = Int(digest[4] % 6)
    }

    public func isBodyPixelFilled(row: Int, col: Int) -> Bool {
        guard (0..<5).contains(row), (0..<5).contains(col) else { return false }
        let mirroredCol = col <= 2 ? col : (4 - col)
        let bitIndex = row * 3 + mirroredCol
        return (bodyMask & (UInt16(1) << bitIndex)) != 0
    }
}

public struct AgentProfile: Codable, Sendable, Identifiable, Equatable, Hashable {
    public struct RolePreset: Sendable, Identifiable, Hashable {
        public var id: String { role.rawValue }
        public let role: AgentRole
        public let name: String
        public let goal: String
        public let defaultPersonality: AgentPersonality
        public let capabilities: Set<AgentCapability>

        public init(
            role: AgentRole,
            name: String,
            goal: String,
            defaultPersonality: AgentPersonality,
            capabilities: Set<AgentCapability>
        ) {
            self.role = role
            self.name = name
            self.goal = goal
            self.defaultPersonality = defaultPersonality
            self.capabilities = capabilities
        }

        public static let orchestrator = RolePreset(
            role: .orchestrator,
            name: "Helm Orchestrator",
            goal: "Coordinate the project crew, decompose tasks, track shared state, and drive work to completion.",
            defaultPersonality: .calmCommander,
            capabilities: [.readSharedState, .proposeSharedState, .delegateTasks]
        )

        public static let coder = RolePreset(
            role: .coder,
            name: "Forge Coder",
            goal: "Implement, edit, and verify project files and tests directly inside the project folder.",
            defaultPersonality: .pragmaticBuilder,
            capabilities: [.codeExec, .readSharedState, .proposeSharedState]
        )

        public static let researcher = RolePreset(
            role: .researcher,
            name: "Chart Researcher",
            goal: "Inspect project files and specifications, synthesize findings into shared state, and verify facts.",
            defaultPersonality: .methodicalArchitect,
            capabilities: [.readSharedState, .proposeSharedState]
        )

        public static let browserAnalyst = RolePreset(
            role: .browserAnalyst,
            name: "Lookout Browser",
            goal: "Navigate web targets headlessly, extract OCR/DOM observations, and report findings.",
            defaultPersonality: .rapidOperator,
            capabilities: [.browser, .ocr, .readSharedState, .proposeSharedState]
        )

        public static let qaVerifier = RolePreset(
            role: .qaVerifier,
            name: "Harbor Verifier",
            goal: "Independently run build, test, and verification checks against the project folder and confirm acceptance criteria.",
            defaultPersonality: .adversarialReviewer,
            capabilities: [.codeExec, .browser, .ocr, .readSharedState, .proposeSharedState]
        )

        public static let specialist = RolePreset(
            role: .specialist,
            name: "Harbor Specialist",
            goal: "Execute domain-specific tasks autonomously using the project folder and shared state.",
            defaultPersonality: .creativeExplorer,
            capabilities: [.readSharedState, .proposeSharedState]
        )

        public static let allPresets: [RolePreset] = [
            .orchestrator,
            .coder,
            .researcher,
            .browserAnalyst,
            .qaVerifier,
            .specialist,
        ]

        public static func preset(for role: AgentRole) -> RolePreset {
            switch role {
            case .orchestrator: return .orchestrator
            case .coder: return .coder
            case .researcher: return .researcher
            case .browserAnalyst: return .browserAnalyst
            case .qaVerifier: return .qaVerifier
            case .specialist: return .specialist
            }
        }

        public func buildSystemPrompt(
            personality: AgentPersonality? = nil,
            notes: String = ""
        ) -> String {
            AgentProfile.buildSystemPromptTemplate(
                role: role,
                personality: personality ?? defaultPersonality,
                goal: goal,
                notes: notes
            )
        }
    }

    public let id: UUID
    public let projectID: UUID
    public var name: String
    public var role: AgentRole
    public var goal: String
    public var personality: AgentPersonality
    public var personalityNotes: String
    public var systemPrompt: String
    public var capabilities: Set<AgentCapability>
    public var backend: LLMBackendKind
    public var modelOverride: String?
    public var activityState: AgentActivityState
    public let characterSeed: AgentCharacterSeed
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        name: String,
        role: AgentRole,
        goal: String,
        personality: AgentPersonality? = nil,
        personalityNotes: String = "",
        systemPrompt: String? = nil,
        capabilities: Set<AgentCapability> = [.readSharedState, .proposeSharedState],
        backend: LLMBackendKind = .claudeCLI,
        modelOverride: String? = nil,
        activityState: AgentActivityState = .idle,
        characterSeed: AgentCharacterSeed? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        let resolvedPersonality = personality ?? AgentPersonality.defaultForRole(role)
        let trimmedSystemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.projectID = projectID
        self.name = name
        self.role = role
        self.goal = goal
        self.personality = resolvedPersonality
        self.personalityNotes = personalityNotes
        self.systemPrompt = (trimmedSystemPrompt?.isEmpty == false)
            ? trimmedSystemPrompt!
            : Self.buildSystemPromptTemplate(
                role: role,
                personality: resolvedPersonality,
                goal: goal,
                notes: personalityNotes
            )
        self.capabilities = capabilities
        self.backend = backend
        self.modelOverride = modelOverride
        self.activityState = activityState
        self.characterSeed = characterSeed ?? AgentCharacterSeed(agentID: id, isOrchestrator: role == .orchestrator)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func buildSystemPromptTemplate(
        role: AgentRole,
        personality: AgentPersonality,
        goal: String,
        notes: String = ""
    ) -> String {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = [
            "Role: \(role.rawValue)",
            "Style (\(personality.displayName)): \(personality.promptDirective)",
            "Mission: \(trimmedGoal.isEmpty ? RolePreset.preset(for: role).goal : trimmedGoal)",
            "Autonomy: Work directly from the attached project folder and available tools. Inspect files, run checks, and complete tasks end-to-end without pausing for routine clarifications.",
        ]
        if !trimmedNotes.isEmpty {
            lines.append("Operator Notes: \(trimmedNotes)")
        }
        return lines.joined(separator: "\n")
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, name, role, goal, personality, personalityNotes, systemPrompt
        case capabilities, backend, modelOverride, activityState, characterSeed, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        let role = try c.decode(AgentRole.self, forKey: .role)
        let goal = try c.decode(String.self, forKey: .goal)
        let personality = try c.decodeIfPresent(AgentPersonality.self, forKey: .personality)
            ?? AgentPersonality.defaultForRole(role)
        let personalityNotes = try c.decodeIfPresent(String.self, forKey: .personalityNotes) ?? ""
        let decodedPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.projectID = try c.decode(UUID.self, forKey: .projectID)
        self.name = try c.decode(String.self, forKey: .name)
        self.role = role
        self.goal = goal
        self.personality = personality
        self.personalityNotes = personalityNotes
        self.systemPrompt = (decodedPrompt?.isEmpty == false)
            ? decodedPrompt!
            : Self.buildSystemPromptTemplate(
                role: role,
                personality: personality,
                goal: goal,
                notes: personalityNotes
            )
        self.capabilities = try c.decode(Set<AgentCapability>.self, forKey: .capabilities)
        self.backend = try c.decode(LLMBackendKind.self, forKey: .backend)
        self.modelOverride = try c.decodeIfPresent(String.self, forKey: .modelOverride)
        self.activityState = try c.decode(AgentActivityState.self, forKey: .activityState)
        self.characterSeed = try c.decodeIfPresent(AgentCharacterSeed.self, forKey: .characterSeed)
            ?? AgentCharacterSeed(agentID: id, isOrchestrator: role == .orchestrator)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

public typealias AgentRoleTemplate = AgentProfile.RolePreset
