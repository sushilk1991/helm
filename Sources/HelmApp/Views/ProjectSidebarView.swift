import HelmCore
import SwiftUI

public struct ProjectSidebarView: View {
    @Bindable var store: HelmWorkspaceStore

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.helmReduceMotion) private var forcedReduceMotion

    @State private var isHoveringUpdateIcon: Bool = false
    @State private var spinAngle: Double = 0

    public init(store: HelmWorkspaceStore) {
        self.store = store
    }

    private var effectiveReduceMotion: Bool {
        systemReduceMotion || forcedReduceMotion
    }

    private var updater: AppUpdateManager {
        store.updateManager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App Identity Header + Left-Sidebar Update Icon
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

                sidebarUpdateButton
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

            // Inline Update Banner (appears smoothly only when a newer release is available / downloading / installing)
            if let release = updater.state.availableRelease {
                sidebarUpdateBanner(release: release)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Divider().overlay(HelmSurface.line)

            // Footer actions + subtle environment & version strip
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
                        store.openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(HelmInk.secondary)
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                    .help("Settings & AI CLIs (⌘,)")
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(HelmSemantic.steady)
                        .frame(width: 6, height: 6)
                    Text(store.virtualizationAvailable ? "Apple VM Ready" : "Sandbox Ready")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                    Spacer(minLength: 0)
                    Text("v\(updater.currentVersionString)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(HelmInk.muted)
                }
            }
            .padding(14)
        }
        .frame(width: 244)
        .background(HelmSurface.sidebar)
        .animation(effectiveReduceMotion ? HelmMotion.exit : HelmMotion.state, value: updater.state)
    }

    // MARK: - Left-Sidebar Update Icon & Popover

    private var sidebarUpdateButton: some View {
        let hasUpdate = updater.state.availableRelease != nil
        let isChecking: Bool = {
            if case .checking = updater.state { return true }
            return false
        }()
        let isUpToDate: Bool = {
            if case .upToDate = updater.state { return true }
            return false
        }()

        return Button {
            updater.showUpdatePopover.toggle()
            if case .idle = updater.state {
                Task { await updater.checkForUpdates(userInitiated: true) }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if hasUpdate {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(HelmAccent.primary)
                    } else if isChecking {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HelmAccent.primary)
                            .rotationEffect(.degrees(effectiveReduceMotion ? 0 : spinAngle))
                    } else if isUpToDate {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(HelmSemantic.steady)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isHoveringUpdateIcon ? HelmInk.primary : HelmInk.muted)
                    }
                }
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                        .fill(hasUpdate
                            ? HelmAccent.primarySoft
                            : (isHoveringUpdateIcon ? HelmSurface.elevated : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                        .strokeBorder(
                            hasUpdate
                                ? HelmAccent.primary.opacity(0.35)
                                : (isHoveringUpdateIcon ? HelmSurface.line : Color.clear),
                            lineWidth: 1
                        )
                )

                if hasUpdate {
                    Circle()
                        .fill(HelmAccent.brass)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(HelmSurface.sidebar, lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(HelmMotion.micro) {
                isHoveringUpdateIcon = hovering
            }
        }
        .onChange(of: isChecking) { _, active in
            if active && !effectiveReduceMotion {
                spinAngle = 0
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    spinAngle = 360
                }
            } else {
                withAnimation(.default) {
                    spinAngle = 0
                }
            }
        }
        .help(updateTooltip)
        .popover(
            isPresented: Binding(
                get: { updater.showUpdatePopover },
                set: { updater.showUpdatePopover = $0 }
            ),
            arrowEdge: .trailing
        ) {
            updatePopoverContent
        }
    }

    private var updateTooltip: String {
        switch updater.state {
        case .available(let release):
            return "Update v\(release.version.displayString) available"
        case .downloading(let progress, let release):
            return "Downloading v\(release.version.displayString) (\(Int(progress * 100))%)"
        case .waitingForIdle(let release):
            return "v\(release.version.displayString) ready — waiting for active agents to finish"
        case .installing(let release):
            return "Installing v\(release.version.displayString)…"
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "Helm v\(updater.currentVersionString) is up to date"
        case .failed:
            return "Update check failed — click to retry"
        case .idle:
            return "Check for Updates (v\(updater.currentVersionString))"
        }
    }

    private var updatePopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                CompassHelmLogo(size: 26, style: .emblem)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Helm Updates")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                    Text("Current version v\(updater.currentVersionString)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(HelmInk.secondary)
                }
                Spacer()
            }

            Divider().overlay(HelmSurface.line)

            switch updater.state {
            case .idle:
                Text("Check GitHub Releases for signed & notarized updates.")
                    .font(.caption)
                    .foregroundStyle(HelmInk.secondary)

            case .checking:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking GitHub Releases…")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                }

            case .upToDate(let checkedAt):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(HelmSemantic.steady)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You're up to date")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(HelmInk.primary)
                        Text("Checked \(checkedAt, format: .dateTime.hour().minute())")
                            .font(.caption)
                            .foregroundStyle(HelmInk.muted)
                    }
                }

            case .available(let release):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Helm v\(release.version.displayString) Available")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(HelmAccent.primary)
                        Spacer()
                        MetadataTag("Notarized")
                    }
                    if !release.notes.isEmpty {
                        ScrollView {
                            Text(release.notes)
                                .font(.caption)
                                .foregroundStyle(HelmInk.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 110)
                    }
                }

            case .downloading(let progress, let release):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Downloading v\(release.version.displayString)…")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.primary)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(HelmInk.secondary)
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }

            case .waitingForIdle(let release):
                VStack(alignment: .leading, spacing: 6) {
                    Label("v\(release.version.displayString) Downloaded & Verified", systemImage: "checkmark.shield.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmSemantic.steady)
                    Text("Waiting for \(updater.activeRunningProjectCount) active project(s) to finish before restarting—no running agents will be interrupted.")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                }

            case .installing(let release):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checkpointing active state & installing v\(release.version.displayString)…")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                }

            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Update check failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmSemantic.attention)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                        .lineLimit(3)
                }
            }

            if case .available = updater.state, updater.activeRunningProjectCount > 0 {
                Text("\(updater.activeRunningProjectCount) project(s) currently running. Updating checkpoints state to SQLite and auto-resumes on relaunch, or waits until idle.")
                    .font(.system(size: 10))
                    .foregroundStyle(HelmInk.muted)
            }

            HStack(spacing: 8) {
                if case .available(let release) = updater.state {
                    if updater.activeRunningProjectCount > 0 {
                        Button("When Idle") {
                            Task { await updater.downloadAndInstall(release, deferUntilIdle: true) }
                        }
                        .buttonStyle(HelmSecondaryButtonStyle())

                        Button {
                            Task { await updater.downloadAndInstall(release, deferUntilIdle: false) }
                        } label: {
                            Text("Safe Update")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HelmPrimaryButtonStyle())
                    } else {
                        Button {
                            Task { await updater.downloadAndInstall(release, deferUntilIdle: false) }
                        } label: {
                            Label("Install & Restart", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HelmPrimaryButtonStyle())
                    }
                } else if case .waitingForIdle(let release) = updater.state {
                    Button("Cancel Wait") {
                        updater.cancelWaitingForIdle()
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())

                    Button {
                        Task { await updater.downloadAndInstall(release, deferUntilIdle: false) }
                    } label: {
                        Text("Restart Now")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                } else {
                    Button {
                        Task { await updater.checkForUpdates(userInitiated: true) }
                    } label: {
                        Text("Check Now")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                    .disabled(updater.state.isBusy)
                }

                Button {
                    updater.openReleasesPage()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(HelmSecondaryButtonStyle())
                .help("Open Releases on GitHub")
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(HelmSurface.elevated)
    }

    private func sidebarUpdateBanner(release: HelmReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HelmAccent.primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update v\(release.version.displayString)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                    Text(bannerSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(HelmInk.secondary)
                }
                Spacer(minLength: 0)
            }

            switch updater.state {
            case .downloading(let progress, _):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            case .waitingForIdle:
                HStack(spacing: 6) {
                    Button("Cancel") {
                        updater.cancelWaitingForIdle()
                    }
                    .buttonStyle(HelmSecondaryButtonStyle())
                    Button {
                        Task { await updater.downloadAndInstall(release, deferUntilIdle: false) }
                    } label: {
                        Text("Restart Now")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                }
            case .installing:
                ProgressView()
                    .progressViewStyle(.linear)
            default:
                if updater.activeRunningProjectCount > 0 {
                    HStack(spacing: 6) {
                        Button("When Idle") {
                            Task { await updater.downloadAndInstall(release, deferUntilIdle: true) }
                        }
                        .buttonStyle(HelmSecondaryButtonStyle())
                        Button {
                            Task { await updater.downloadAndInstall(release, deferUntilIdle: false) }
                        } label: {
                            Text("Safe Update")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HelmPrimaryButtonStyle())
                    }
                } else {
                    Button {
                        Task { await updater.downloadAndInstall(release, deferUntilIdle: false) }
                    } label: {
                        Label("Update & Restart", systemImage: "arrow.down.circle.fill")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                }
            }
        }
        .padding(10)
        .helmCard(cornerRadius: HelmRadius.panel, accentBorder: HelmAccent.primary.opacity(0.35))
    }

    private var bannerSubtitle: String {
        switch updater.state {
        case .downloading(let progress, _):
            return "Downloading \(Int(progress * 100))%…"
        case .waitingForIdle:
            return "Staged · waiting for active agents"
        case .installing:
            return "Checkpointing & restarting…"
        default:
            return updater.activeRunningProjectCount > 0
                ? "Auto-pauses & resumes active agents"
                : "Signed & notarized release ready"
        }
    }

    // MARK: - Sidebar Rows

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
