import HelmCore
import SwiftUI

public struct ProjectSidebarView: View {
    @Bindable var store: HelmWorkspaceStore

    public init(store: HelmWorkspaceStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App Identity Header
            HStack(spacing: HelmSpace.m) {
                CompassHelmLogo(
                    size: 28,
                    style: .emblem,
                    hasOpenException: store.totalOpenExceptionCount > 0,
                    settleTrigger: store.settleHelmCounter
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text("Helm")
                        .font(.headline)
                        .foregroundStyle(HelmInk.primary)
                    Text(store.totalOpenExceptionCount == 0 ? "All watches quiet" : "\(store.totalOpenExceptionCount) open hold\(store.totalOpenExceptionCount == 1 ? "" : "s")")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(store.totalOpenExceptionCount == 0 ? HelmInk.secondary : HelmSemantic.attention)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HelmSpace.l)
            .padding(.vertical, HelmSpace.l)

            Divider()
                .overlay(HelmSurface.line)

            ScrollView {
                VStack(alignment: .leading, spacing: HelmSpace.xs) {
                    Text("Projects")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.secondary)
                        .padding(.horizontal, HelmSpace.l)
                        .padding(.top, HelmSpace.xl)
                        .padding(.bottom, HelmSpace.s)

                    if store.projects.isEmpty {
                        Text("Create a project to deploy autonomous agents.")
                            .font(.caption)
                            .foregroundStyle(HelmInk.muted)
                            .padding(.horizontal, HelmSpace.l)
                            .padding(.vertical, HelmSpace.m)
                    } else {
                        ForEach(store.projects) { project in
                            projectRow(project)
                        }
                    }

                    // Exception Inbox — completely absent/collapsed when 0 open exceptions
                    if !store.allOpenExceptions.isEmpty {
                        Text("Exception Inbox")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(HelmSemantic.attention)
                            .padding(.horizontal, HelmSpace.l)
                            .padding(.top, HelmSpace.xl)
                            .padding(.bottom, HelmSpace.s)

                        ForEach(store.allOpenExceptions, id: \.alert.id) { item in
                            exceptionInboxRow(project: item.project, alert: item.alert)
                        }
                    }
                }
                .padding(.bottom, HelmSpace.xl)
            }

            Divider()
                .overlay(HelmSurface.line)

            // Footer actions + virtualization status
            VStack(alignment: .leading, spacing: HelmSpace.m) {
                Button {
                    store.showNewProjectSheet = true
                } label: {
                    Label("New Project", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(HelmPrimaryButtonStyle())

                HStack(spacing: HelmSpace.s) {
                    Image(systemName: store.virtualizationAvailable ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(store.virtualizationAvailable ? HelmSemantic.steady : HelmInk.secondary)
                    Text(store.virtualizationAvailable ? "VZ Micro-VM Ready" : "Seatbelt Sandbox Ready")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(HelmSpace.l)
        }
        .frame(width: 240)
        .background(HelmSurface.sidebar)
    }

    private func projectRow(_ project: Project) -> some View {
        let isSelected = store.selectedProject?.id == project.id
        let openCount = (store.controlPlane.openExceptionsByProject[project.id] ?? []).count

        return Button {
            store.selectProject(project.id)
        } label: {
            HStack(alignment: .top, spacing: HelmSpace.m) {
                Image(systemName: statusSymbol(for: project.status, openCount: openCount))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor(for: project.status, openCount: openCount))
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: HelmSpace.xxs) {
                    Text(project.name)
                        .font(.body.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(HelmInk.primary)
                        .lineLimit(1)
                    Text(project.goal)
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if openCount > 0 {
                    Text("\(openCount)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(HelmSemantic.attention)
                        .padding(.horizontal, HelmSpace.s)
                        .padding(.vertical, 1)
                        .background(HelmSemantic.attentionSoft, in: Capsule())
                }
            }
            .padding(.horizontal, HelmSpace.l)
            .padding(.vertical, HelmSpace.m)
            .background(
                RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                    .fill(isSelected ? HelmSurface.selectedWash : Color.clear)
                    .padding(.horizontal, HelmSpace.m)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(project.goal)
    }

    private func exceptionInboxRow(project: Project, alert: ExceptionAlert) -> some View {
        Button {
            store.selectProject(project.id)
        } label: {
            HStack(alignment: .top, spacing: HelmSpace.m) {
                Image(systemName: alert.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(alert.severity == .critical ? HelmSemantic.critical : HelmSemantic.attention)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: HelmSpace.xxs) {
                    Text(alert.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(HelmInk.primary)
                        .lineLimit(1)
                    Text(project.name)
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HelmSpace.l)
            .padding(.vertical, HelmSpace.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusSymbol(for status: ProjectStatus, openCount: Int) -> String {
        if openCount > 0 || status == .held {
            return "exclamationmark.triangle.fill"
        }
        switch status {
        case .running: return "circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .paused: return "pause.circle"
        case .failed: return "xmark.octagon.fill"
        case .idle, .held: return "circle"
        }
    }

    private func statusColor(for status: ProjectStatus, openCount: Int) -> Color {
        if openCount > 0 || status == .held {
            return HelmSemantic.attention
        }
        switch status {
        case .running, .completed: return HelmSemantic.steady
        case .failed: return HelmSemantic.critical
        case .idle, .paused, .held: return HelmSemantic.idle
        }
    }
}
