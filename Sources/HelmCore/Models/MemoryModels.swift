import CryptoKit
import Foundation

public enum TrustLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case untrustedData
    case agentGenerated
    case orchestratorVerified
    case humanAuthoritative

    private var rank: Int {
        switch self {
        case .untrustedData: return 0
        case .agentGenerated: return 1
        case .orchestratorVerified: return 2
        case .humanAuthoritative: return 3
        }
    }

    public static func < (lhs: TrustLevel, rhs: TrustLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum MemoryScope: String, Codable, Sendable, CaseIterable {
    case agentPrivate
    case projectShared
}

public enum SharedStateCategory: String, Codable, Sendable, CaseIterable {
    case rule
    case fact
    case decision
    case artifactRef
    case continuity
    case observation
}

public enum ProvenanceSource: String, Codable, Sendable, CaseIterable {
    case humanOwner
    case orchestrator
    case workerAgent
    case browserObservation
    case ocrResult
    case sandboxOutput
    case externalWeb
}

public struct ProvenanceRecord: Codable, Sendable, Equatable, Hashable {
    public let source: ProvenanceSource
    public let authorAgentID: UUID?
    public let sourceEventID: UUID?
    public let sourceURI: String?

    public init(
        source: ProvenanceSource,
        authorAgentID: UUID? = nil,
        sourceEventID: UUID? = nil,
        sourceURI: String? = nil
    ) {
        self.source = source
        self.authorAgentID = authorAgentID
        self.sourceEventID = sourceEventID
        self.sourceURI = sourceURI
    }
}

public struct SharedStateEntry: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let projectID: UUID
    public let scope: MemoryScope
    public let ownerAgentID: UUID?
    public let category: SharedStateCategory
    public let key: String
    public var title: String
    public var content: String
    public let trustLevel: TrustLevel
    public let provenance: ProvenanceRecord
    public var pinned: Bool
    public var accessCount: Int
    public var lastAccessedAt: Date
    public let createdAt: Date
    public var updatedAt: Date
    public var contentSHA256: String
    public var supersedesEntryID: UUID?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        scope: MemoryScope,
        ownerAgentID: UUID? = nil,
        category: SharedStateCategory,
        key: String,
        title: String,
        content: String,
        trustLevel: TrustLevel,
        provenance: ProvenanceRecord,
        pinned: Bool = false,
        accessCount: Int = 0,
        lastAccessedAt: Date = Date(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        contentSHA256: String? = nil,
        supersedesEntryID: UUID? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.scope = scope
        self.ownerAgentID = ownerAgentID
        self.category = category
        self.key = key
        self.title = title
        self.content = content
        self.trustLevel = trustLevel
        self.provenance = provenance
        self.pinned = pinned
        self.accessCount = accessCount
        self.lastAccessedAt = lastAccessedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.contentSHA256 = contentSHA256 ?? Self.sha256Hex(key: key, title: title, content: content)
        self.supersedesEntryID = supersedesEntryID
    }

    public static func sha256Hex(key: String, title: String, content: String) -> String {
        let payload = "\(key)\n\(title)\n\(content)"
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct ArtifactRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let projectID: UUID
    public let agentID: UUID?
    public let taskID: UUID?
    public let kind: String
    public let relativePath: String
    public let mimeType: String?
    public let byteSize: Int64
    public let sha256: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        agentID: UUID? = nil,
        taskID: UUID? = nil,
        kind: String,
        relativePath: String,
        mimeType: String? = nil,
        byteSize: Int64 = 0,
        sha256: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.agentID = agentID
        self.taskID = taskID
        self.kind = kind
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.sha256 = sha256
        self.createdAt = createdAt
    }
}
