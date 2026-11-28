import Foundation

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case blocked
    case needsHuman
    case done
    case failed
    case cancelled
    case outcomeUnknown
}

public enum DelegatedTaskKind: String, Codable, Sendable, CaseIterable {
    case goal
    case chat
}

public struct DelegatedTask: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let projectID: UUID
    public let parentTaskID: UUID?
    public var assignedAgentID: UUID
    public let createdByAgentID: UUID?
    public var title: String
    public var instructions: String
    public var status: TaskStatus
    public var waitingOn: [UUID]
    public var attemptCount: Int
    public var maxAttempts: Int
    public var hasExternalSideEffect: Bool
    public var resultSummary: String?
    public var errorSummary: String?
    public var artifactPaths: [String]
    public let createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var taskKind: DelegatedTaskKind

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        parentTaskID: UUID? = nil,
        assignedAgentID: UUID,
        createdByAgentID: UUID? = nil,
        title: String,
        instructions: String,
        status: TaskStatus = .queued,
        waitingOn: [UUID] = [],
        attemptCount: Int = 0,
        maxAttempts: Int = 3,
        hasExternalSideEffect: Bool = false,
        resultSummary: String? = nil,
        errorSummary: String? = nil,
        artifactPaths: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        taskKind: DelegatedTaskKind = .goal
    ) {
        self.id = id
        self.projectID = projectID
        self.parentTaskID = parentTaskID
        self.assignedAgentID = assignedAgentID
        self.createdByAgentID = createdByAgentID
        self.title = title
        self.instructions = instructions
        self.status = status
        self.waitingOn = waitingOn
        self.attemptCount = attemptCount
        self.maxAttempts = maxAttempts
        self.hasExternalSideEffect = hasExternalSideEffect
        self.resultSummary = resultSummary
        self.errorSummary = errorSummary
        self.artifactPaths = artifactPaths
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.taskKind = taskKind
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, parentTaskID, assignedAgentID, createdByAgentID
        case title, instructions, status, waitingOn, attemptCount, maxAttempts
        case hasExternalSideEffect, resultSummary, errorSummary, artifactPaths
        case createdAt, updatedAt, startedAt, completedAt, taskKind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.projectID = try c.decode(UUID.self, forKey: .projectID)
        self.parentTaskID = try c.decodeIfPresent(UUID.self, forKey: .parentTaskID)
        self.assignedAgentID = try c.decode(UUID.self, forKey: .assignedAgentID)
        self.createdByAgentID = try c.decodeIfPresent(UUID.self, forKey: .createdByAgentID)
        self.title = try c.decode(String.self, forKey: .title)
        self.instructions = try c.decode(String.self, forKey: .instructions)
        self.status = try c.decode(TaskStatus.self, forKey: .status)
        self.waitingOn = try c.decode([UUID].self, forKey: .waitingOn)
        self.attemptCount = try c.decode(Int.self, forKey: .attemptCount)
        self.maxAttempts = try c.decode(Int.self, forKey: .maxAttempts)
        self.hasExternalSideEffect = try c.decode(Bool.self, forKey: .hasExternalSideEffect)
        self.resultSummary = try c.decodeIfPresent(String.self, forKey: .resultSummary)
        self.errorSummary = try c.decodeIfPresent(String.self, forKey: .errorSummary)
        self.artifactPaths = try c.decode([String].self, forKey: .artifactPaths)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        self.completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        self.taskKind = try c.decodeIfPresent(DelegatedTaskKind.self, forKey: .taskKind) ?? .goal
    }
}
