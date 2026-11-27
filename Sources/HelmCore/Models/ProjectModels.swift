import Foundation

public enum ProjectStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case paused
    case held
    case completed
    case failed
}

public struct BudgetPolicy: Codable, Sendable, Equatable, Hashable {
    public var maxStepsPerRun: Int
    public var stepTimeoutSeconds: TimeInterval
    public var maxConsecutiveToolFailures: Int
    public var coordinatorStallSeconds: TimeInterval
    public var minFreeDiskMB: Int
    public var memoryCharBudget: Int

    public init(
        maxStepsPerRun: Int = 50,
        stepTimeoutSeconds: TimeInterval = 120,
        maxConsecutiveToolFailures: Int = 3,
        coordinatorStallSeconds: TimeInterval = 180,
        minFreeDiskMB: Int = 500,
        memoryCharBudget: Int = 4_000
    ) {
        self.maxStepsPerRun = maxStepsPerRun
        self.stepTimeoutSeconds = stepTimeoutSeconds
        self.maxConsecutiveToolFailures = maxConsecutiveToolFailures
        self.coordinatorStallSeconds = coordinatorStallSeconds
        self.minFreeDiskMB = minFreeDiskMB
        self.memoryCharBudget = memoryCharBudget
    }
}

public struct Project: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public var goal: String
    public var workspaceRoot: URL
    public var status: ProjectStatus
    public var budgetPolicy: BudgetPolicy
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        goal: String,
        workspaceRoot: URL,
        status: ProjectStatus = .idle,
        budgetPolicy: BudgetPolicy = BudgetPolicy(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.goal = goal
        self.workspaceRoot = workspaceRoot
        self.status = status
        self.budgetPolicy = budgetPolicy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
