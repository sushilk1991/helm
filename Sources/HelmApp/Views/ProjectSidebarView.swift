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
                    size: 30,
                    style: .emblem,
                    hasOpenException: store.totalOpenExceptionCount > 0,
                    settleTrigger: store.settleHelmCounter
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text("Helm")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(HelmInk.primary)
                    Text(store.totalOpenExceptionCount == 0
                        ? "All watches quiet"
                        : "\(store.totalOpenExceptionCount) need\(store.totalOpenExceptionCount == 1 ? "s" : "") decision")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(store.totalOpenExceptionCount == 0 ? HelmInk.secondary : HelmSemantic.attention)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            Divider().overlay(HelmSurface.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PROJECTS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(HelmInk.muted)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 6)

                    if store.projects.isEmpty {
                        Text("No projects yet")
                            .font(.caption)
                            .foregroundStyle(HelmInk.muted)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(store.projects) { project in
                            projectRow(project)
                        }
                    }

                    // Exception Inbox — completely absent when 0 open exceptions
                    if !store.allOpenExceptions.isEmpty {
                        Text("NEEDS DECISION")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(HelmSemantic.attention)
                            .padding(.horizontal, 16)
                            .padding(.top, 18)
                            .padding(.bottom, 6)

                        ForEach(store.allOpenExceptions, id: \.alert.id) { item in
                            exceptionInboxRow(project: item.project, alert: item.alert)
                        }
                    }
                }
                .padding(.bottom, 16)
            }

            Divider().overlay(HelmSurface.line)

            // Footer actions + subtle environment & setup controls
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        store.showNewProjectSheet = true
                    } label: {
                        Label("New Project", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())

                    Button {
                        store.reopenOnboarding()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(HelmInk.secondary)
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                    .help("Setup & AI Provider Preferences")
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(HelmSemantic.steady)
                        .frame(width: 6, height: 6)
                    Text(store.virtualizationAvailable ? "Apple VM Ready" : "Sandbox Ready")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                    Spacer(minLength: 0)
                    Text(store.defaultBackend.displayName)
                        .font(.caption)
                        .foregroundStyle(HelmInk.muted)
                }
            }
            .padding(14)
        }
        .frame(width: 244)
        .background(HelmSurface.sidebar)
    }

    private func projectRow(_ project: Project) -> some View {
        let isSelected = store.selectedProject?.id == project.id
        let openCount = (store.controlPlane.openExceptionsByProject[project.id] ?? []).count
        let crewCount = (store.controlPlane.agentsByProject[project.id] ?? []).count

        return Button {
            store.selectProject(project.id)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: statusSymbol(for: project.status, openCount: openCount))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor(for: project.status, openCount: openCount))

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(HelmInk.primary)
                        .lineLimit(1)
                    Text(crewCount > 0 ? "\(crewCount) agent\(crewCount == 1 ? "" : "s")" : project.goal)
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
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(HelmSemantic.attentionSoft, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                    .fill(isSelected ? HelmSurface.selectedWash : Color.clear)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(project.goal)
    }

    private func exceptionInboxRow(project: Project, alert: ExceptionAlert) -> some View {
        Button {
            store.selectProject(project.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: alert.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(alert.severity == .critical ? HelmSemantic.critical : HelmSemantic.attention)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                        .lineLimit(1)
                    Text(project.name)
                        .font(.caption2)
                        .foregroundStyle(HelmInk.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
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
