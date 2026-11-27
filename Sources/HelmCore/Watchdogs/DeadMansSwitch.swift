import Foundation
import os

public final class HeartbeatStamp: @unchecked Sendable {
    private struct State: Sendable {
        var lastBeatAt: Date
        var isActive: Bool
        var stallThreshold: TimeInterval
    }

    private let lock: OSAllocatedUnfairLock<State>

    public init(stallThreshold: TimeInterval = 30.0) {
        self.lock = OSAllocatedUnfairLock(initialState: State(
            lastBeatAt: Date(),
            isActive: false,
            stallThreshold: stallThreshold
        ))
    }

    public func arm(stallThreshold: TimeInterval? = nil) {
        lock.withLock { state in
            if let stallThreshold {
                state.stallThreshold = stallThreshold
            }
            state.lastBeatAt = Date()
            state.isActive = true
        }
    }

    public func beat() {
        lock.withLock { state in
            state.lastBeatAt = Date()
        }
    }

    public func disarm() {
        lock.withLock { state in
            state.isActive = false
        }
    }

    /// Atomically checks if stalled; if stalled, disarms once and returns true so the alert fires once.
    public func checkAndTripIfStalled(now: Date = Date()) -> Bool {
        lock.withLock { state in
            guard state.isActive else { return false }
            if now.timeIntervalSince(state.lastBeatAt) > state.stallThreshold {
                state.isActive = false
                return true
            }
            return false
        }
    }
}

public final class DeadMansSwitch: @unchecked Sendable {
    public let projectID: UUID
    public let stamp: HeartbeatStamp
    private let database: HelmDatabase
    private let queue = DispatchQueue(label: "com.helm.watchdog.deadmansswitch", qos: .utility)
    private let timerLock = OSAllocatedUnfairLock<DispatchSourceTimer?>(initialState: nil)
    private let onTriggered: (@Sendable (ExceptionAlert) async -> Void)?

    public init(
        projectID: UUID,
        database: HelmDatabase,
        stallThreshold: TimeInterval = 30.0,
        onTriggered: (@Sendable (ExceptionAlert) async -> Void)? = nil
    ) {
        self.projectID = projectID
        self.database = database
        self.stamp = HeartbeatStamp(stallThreshold: stallThreshold)
        self.onTriggered = onTriggered
    }

    public func start(checkInterval: TimeInterval = 0.25, stallThreshold: TimeInterval? = nil) {
        stop()
        stamp.arm(stallThreshold: stallThreshold)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let intervalMs = max(10, Int(checkInterval * 1000))
        timer.schedule(deadline: .now() + .milliseconds(intervalMs), repeating: .milliseconds(intervalMs))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timerLock.withLock { $0 = timer }
        timer.resume()
    }

    public func beat() {
        stamp.beat()
    }

    public func stop() {
        stamp.disarm()
        let existing = timerLock.withLock { current -> DispatchSourceTimer? in
            let prev = current
            current = nil
            return prev
        }
        existing?.cancel()
    }

    private func tick() {
        guard stamp.checkAndTripIfStalled() else { return }
        let projectID = self.projectID
        let database = self.database
        let onTriggered = self.onTriggered
        Task {
            let gate = HumanDecisionGate(database: database)
            let alert = ExceptionAlert(
                projectID: projectID,
                kind: .coordinatorStalled,
                severity: .critical,
                title: "Coordinator Dead-Man's Switch Triggered",
                summary: "Orchestrator heartbeat ceased beyond configured stall threshold.",
                suggestedOptions: ["retry", "abort"],
                dedupKey: "coordinator_stalled:\(projectID.uuidString)"
            )
            if let persisted = try? await gate.triggerHold(alert: alert) {
                await onTriggered?(persisted)
            }
        }
    }

    deinit {
        stop()
    }
}
