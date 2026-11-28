import Foundation

public enum ProjectStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case paused
    case held
    case completed
    case failed
}

public enum SandboxTrustPolicy: String, Codable, Sendable, CaseIterable, Hashable {
    case sandboxed
    case standardWorkspace
    case trustedFullAccess

    public var displayName: String {
        switch self {
        case .sandboxed:
            return "Sandboxed"
        case .standardWorkspace:
            return "Workspace Direct"
        case .trustedFullAccess:
            return "Trusted Full Access"
        }
    }

    public var summary: String {
        switch self {
        case .sandboxed:
            return "Seatbelt / VM isolation around workspace"
        case .standardWorkspace:
            return "Direct read/write & tools inside project folder"
        case .trustedFullAccess:
            return "Full local tool & command execution for project"
        }
    }
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
    public var sandboxTrustPolicy: SandboxTrustPolicy
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        goal: String,
        workspaceRoot: URL,
        status: ProjectStatus = .idle,
        budgetPolicy: BudgetPolicy = BudgetPolicy(),
        sandboxTrustPolicy: SandboxTrustPolicy = .standardWorkspace,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.goal = goal
        self.workspaceRoot = workspaceRoot
        self.status = status
        self.budgetPolicy = budgetPolicy
        self.sandboxTrustPolicy = sandboxTrustPolicy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, goal, workspaceRoot, status, budgetPolicy, sandboxTrustPolicy, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.goal = try c.decode(String.self, forKey: .goal)
        self.workspaceRoot = try c.decode(URL.self, forKey: .workspaceRoot)
        self.status = try c.decode(ProjectStatus.self, forKey: .status)
        self.budgetPolicy = try c.decode(BudgetPolicy.self, forKey: .budgetPolicy)
        self.sandboxTrustPolicy = try c.decodeIfPresent(SandboxTrustPolicy.self, forKey: .sandboxTrustPolicy)
            ?? .standardWorkspace
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}
