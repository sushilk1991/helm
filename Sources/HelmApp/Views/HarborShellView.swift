import HelmCore
import SwiftUI

public struct HarborInteractiveShellView: View {
    @Bindable var store: HelmWorkspaceStore

    public init(store: HelmWorkspaceStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.showOnboarding {
                OnboardingFlowView(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                NavigationSplitView {
                    ProjectSidebarView(store: store)
                        .navigationSplitViewColumnWidth(min: 224, ideal: 244, max: 272)
                } detail: {
                    HStack(spacing: 0) {
                        ProjectCanvasView(store: store)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if store.isInspectorVisible && store.selectedProject != nil {
                            DetailInspectorView(store: store)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(store.forcedReduceMotion ? HelmMotion.exit : HelmMotion.state, value: store.showOnboarding)
        .environment(\.helmReduceMotion, store.forcedReduceMotion)
        .environment(\.helmWindowOccluded, store.isWindowOccluded)
        .sheet(isPresented: $store.showNewProjectSheet) {
            NewProjectSheet(store: store)
        }
        .sheet(isPresented: $store.showAddAgentSheet) {
            if let project = store.selectedProject {
                AddAgentSheet(store: store, projectID: project.id)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
    }
}

/// Deterministic 3-pane layout sharing the exact same subviews for offscreen snapshot capture.
public struct HarborSnapshotShellView: View {
    @Bindable var store: HelmWorkspaceStore
    public let horizonPingOverride: Bool

    public init(store: HelmWorkspaceStore, horizonPingOverride: Bool = false) {
        self.store = store
        self.horizonPingOverride = horizonPingOverride
    }

    public var body: some View {
        HStack(spacing: 0) {
            ProjectSidebarView(store: store)

            Rectangle()
                .fill(HelmSurface.line)
                .frame(width: 1)

            ProjectCanvasView(store: store, horizonPingOverride: horizonPingOverride)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.isInspectorVisible && store.selectedProject != nil {
                DetailInspectorView(store: store)
            }
        }
        .frame(width: 1280, height: 800)
        .background(HelmSurface.canvas)
    }
}
