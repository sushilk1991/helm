import Foundation

public enum ChatChannelKind: Codable, Sendable, Equatable, Hashable {
    case crew
    case direct(agentID: UUID)

    public var channelKey: String {
        switch self {
        case .crew:
            return "crew"
        case .direct(let agentID):
            return "agent:\(agentID.uuidString)"
        }
    }

    public init?(channelKey: String) {
        let trimmed = channelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "crew" {
            self = .crew
            return
        }
        if trimmed.hasPrefix("agent:") {
            let uuidPart = String(trimmed.dropFirst("agent:".count))
            if let uuid = UUID(uuidString: uuidPart) {
                self = .direct(agentID: uuid)
                return
            }
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        guard let parsed = ChatChannelKind(channelKey: key) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ChatChannelKind key: \(key)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(channelKey)
    }
}

public enum ChatSenderKind: String, Codable, Sendable, CaseIterable, Hashable {
    case user
    case agent
    case orchestrator
    case system
}

public struct ChatMessage: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let projectID: UUID
    public let channelKey: String
    public let channelKind: ChatChannelKind
    public let senderKind: ChatSenderKind
    public let senderAgentID: UUID?
    public let senderName: String
    public let content: String
    public let referencedFiles: [String]
    public let relatedTaskID: UUID?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        channelKind: ChatChannelKind,
        senderKind: ChatSenderKind,
        senderAgentID: UUID? = nil,
        senderName: String,
        content: String,
        referencedFiles: [String] = [],
        relatedTaskID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.channelKey = channelKind.channelKey
        self.channelKind = channelKind
        self.senderKind = senderKind
        self.senderAgentID = senderAgentID
        self.senderName = senderName
        self.content = content
        self.referencedFiles = referencedFiles
        self.relatedTaskID = relatedTaskID
        self.createdAt = createdAt
    }
}
