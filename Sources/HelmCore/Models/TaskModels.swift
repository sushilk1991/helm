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
        completedAt: Date? = nil
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
    }
}
