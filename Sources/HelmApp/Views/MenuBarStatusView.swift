import HelmCore
import SwiftUI

public struct MenuBarStatusView: View {
    @Bindable var store: HelmWorkspaceStore
    @Environment(\.openWindow) private var openWindow

    public init(store: HelmWorkspaceStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HelmSpace.m) {
            HStack(spacing: HelmSpace.m) {
                CompassHelmLogo(
                    size: 20,
                    style: .inlineMark,
                    hasOpenException: store.totalOpenExceptionCount > 0,
                    settleTrigger: store.settleHelmCounter
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text("Helm Control Plane")
                        .font(.headline)
                    Text(store.totalOpenExceptionCount == 0
                        ? "All autonomous watches steady"
                        : "\(store.totalOpenExceptionCount) exception\(store.totalOpenExceptionCount == 1 ? "" : "s") awaiting decision")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(store.totalOpenExceptionCount == 0 ? HelmInk.secondary : HelmSemantic.attention)
                }
                Spacer()
            }

            Divider()

            if store.projects.isEmpty {
                Text("No active projects")
                    .font(.caption)
                    .foregroundStyle(HelmInk.muted)
            } else {
                ForEach(store.projects) { project in
                    HStack {
                        Text(project.name)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                        ProjectStatusBadge(status: project.status)
                    }
                }
            }

            Divider()

            HStack {
                Button("Open Helm") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                .buttonStyle(.borderedProminent)
                .tint(HelmAccent.primary)

                Spacer()

                if store.projects.contains(where: { $0.status == .running }) {
                    Button("Pause All") {
                        Task { await store.pauseAllProjects() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(HelmSpace.l)
        .frame(width: 280)
    }
}
