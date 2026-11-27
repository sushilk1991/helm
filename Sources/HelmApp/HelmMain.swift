import AppKit
import Foundation
import HelmAppCore

@main
enum HelmMain {
    static func main() {
        let args = CommandLine.arguments
        let env = ProcessInfo.processInfo.environment

        switch HeadlessSnapshotRunner.parseSnapshotDir(arguments: args) {
        case .invalid(let message):
            fputs("Helm snapshot error: \(message)\n", stderr)
            Foundation.exit(1)
        case .valid(let snapshotDir):
            let reduceMotion = args.contains("--reduce-motion") || env["HELM_REDUCE_MOTION"] == "1"
            let semaphore = DispatchSemaphore(value: 0)
            let box = SnapshotErrorBox()

            Task { @MainActor in
                do {
                    try await HeadlessSnapshotRunner.run(
                        snapshotDirectory: URL(fileURLWithPath: snapshotDir, isDirectory: true),
                        reduceMotion: reduceMotion
                    )
                } catch {
                    box.error = error
                }
                semaphore.signal()
            }

            while semaphore.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }

            if let err = box.error {
                fputs("Helm snapshot error: \(err.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
            Foundation.exit(0)
        case .notRequested:
            break
        }

        if args.contains("--headless") && args.contains("--seed-demo") {
            Foundation.exit(0)
        }

        HelmSwiftUIApp.main()
    }
}

private final class SnapshotErrorBox: @unchecked Sendable {
    var error: Error?
}
