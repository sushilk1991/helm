import AppKit
import Foundation

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public weak var store: HelmWorkspaceStore?
    private var occlusionObserver: NSObjectProtocol?

    public static var isNoActivateMode: Bool {
        let args = CommandLine.arguments
        let env = ProcessInfo.processInfo.environment
        return env["HELM_NO_ACTIVATE"] == "1"
            || args.contains("--headless")
            || args.contains("--snapshot-dir")
            || args.contains(where: { $0.hasPrefix("--snapshot-dir=") })
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.isNoActivateMode {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isNoActivateMode {
            NSApp.setActivationPolicy(.accessory)
            for window in NSApp.windows {
                window.orderOut(nil)
            }
        }

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let store = self.store else { return }
                let anyVisible = NSApp.windows.contains { $0.occlusionState.contains(.visible) }
                store.isWindowOccluded = NSApp.windows.isEmpty ? false : !anyVisible
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        guard let store else { return }
        store.stopPollingForTermination()
        let browserService = store.browserService
        let sandboxExecutor = store.sandboxExecutor
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await browserService.closeAllSessions() }
                group.addTask { await sandboxExecutor.shutdownAll() }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .seconds(2))
    }
}
