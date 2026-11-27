import Foundation
import IOKit.pwr_mgt
import os

public final class PowerAssertionGuard: Sendable {
    private struct State: Sendable {
        var activeTokens: Set<UUID> = []
        var assertionID: IOPMAssertionID = 0
    }

    private final class Box: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock(initialState: State())

        deinit {
            let leftoverID = lock.withLock { state -> IOPMAssertionID in
                let id = state.assertionID
                state.assertionID = 0
                state.activeTokens.removeAll()
                return id
            }
            if leftoverID != 0 {
                _ = IOPMAssertionRelease(leftoverID)
            }
        }
    }

    private let box = Box()

    public init() {}

    public var activeCount: Int {
        box.lock.withLock { $0.activeTokens.count }
    }

    public var hasActiveAssertion: Bool {
        box.lock.withLock { $0.assertionID != 0 }
    }

    @discardableResult
    public func acquire(reason: String = "Helm Workspace Sandbox Execution") -> UUID {
        let token = UUID()
        box.lock.withLock { state in
            let wasEmpty = state.activeTokens.isEmpty
            state.activeTokens.insert(token)
            if wasEmpty && state.assertionID == 0 {
                var newID: IOPMAssertionID = 0
                let rc = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason as CFString,
                    &newID
                )
                if rc == kIOReturnSuccess {
                    state.assertionID = newID
                }
            }
        }
        return token
    }

    public func release(_ token: UUID) {
        let idToRelease = box.lock.withLock { state -> IOPMAssertionID in
            guard state.activeTokens.remove(token) != nil else {
                return 0
            }
            if state.activeTokens.isEmpty && state.assertionID != 0 {
                let id = state.assertionID
                state.assertionID = 0
                return id
            }
            return 0
        }
        if idToRelease != 0 {
            _ = IOPMAssertionRelease(idToRelease)
        }
    }

    public func withAssertion<T: Sendable>(
        reason: String = "Helm Workspace Sandbox Execution",
        operation: () async throws -> T
    ) async rethrows -> T {
        let token = acquire(reason: reason)
        do {
            let result = try await operation()
            release(token)
            return result
        } catch {
            release(token)
            throw error
        }
    }
}
