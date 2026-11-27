import AppKit
import HelmCore
import SwiftUI

public struct CLIAuthSignInSheet: View {
    @Bindable var authManager: CLIAuthManager

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.helmReduceMotion) private var forcedReduceMotion

    @State private var isOutputExpanded: Bool = false
    @State private var didCopyDeviceCode: Bool = false
    @State private var didCopyURL: Bool = false
    @State private var isPulsing: Bool = false

    public init(authManager: CLIAuthManager) {
        self.authManager = authManager
    }

    private var effectiveReduceMotion: Bool {
        systemReduceMotion || forcedReduceMotion
    }

    private var provider: CLIAuthProviderKind {
        authManager.activeLoginProvider ?? .claude
    }

    private var isActivePhase: Bool {
        switch authManager.activeLoginPhase {
        case .launching, .awaitingBrowser, .verifying:
            return true
        case .idle, .succeeded, .failed, .cancelled:
            return false
        }
    }

    private var isFailedPhase: Bool {
        if case .failed = authManager.activeLoginPhase {
            return true
        }
        return false
    }

    private var isSucceededPhase: Bool {
        if case .succeeded = authManager.activeLoginPhase {
            return true
        }
        return false
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider().overlay(HelmSurface.line)

            VStack(alignment: .leading, spacing: HelmSpace.xl) {
                phaseContent

                if shouldShowCLIOutput {
                    liveCLIOutputSection
                }
            }
            .padding(HelmSpace.xxl)

            Divider().overlay(HelmSurface.line)

            footerBar
        }
        .frame(width: 500)
        .background(HelmSurface.canvas)
        .onAppear {
            if isFailedPhase {
                isOutputExpanded = true
            }
            if !effectiveReduceMotion {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
        .onChange(of: isFailedPhase) { _, failed in
            if failed {
                withAnimation(HelmMotion.micro) {
                    isOutputExpanded = true
                }
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: HelmSpace.l) {
            CompassHelmLogo(size: 32, style: .emblem)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: HelmSpace.m) {
                    Text("Sign In to \(provider.displayName)")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(HelmInk.primary)
                        .lineLimit(1)

                    profileModeBadge
                }

                HStack(spacing: HelmSpace.s) {
                    Text(provider.commandName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(HelmInk.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                    if let method = authManager.activeLoginMethod {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(HelmInk.muted)
                        Text(method.title)
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: HelmSpace.s)

            Button {
                handleClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HelmInk.secondary)
                    .frame(width: 24, height: 24)
                    .background(HelmSurface.well, in: Circle())
                    .overlay(Circle().strokeBorder(HelmSurface.line, lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, HelmSpace.xxl)
        .padding(.vertical, HelmSpace.xl)
    }

    private var profileModeBadge: some View {
        let isIsolated = authManager.profileMode == .helmIsolated
        return HStack(spacing: 4) {
            Image(systemName: isIsolated ? "lock.shield.fill" : "person.crop.circle")
                .font(.system(size: 9.5, weight: .semibold))
            Text(authManager.profileMode.displayName)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(isIsolated ? HelmAccent.primary : HelmInk.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(isIsolated ? HelmAccent.primarySoft : HelmSurface.well, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                isIsolated ? HelmAccent.primary.opacity(0.25) : HelmSurface.line,
                lineWidth: 0.75
            )
        )
    }

    // MARK: - Dynamic Phase Body

    @ViewBuilder
    private var phaseContent: some View {
        switch authManager.activeLoginPhase {
        case .idle, .launching:
            launchingView
        case .awaitingBrowser:
            awaitingBrowserView
        case .verifying:
            verifyingView
        case .succeeded(let identity):
            succeededView(identity: identity)
        case .failed(let message):
            failedView(message: message)
        case .cancelled:
            cancelledView
        }
    }

    private var launchingView: some View {
        HStack(alignment: .center, spacing: HelmSpace.xl) {
            ZStack {
                RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                    .fill(HelmAccent.primarySoft)
                    .frame(width: 46, height: 46)
                ProgressView()
                    .controlSize(.regular)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Starting \(provider.commandName) authentication…")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(HelmInk.primary)
                Text(
                    authManager.activeLoginMethod == .deviceCode
                        ? "Requesting a one-time device code for browser or VM sign-in."
                        : "Your default browser will open automatically to complete sign-in."
                )
                .font(.caption)
                .foregroundStyle(HelmInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(HelmSpace.xl)
        .helmCard(cornerRadius: HelmRadius.card)
    }

    private var awaitingBrowserView: some View {
        VStack(alignment: .leading, spacing: HelmSpace.l) {
            // Reassuring primary status card
            VStack(alignment: .leading, spacing: HelmSpace.m) {
                HStack(spacing: HelmSpace.m) {
                    ZStack {
                        Circle()
                            .fill(HelmAccent.primary.opacity(effectiveReduceMotion ? 0.20 : (isPulsing ? 0.30 : 0.12)))
                            .frame(width: 22, height: 22)
                        Circle()
                            .fill(HelmAccent.primary)
                            .frame(width: 8, height: 8)
                    }

                    Text("Complete sign-in in your browser")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)

                    Spacer(minLength: 0)

                    ProgressView()
                        .controlSize(.mini)
                }

                Text(
                    authManager.didAutoOpenBrowser
                        ? "Your browser opened automatically. Helm is watching — this window will complete as soon as you finish signing in."
                        : "Helm is watching automatically — this window will complete as soon as you finish signing in."
                )
                .font(.caption)
                .foregroundStyle(HelmInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(HelmSpace.xl)
            .helmCard(cornerRadius: HelmRadius.card, accentBorder: HelmAccent.primary.opacity(0.32))

            // Prominent Device Code card (for VM / headless / Codex --device-auth)
            if let deviceCode = authManager.discoveredDeviceCode, !deviceCode.isEmpty {
                VStack(alignment: .leading, spacing: HelmSpace.m) {
                    HStack(spacing: HelmSpace.s) {
                        Text("ONE-TIME DEVICE CODE")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(HelmInk.muted)

                        Text("VM / Headless Ready")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(HelmAccent.brass)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(HelmAccent.brassSoft, in: Capsule())

                        Spacer(minLength: 0)
                    }

                    HStack(alignment: .center, spacing: HelmSpace.l) {
                        Text(deviceCode)
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .tracking(2.0)
                            .foregroundStyle(HelmInk.primary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        Spacer(minLength: HelmSpace.s)

                        Button {
                            authManager.copyDeviceCode()
                            triggerCopiedCodeFeedback()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: didCopyDeviceCode ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(didCopyDeviceCode ? "Copied!" : "Copy Code")
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(HelmPrimaryButtonStyle())
                    }
                    .padding(.horizontal, HelmSpace.l)
                    .padding(.vertical, HelmSpace.m)
                    .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                            .strokeBorder(HelmSurface.lineStrong, lineWidth: 0.9)
                    )
                }
                .padding(HelmSpace.xl)
                .helmCard(cornerRadius: HelmRadius.panel, accentBorder: HelmAccent.brass.opacity(0.38))
            }

            // Discovered Auth URL card
            if let authURL = authManager.discoveredAuthURL {
                VStack(alignment: .leading, spacing: HelmSpace.m) {
                    HStack(spacing: HelmSpace.m) {
                        Image(systemName: "link")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(HelmInk.muted)

                        Text(authURL.absoluteString)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(HelmInk.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(authURL.absoluteString)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                            .strokeBorder(HelmSurface.line, lineWidth: 0.8)
                    )

                    HStack(spacing: HelmSpace.m) {
                        Button {
                            authManager.openDiscoveredURLInBrowser()
                        } label: {
                            Label("Open in Browser", systemImage: "safari")
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(HelmPrimaryButtonStyle())

                        Button {
                            authManager.copyDiscoveredURL()
                            triggerCopiedURLFeedback()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: didCopyURL ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11, weight: .medium))
                                Text(didCopyURL ? "Copied Link" : "Copy Link")
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(HelmSecondaryButtonStyle())

                        Spacer(minLength: 0)
                    }
                }
                .padding(HelmSpace.xl)
                .helmCard(cornerRadius: HelmRadius.panel)
            }
        }
    }

    private var verifyingView: some View {
        HStack(alignment: .center, spacing: HelmSpace.xl) {
            ZStack {
                RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                    .fill(HelmSemantic.thinkingSoft)
                    .frame(width: 46, height: 46)
                ProgressView()
                    .controlSize(.regular)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Verifying credentials…")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(HelmInk.primary)
                Text("Confirming your active \(provider.displayName) session and account details.")
                    .font(.caption)
                    .foregroundStyle(HelmInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(HelmSpace.xl)
        .helmCard(cornerRadius: HelmRadius.card)
    }

    private func succeededView(identity: CLIAuthIdentity) -> some View {
        VStack(alignment: .leading, spacing: HelmSpace.l) {
            HStack(alignment: .top, spacing: HelmSpace.l) {
                ZStack {
                    RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                        .fill(HelmSemantic.steadySoft)
                        .frame(width: 46, height: 46)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(HelmSemantic.steady)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Signed In to \(identity.provider.displayName)")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)

                    Text(identity.email ?? identity.accountLabel ?? identity.summary)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(HelmInk.primary)
                        .textSelection(.enabled)
                        .lineLimit(2)

                    if let expiresAt = identity.expiresAt, !expiresAt.isEmpty {
                        Text("Session expires: \(expiresAt)")
                            .font(.caption)
                            .foregroundStyle(HelmInk.muted)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: HelmSpace.m) {
                if let planTier = identity.planTier, !planTier.isEmpty {
                    Text(planTier)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmAccent.brass)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(HelmAccent.brassSoft, in: Capsule())
                }

                if !identity.authMethod.isEmpty {
                    Text(identity.authMethod)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(HelmInk.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(HelmSurface.well, in: Capsule())
                        .overlay(Capsule().strokeBorder(HelmSurface.line, lineWidth: 0.75))
                }

                Text(identity.profileMode.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HelmSemantic.steady)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(HelmSemantic.steadySoft, in: Capsule())

                Spacer(minLength: 0)
            }
        }
        .padding(HelmSpace.xl)
        .helmCard(cornerRadius: HelmRadius.card, accentBorder: HelmSemantic.steady.opacity(0.45))
    }

    private func failedView(message: String) -> some View {
        VStack(alignment: .leading, spacing: HelmSpace.l) {
            HStack(alignment: .top, spacing: HelmSpace.l) {
                ZStack {
                    RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                        .fill(HelmSemantic.criticalSoft)
                        .frame(width: 42, height: 42)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(HelmSemantic.critical)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign-In Couldn't Complete")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: HelmSpace.m) {
                Button {
                    authManager.beginLogin(
                        provider: provider,
                        method: authManager.activeLoginMethod ?? .browserOAuth
                    )
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmPrimaryButtonStyle())

                Button {
                    authManager.openTerminalLoginFallback(for: provider)
                } label: {
                    Label("Open in Terminal…", systemImage: "terminal")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmSecondaryButtonStyle())

                Spacer(minLength: 0)
            }
        }
        .padding(HelmSpace.xl)
        .helmCard(cornerRadius: HelmRadius.card, accentBorder: HelmSemantic.critical.opacity(0.42))
    }

    private var cancelledView: some View {
        VStack(alignment: .leading, spacing: HelmSpace.l) {
            HStack(alignment: .top, spacing: HelmSpace.l) {
                ZStack {
                    RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                        .fill(HelmSurface.well)
                        .frame(width: 42, height: 42)
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(HelmInk.muted)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign-In Cancelled")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HelmInk.primary)
                    Text("No changes were made to your \(provider.displayName) credentials.")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: HelmSpace.m) {
                Button {
                    authManager.beginLogin(
                        provider: provider,
                        method: authManager.activeLoginMethod ?? .browserOAuth
                    )
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmPrimaryButtonStyle())

                Button {
                    authManager.openTerminalLoginFallback(for: provider)
                } label: {
                    Label("Open in Terminal…", systemImage: "terminal")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmSecondaryButtonStyle())

                Spacer(minLength: 0)
            }
        }
        .padding(HelmSpace.xl)
        .helmCard(cornerRadius: HelmRadius.card)
    }

    // MARK: - Expandable Live CLI Output

    private var shouldShowCLIOutput: Bool {
        !authManager.liveLogLines.isEmpty || isActivePhase || isFailedPhase
    }

    private var liveCLIOutputSection: some View {
        DisclosureGroup(isExpanded: $isOutputExpanded) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if authManager.liveLogLines.isEmpty {
                            Text("Waiting for \(provider.commandName) CLI output…")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(HelmInk.muted)
                        } else {
                            ForEach(Array(authManager.liveLogLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(HelmInk.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(minHeight: 84, maxHeight: 150)
                .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                        .strokeBorder(HelmSurface.lineStrong, lineWidth: 0.85)
                )
                .padding(.top, HelmSpace.m)
                .onChange(of: authManager.liveLogLines.count) { _, newCount in
                    if newCount > 0 {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }
        } label: {
            HStack(spacing: HelmSpace.s) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HelmInk.secondary)
                Text("CLI Output")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HelmInk.secondary)
                Spacer()
                if !authManager.liveLogLines.isEmpty {
                    Text("\(authManager.liveLogLines.count) lines")
                        .font(.system(size: 10.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(HelmInk.muted)
                }
            }
        }
        .padding(.horizontal, HelmSpace.l)
        .padding(.vertical, 10)
        .background(HelmSurface.elevated, in: RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HelmRadius.panel, style: .continuous)
                .strokeBorder(HelmSurface.line, lineWidth: 1.0)
        )
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: HelmSpace.m) {
            if !isSucceededPhase {
                Button {
                    authManager.openTerminalLoginFallback(for: provider)
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HelmSecondaryButtonStyle())
                .help("Run interactive CLI login in macOS Terminal")
            }

            Spacer()

            if isSucceededPhase {
                Button("Done") {
                    authManager.dismissSignInSheet()
                }
                .buttonStyle(HelmPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            } else if isActivePhase {
                Button("Cancel") {
                    authManager.cancelActiveLogin()
                    authManager.dismissSignInSheet()
                }
                .buttonStyle(HelmSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            } else {
                Button("Close") {
                    authManager.dismissSignInSheet()
                }
                .buttonStyle(HelmSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, HelmSpace.xxl)
        .padding(.vertical, 14)
    }

    // MARK: - Helpers

    private func handleClose() {
        if isActivePhase {
            authManager.cancelActiveLogin()
        }
        authManager.dismissSignInSheet()
    }

    private func triggerCopiedCodeFeedback() {
        withAnimation(HelmMotion.micro) {
            didCopyDeviceCode = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(HelmMotion.micro) {
                didCopyDeviceCode = false
            }
        }
    }

    private func triggerCopiedURLFeedback() {
        withAnimation(HelmMotion.micro) {
            didCopyURL = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(HelmMotion.micro) {
                didCopyURL = false
            }
        }
    }
}
