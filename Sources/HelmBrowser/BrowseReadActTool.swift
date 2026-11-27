import CoreGraphics
import Foundation
import HelmCore
import os

public struct BrowserActionReport: Codable, Sendable, Equatable {
    public let observation: BrowserObservation
    public let passkeyRejected: Bool
    public let evalResult: String?

    public init(
        observation: BrowserObservation,
        passkeyRejected: Bool,
        evalResult: String? = nil
    ) {
        self.observation = observation
        self.passkeyRejected = passkeyRejected
        self.evalResult = evalResult
    }

    public func toCLIOutput() -> BrowserObservationCLIOutput {
        BrowserObservationCLIOutput(
            url: observation.url,
            title: observation.title,
            viewportSize: observation.viewportSize,
            screenshotPNGPath: observation.screenshotPNGPath.path,
            ocrLines: observation.ocrLines,
            domElements: observation.domElements,
            trustTag: .untrustedData,
            latencyMs: observation.latencyMs,
            passkeyRejected: passkeyRejected
        )
    }
}

/// Flat JSON output contract for `helmctl browser act`, encoding all 8 `BrowserObservation` fields
/// with `screenshotPNGPath` as a plain filesystem path (not a `file://` URI) plus `passkeyRejected`.
public struct BrowserObservationCLIOutput: Codable, Sendable, Equatable {
    public let url: String
    public let title: String
    public let viewportSize: CGSize
    public let screenshotPNGPath: String
    public let ocrLines: [OCRLine]
    public let domElements: [DOMInteractiveElement]
    public let trustTag: TrustLevel
    public let latencyMs: Double
    public let passkeyRejected: Bool

    public init(
        url: String,
        title: String,
        viewportSize: CGSize,
        screenshotPNGPath: String,
        ocrLines: [OCRLine],
        domElements: [DOMInteractiveElement],
        trustTag: TrustLevel = .untrustedData,
        latencyMs: Double,
        passkeyRejected: Bool
    ) {
        self.url = url
        self.title = title
        self.viewportSize = viewportSize
        self.screenshotPNGPath = screenshotPNGPath
        self.ocrLines = ocrLines
        self.domElements = domElements
        self.trustTag = .untrustedData
        self.latencyMs = latencyMs
        self.passkeyRejected = passkeyRejected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decode(String.self, forKey: .url)
        self.title = try container.decode(String.self, forKey: .title)
        self.viewportSize = try container.decode(CGSize.self, forKey: .viewportSize)
        self.screenshotPNGPath = try container.decode(String.self, forKey: .screenshotPNGPath)
        self.ocrLines = try container.decode([OCRLine].self, forKey: .ocrLines)
        self.domElements = try container.decode([DOMInteractiveElement].self, forKey: .domElements)
        _ = try container.decodeIfPresent(TrustLevel.self, forKey: .trustTag)
        self.trustTag = .untrustedData
        self.latencyMs = try container.decode(Double.self, forKey: .latencyMs)
        self.passkeyRejected = try container.decodeIfPresent(Bool.self, forKey: .passkeyRejected) ?? false
    }
}

public actor BrowseReadActTool: BrowserOCRService {
    private struct SessionEntry {
        let projectID: UUID
        let cdp: HeadlessChromeCDP
        let artifactDir: URL
        var lastObservation: BrowserObservation?
        var lastPasskeyRejected: Bool = false
    }

    private let chromePath: String?
    private let ocrService: VisionOCRService
    private var sessions: [UUID: SessionEntry] = [:]

    public init(
        chromePath: String? = nil,
        ocrService: VisionOCRService = VisionOCRService()
    ) {
        self.chromePath = chromePath
        self.ocrService = ocrService
    }

    public func openSession(projectID: UUID) async throws -> UUID {
        let sessionID = UUID()
        await ocrService.warmUpInBackground()

        let cdp = try HeadlessChromeCDP(sessionID: sessionID, chromePath: chromePath)
        let artifactDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm_browser_artifacts_\(sessionID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)

        do {
            try await cdp.start(timeoutSeconds: 30.0)
        } catch {
            await cdp.terminate()
            try? FileManager.default.removeItem(at: artifactDir)
            throw error
        }

        sessions[sessionID] = SessionEntry(
            projectID: projectID,
            cdp: cdp,
            artifactDir: artifactDir
        )
        return sessionID
    }

    public func sessionDevToolsPort(_ sessionID: UUID) async -> Int? {
        guard let entry = sessions[sessionID] else { return nil }
        return await entry.cdp.devToolsPort
    }

    public func perform(
        _ action: BrowserAction,
        sessionID: UUID,
        timeoutSeconds: TimeInterval = 60.0
    ) async throws -> BrowserObservation {
        let report = try await performDetailed(
            action,
            sessionID: sessionID,
            screenshotOutURL: nil,
            timeoutSeconds: timeoutSeconds
        )
        return report.observation
    }

    public func performDetailed(
        _ action: BrowserAction,
        sessionID: UUID,
        screenshotOutURL: URL? = nil,
        timeoutSeconds: TimeInterval = 60.0
    ) async throws -> BrowserActionReport {
        guard timeoutSeconds > 0, timeoutSeconds.isFinite else {
            throw HelmBrowserError.invalidArgument("timeoutSeconds must be a positive finite number.")
        }
        guard let entry = sessions[sessionID] else {
            throw HelmBrowserError.sessionNotFound(sessionID)
        }

        let startClock = ContinuousClock.now
        let ocrService = self.ocrService

        let report: BrowserActionReport
        do {
            report = try await withDeadline(seconds: timeoutSeconds, onTimeout: {
                await entry.cdp.terminate()
            }) {
                var evalResult: String? = nil

                switch action {
                case .navigate(let url):
                    try await entry.cdp.navigate(url: url)

                case .clickCSS(let x, let y):
                    try await entry.cdp.clickCSS(x: x, y: y)

                case .clickOCRText(let query):
                    let currentLines: [OCRLine]
                    if let cached = entry.lastObservation {
                        currentLines = cached.ocrLines
                    } else {
                        let preSnap = try await entry.cdp.captureSnapshotState()
                        currentLines = try await ocrService.recognizeText(
                            pngData: preSnap.pngData,
                            viewportSize: preSnap.viewportSize
                        )
                    }
                    guard let matched = VisionOCRService.matchOCRLine(query: query, in: currentLines) else {
                        throw HelmBrowserError.ocrTargetNotFound(
                            query: query,
                            availableTexts: currentLines.map(\.text)
                        )
                    }
                    let targetPoint = CoordinateMapper.centerPoint(
                        of: matched.cssRect,
                        clampedTo: HeadlessChromeCDP.defaultViewportSize
                    )
                    try await entry.cdp.clickCSS(x: targetPoint.x, y: targetPoint.y)

                case .typeText(let selectorOrOCR, let text, let submit):
                    let currentLines: [OCRLine]
                    if let cached = entry.lastObservation {
                        currentLines = cached.ocrLines
                    } else {
                        let preSnap = try await entry.cdp.captureSnapshotState()
                        currentLines = try await ocrService.recognizeText(
                            pngData: preSnap.pngData,
                            viewportSize: preSnap.viewportSize
                        )
                    }
                    try await entry.cdp.typeText(
                        selectorOrOCR: selectorOrOCR,
                        text: text,
                        submit: submit,
                        ocrLines: currentLines
                    )

                case .evaluateJS(let script):
                    evalResult = try await entry.cdp.evaluateJS(script: script)
                }

                let snapshot = try await entry.cdp.captureSnapshotState()
                let ocrLines = try await ocrService.recognizeText(
                    pngData: snapshot.pngData,
                    viewportSize: snapshot.viewportSize
                )

                let pngURL = try Self.writeScreenshot(
                    pngData: snapshot.pngData,
                    requestedURL: screenshotOutURL,
                    fallbackDir: entry.artifactDir
                )

                let elapsed = ContinuousClock.now - startClock
                let latencyMs = Double(elapsed.components.seconds) * 1000.0
                    + Double(elapsed.components.attoseconds) / 1e15

                let observation = BrowserObservation(
                    url: snapshot.url,
                    title: snapshot.title,
                    viewportSize: snapshot.viewportSize,
                    screenshotPNGPath: pngURL,
                    ocrLines: ocrLines,
                    domElements: snapshot.domElements,
                    trustTag: .untrustedData,
                    latencyMs: max(0.0, latencyMs)
                )
                return BrowserActionReport(
                    observation: observation,
                    passkeyRejected: snapshot.passkeyRejected,
                    evalResult: evalResult
                )
            }
        } catch {
            if error is CancellationError {
                sessions.removeValue(forKey: sessionID)
                await entry.cdp.terminate()
                try? FileManager.default.removeItem(at: entry.artifactDir)
            } else if case HelmBrowserError.timeout = error {
                sessions.removeValue(forKey: sessionID)
                await entry.cdp.terminate()
                try? FileManager.default.removeItem(at: entry.artifactDir)
            } else if case HelmBrowserError.sessionNotFound = error {
                sessions.removeValue(forKey: sessionID)
                await entry.cdp.terminate()
                try? FileManager.default.removeItem(at: entry.artifactDir)
            }
            throw error
        }

        if var updated = sessions[sessionID] {
            updated.lastObservation = report.observation
            updated.lastPasskeyRejected = report.passkeyRejected
            sessions[sessionID] = updated
        }

        return report
    }

    public func closeSession(_ sessionID: UUID) async {
        guard let entry = sessions.removeValue(forKey: sessionID) else {
            return
        }
        await entry.cdp.terminate()
        try? FileManager.default.removeItem(at: entry.artifactDir)
    }

    public func closeAllSessions() async {
        let ids = Array(sessions.keys)
        for id in ids {
            await closeSession(id)
        }
    }

    // MARK: - Helpers

    private static func writeScreenshot(
        pngData: Data,
        requestedURL: URL?,
        fallbackDir: URL
    ) throws -> URL {
        let destination: URL
        if let requestedURL {
            destination = requestedURL
            let parent = requestedURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
            destination = fallbackDir.appendingPathComponent("shot_\(UUID().uuidString).png")
        }
        try pngData.write(to: destination, options: .atomic)
        return destination
    }

    private enum DeadlinePhase<T: Sendable> {
        case awaitingContinuation
        case pending(CheckedContinuation<T, Error>)
        case cancelledBeforeInstall
        case finished
    }

    private final class DeadlineRaceState<T: Sendable>: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<DeadlinePhase<T>>(initialState: .awaitingContinuation)
        private var opTask: Task<Void, Never>?
        private var timerTask: Task<Void, Never>?

        func installContinuation(_ cont: CheckedContinuation<T, Error>) -> Bool {
            lock.withLock { phase in
                switch phase {
                case .awaitingContinuation:
                    phase = .pending(cont)
                    return true
                case .cancelledBeforeInstall:
                    phase = .finished
                    return false
                case .pending, .finished:
                    return false
                }
            }
        }

        func attachTasks(opTask: Task<Void, Never>, timerTask: Task<Void, Never>) {
            let shouldCancel = lock.withLock { phase -> Bool in
                if case .pending = phase {
                    self.opTask = opTask
                    self.timerTask = timerTask
                    return false
                }
                return true
            }
            if shouldCancel {
                opTask.cancel()
                timerTask.cancel()
            }
        }

        func claimWinnerForTimeout() -> (CheckedContinuation<T, Error>, Task<Void, Never>?)? {
            lock.withLock { phase in
                guard case .pending(let cont) = phase else {
                    return nil
                }
                phase = .finished
                let op = self.opTask
                self.opTask = nil
                self.timerTask = nil
                return (cont, op)
            }
        }

        func resolve(with result: Result<T, Error>) -> Bool {
            let extracted: (CheckedContinuation<T, Error>?, Task<Void, Never>?, Task<Void, Never>?) = lock.withLock { phase in
                switch phase {
                case .awaitingContinuation:
                    if case .failure(let err) = result, err is CancellationError {
                        phase = .cancelledBeforeInstall
                    }
                    return (nil, nil, nil)
                case .pending(let cont):
                    phase = .finished
                    let op = self.opTask
                    let timer = self.timerTask
                    self.opTask = nil
                    self.timerTask = nil
                    return (cont, op, timer)
                case .cancelledBeforeInstall, .finished:
                    return (nil, nil, nil)
                }
            }
            extracted.1?.cancel()
            extracted.2?.cancel()
            if let cont = extracted.0 {
                cont.resume(with: result)
                return true
            }
            return false
        }
    }

    private func withDeadline<T: Sendable>(
        seconds: TimeInterval,
        onTimeout: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let state = DeadlineRaceState<T>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.installContinuation(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let opTask = Task {
                    do {
                        let value = try await operation()
                        _ = state.resolve(with: .success(value))
                    } catch {
                        _ = state.resolve(with: .failure(error))
                    }
                }
                let timerTask = Task {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                        if let (cont, op) = state.claimWinnerForTimeout() {
                            op?.cancel()
                            await onTimeout()
                            cont.resume(throwing: HelmBrowserError.timeout(seconds))
                        }
                    } catch {
                        // Cancelled when operation completed or parent cancelled
                    }
                }
                state.attachTasks(opTask: opTask, timerTask: timerTask)
            }
        } onCancel: {
            if state.resolve(with: .failure(CancellationError())) {
                Task {
                    await onTimeout()
                }
            }
        }
    }
}
