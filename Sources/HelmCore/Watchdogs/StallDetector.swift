import CryptoKit
import Foundation

public struct ToolFailureSignature: Hashable, Sendable {
    public let agentID: UUID
    public let toolName: String
    public let argsHash: String
    public let errorHash: String

    public init(agentID: UUID, toolName: String, argumentsJSON: String, errorMessage: String) {
        self.agentID = agentID
        self.toolName = toolName
        self.argsHash = Self.sha256Hex(argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines))
        self.errorHash = Self.sha256Hex(errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public actor StallDetector {
    private struct FailureStreak: Sendable {
        var signature: ToolFailureSignature
        var count: Int
    }

    private var streaksByAgent: [UUID: FailureStreak] = [:]

    public init() {}

    public func recordToolFailure(
        agentID: UUID,
        toolName: String,
        argumentsJSON: String,
        errorMessage: String,
        policy: BudgetPolicy
    ) -> (triggeredKind: ExceptionKind?, count: Int) {
        let sig = ToolFailureSignature(
            agentID: agentID,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            errorMessage: errorMessage
        )
        if let current = streaksByAgent[agentID], current.signature == sig {
            let nextCount = current.count + 1
            streaksByAgent[agentID] = FailureStreak(signature: sig, count: nextCount)
            if nextCount >= max(1, policy.maxConsecutiveToolFailures) {
                return (.loop, nextCount)
            }
            return (nil, nextCount)
        } else {
            streaksByAgent[agentID] = FailureStreak(signature: sig, count: 1)
            if policy.maxConsecutiveToolFailures <= 1 {
                return (.loop, 1)
            }
            return (nil, 1)
        }
    }

    public func recordToolSuccess(agentID: UUID) {
        streaksByAgent.removeValue(forKey: agentID)
    }

    public func resetAll() {
        streaksByAgent.removeAll()
    }

    public func currentStreakCount(for agentID: UUID) -> Int {
        streaksByAgent[agentID]?.count ?? 0
    }

    public nonisolated func checkStepTimeout(elapsed: TimeInterval, policy: BudgetPolicy) -> ExceptionKind? {
        elapsed > policy.stepTimeoutSeconds ? .stall : nil
    }

    public nonisolated func checkStepBudget(totalSteps: Int, maxStepsOverride: Int? = nil, policy: BudgetPolicy) -> ExceptionKind? {
        let limit = maxStepsOverride ?? policy.maxStepsPerRun
        return totalSteps > limit ? .stall : nil
    }
}
