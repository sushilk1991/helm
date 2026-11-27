import Foundation

public struct HumanDecisionGate: Sendable {
    private let database: HelmDatabase

    public init(database: HelmDatabase) {
        self.database = database
    }

    @discardableResult
    public func triggerHold(alert: ExceptionAlert) async throws -> ExceptionAlert {
        try await database.triggerDurableHold(alert: alert)
    }

    @discardableResult
    public func resolve(exceptionID: UUID, resolution: ExceptionResolution) async throws -> ExceptionAlert {
        try await database.resolveDurableException(id: exceptionID, resolution: resolution)
    }
}
