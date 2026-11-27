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
    case directHTTP = "http"
    case foundationModels = "foundation"

    public static func parse(_ raw: String) -> LLMBackendKind? {
        let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch norm {
        case "mock": return .mock
        case "claude", "claudecli", "claude_cli": return .claudeCLI
        case "codex", "codexcli", "codex_cli": return .codexCLI
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
    public let id: UUID
    public let projectID: UUID
    public var name: String
    public var role: AgentRole
    public var goal: String
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
        capabilities: Set<AgentCapability> = [.readSharedState, .proposeSharedState, .requestHumanDecision],
        backend: LLMBackendKind = .claudeCLI,
        modelOverride: String? = nil,
        activityState: AgentActivityState = .idle,
        characterSeed: AgentCharacterSeed? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.role = role
        self.goal = goal
        self.capabilities = capabilities
        self.backend = backend
        self.modelOverride = modelOverride
        self.activityState = activityState
        self.characterSeed = characterSeed ?? AgentCharacterSeed(agentID: id, isOrchestrator: role == .orchestrator)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
