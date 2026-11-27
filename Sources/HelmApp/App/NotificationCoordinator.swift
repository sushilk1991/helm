import Foundation
import HelmCore
@preconcurrency import UserNotifications

@MainActor
public final class NotificationCoordinator {
    public let isDisabled: Bool
    private var hasRequestedAuthorization = false
    private var notifiedExceptionIDs: Set<UUID> = []

    public init(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let disableEnv = environment["HELM_DISABLE_NOTIFICATIONS"] == "1"
        let noActivateEnv = environment["HELM_NO_ACTIVATE"] == "1"
        let headlessArg = arguments.contains("--headless") || arguments.contains("--snapshot-dir")
        let missingBundle = Bundle.main.bundleIdentifier == nil
        self.isDisabled = disableEnv || noActivateEnv || headlessArg || missingBundle
    }

    public func requestAuthorizationIfNeeded() async {
        guard !isDisabled, !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Posts a local macOS notification strictly for open ExceptionAlerts (never on STEADY_OK).
    public func notifyIfNewException(_ alert: ExceptionAlert, projectName: String) async {
        guard !isDisabled, alert.status == .open else { return }
        guard !notifiedExceptionIDs.contains(alert.id) else { return }
        notifiedExceptionIDs.insert(alert.id)

        await requestAuthorizationIfNeeded()

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Helm — \(projectName)"
        content.subtitle = alert.title
        content.body = alert.summary
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "helm.exception.\(alert.id.uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    public func clearNotified(exceptionID: UUID) {
        notifiedExceptionIDs.remove(exceptionID)
    }
}
