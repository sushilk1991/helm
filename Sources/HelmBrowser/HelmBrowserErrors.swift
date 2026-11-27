import Foundation

public enum HelmBrowserError: Error, Sendable, LocalizedError, Equatable {
    case notImplementedInM1
    case chromeNotFound(String)
    case sessionNotFound(UUID)
    case cdpLaunchFailed(String)
    case cdpProtocolError(String)
    case timeout(TimeInterval)
    case ocrTargetNotFound(query: String, availableTexts: [String])
    case elementNotInteractive(x: Double, y: Double, tagName: String?)
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .notImplementedInM1:
            return "HelmBrowser headless CDP + Vision OCR service is scheduled for Milestone M3."
        case .chromeNotFound(let path):
            return "Google Chrome executable not found or not executable at '\(path)'."
        case .sessionNotFound(let sessionID):
            return "Browser session '\(sessionID.uuidString)' was not found or has already been closed."
        case .cdpLaunchFailed(let reason):
            return "Failed to launch headless Chrome CDP session: \(reason)"
        case .cdpProtocolError(let detail):
            return "Chrome DevTools Protocol error: \(detail)"
        case .timeout(let seconds):
            return "Browser operation timed out after \(String(format: "%.2f", seconds))s."
        case .ocrTargetNotFound(let query, let availableTexts):
            let preview = availableTexts.prefix(8).joined(separator: ", ")
            return "OCR target '\(query)' was not found on page. Observed texts: [\(preview)]"
        case .elementNotInteractive(let x, let y, let tagName):
            let tagDesc = tagName ?? "none"
            return "No interactive element found at CSS coordinates (\(String(format: "%.1f", x)), \(String(format: "%.1f", y))) (hit: \(tagDesc))."
        case .invalidArgument(let message):
            return "Invalid browser argument: \(message)"
        }
    }
}
