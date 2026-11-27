import Foundation

public enum ExceptionKind: String, Codable, Sendable, CaseIterable {
    case stall
    case loop
    case drift
    case budget
    case humanDecision
    case coordinatorStalled
    case providerFailure
}

public enum ExceptionSeverity: String, Codable, Sendable, CaseIterable {
    case attention
    case critical
}

public enum ExceptionStatus: String, Codable, Sendable, CaseIterable {
    case open
    case resolved
    case dismissed
}

public enum ExceptionResolution: Codable, Sendable, Equatable, Hashable {
    case approve
    case redirect(note: String)
    case retry
    case abort

    public var actionName: String {
        switch self {
        case .approve: return "approve"
        case .redirect: return "redirect"
        case .retry: return "retry"
        case .abort: return "abort"
        }
    }

    public var note: String? {
        if case let .redirect(note) = self { return note }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(String.self, forKey: .action)
        let note = try container.decodeIfPresent(String.self, forKey: .note)
        switch action.lowercased() {
        case "approve":
            self = .approve
        case "redirect":
            self = .redirect(note: note ?? "")
        case "retry":
            self = .retry
        case "abort":
            self = .abort
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: "Unknown exception resolution action: \(action)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actionName, forKey: .action)
        if let note {
            try container.encode(note, forKey: .note)
        }
    }
}

public struct ExceptionAlert: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let projectID: UUID
    public let taskID: UUID?
    public let agentID: UUID?
    public let kind: ExceptionKind
    public let severity: ExceptionSeverity
    public let title: String
    public let summary: String
    public let diagnosticSummary: String
    public let suggestedOptions: [String]
    public let evidenceJSON: String?
    public let dedupKey: String
    public var status: ExceptionStatus
    public var resolution: ExceptionResolution?
    public let createdAt: Date
    public var resolvedAt: Date?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        taskID: UUID? = nil,
        agentID: UUID? = nil,
        kind: ExceptionKind,
        severity: ExceptionSeverity = .attention,
        title: String,
        summary: String? = nil,
        diagnosticSummary: String? = nil,
        suggestedOptions: [String] = ["approve", "retry", "redirect", "abort"],
        evidenceJSON: String? = nil,
        dedupKey: String,
        status: ExceptionStatus = .open,
        resolution: ExceptionResolution? = nil,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        let resolvedSummary = summary ?? diagnosticSummary ?? title
        let resolvedDiag = diagnosticSummary ?? summary ?? title
        self.id = id
        self.projectID = projectID
        self.taskID = taskID
        self.agentID = agentID
        self.kind = kind
        self.severity = severity
        self.title = title
        self.summary = resolvedSummary
        self.diagnosticSummary = resolvedDiag
        self.suggestedOptions = suggestedOptions
        self.evidenceJSON = evidenceJSON
        self.dedupKey = dedupKey
        self.status = status
        self.resolution = resolution
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

public enum RunEventKind: String, Codable, Sendable, CaseIterable {
    case projectCreated
    case projectStarted
    case projectPaused
    case projectHeld
    case projectCompleted
    case agentAdded
    case agentStateChanged
    case taskCreated
    case taskDelegated
    case taskCompleted
    case taskSelfCorrected
    case taskFailed
    case sharedStateWritten
    case sharedStateRejected
    case heartbeatSteadyOK
    case toolExecuted
    case exceptionRaised
    case exceptionResolved
    case recoveryReconciled
}

public struct RunEvent: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let projectID: UUID
    public let agentID: UUID?
    public let taskID: UUID?
    public let kind: RunEventKind
    public let summary: String
    public let payloadJSON: String?
    public let trustLevel: TrustLevel
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        agentID: UUID? = nil,
        taskID: UUID? = nil,
        kind: RunEventKind,
        summary: String,
        payloadJSON: String? = nil,
        trustLevel: TrustLevel = .orchestratorVerified,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.agentID = agentID
        self.taskID = taskID
        self.kind = kind
        self.summary = summary
        self.payloadJSON = payloadJSON
        self.trustLevel = trustLevel
        self.createdAt = createdAt
    }
}

public enum SimulatedConditionKind: String, Codable, Sendable, CaseIterable {
    case stall
    case drift
    case humanDecision
    case cycle
}

public enum RunOutcomeStatus: String, Codable, Sendable, CaseIterable {
    case completed
    case held
    case failed
    case maxStepsReached
}

public struct RunTaskSummary: Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let title: String
    public let assignedAgentID: UUID
    public let status: TaskStatus
    public let waitingOn: [UUID]
    public let resultSummary: String?

    public init(
        id: UUID,
        title: String,
        assignedAgentID: UUID,
        status: TaskStatus,
        waitingOn: [UUID],
        resultSummary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.assignedAgentID = assignedAgentID
        self.status = status
        self.waitingOn = waitingOn
        self.resultSummary = resultSummary
    }
}

public struct RunSharedStateSummary: Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let key: String
    public let title: String
    public let value: String
    public let content: String
    public let trustLevel: TrustLevel
    public let digest: String
    public let scope: MemoryScope
    public let category: SharedStateCategory
    public let pinned: Bool

    public init(from entry: SharedStateEntry) {
        self.id = entry.id
        self.key = entry.key
        self.title = entry.title
        self.value = entry.content
        self.content = entry.content
        self.trustLevel = entry.trustLevel
        self.digest = entry.contentSHA256
        self.scope = entry.scope
        self.category = entry.category
        self.pinned = entry.pinned
    }
}

public struct ProjectRunReport: Codable, Sendable, Equatable {
    public let projectID: UUID
    public let status: RunOutcomeStatus
    public let stepsExecuted: Int
    public let steadyHeartbeats: Int
    public let notificationsEmitted: Int
    public let alertsSurfaced: Int
    public let tasks: [RunTaskSummary]
    public let sharedState: [RunSharedStateSummary]
    public let exceptions: [ExceptionAlert]
    public let artifacts: [ArtifactRecord]
    public let eventsEmitted: Int

    public init(
        projectID: UUID,
        status: RunOutcomeStatus,
        stepsExecuted: Int,
        steadyHeartbeats: Int,
        notificationsEmitted: Int,
        alertsSurfaced: Int,
        tasks: [RunTaskSummary],
        sharedState: [RunSharedStateSummary],
        exceptions: [ExceptionAlert],
        artifacts: [ArtifactRecord],
        eventsEmitted: Int
    ) {
        self.projectID = projectID
        self.status = status
        self.stepsExecuted = stepsExecuted
        self.steadyHeartbeats = steadyHeartbeats
        self.notificationsEmitted = notificationsEmitted
        self.alertsSurfaced = alertsSurfaced
        self.tasks = tasks
        self.sharedState = sharedState
        self.exceptions = exceptions
        self.artifacts = artifacts
        self.eventsEmitted = eventsEmitted
    }
}
