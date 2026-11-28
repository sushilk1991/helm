import AppKit
import Foundation
import HelmCore
import SwiftUI

public struct NewProjectSheet: View {
    @Bindable var store: HelmWorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var workspacePath: String = ""
    @State private var name: String = ""
    @State private var didManuallyEditName: Bool = false
    @State private var goal: String = ""
    @State private var backend: LLMBackendKind = .mock
    @State private var leadPersonality: AgentPersonality = .calmCommander
    @State private var sandboxTrustPolicy: SandboxTrustPolicy = .standardWorkspace
    @State private var starterRoles: Set<AgentRole> = [.researcher, .coder]
    @State private var validationError: String?
    @State private var isSubmitting: Bool = false

    private let optionalRoles: [AgentRole] = [.researcher, .coder, .browserAnalyst, .qaVerifier]

    public init(store: HelmWorkspaceStore) {
        self.store = store
    }

    private var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let folder = URL(fileURLWithPath: workspacePath).lastPathComponent
        return (folder.isEmpty || folder == "/") ? "" : folder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                CompassHelmLogo(size: 36, style: .emblem)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Autonomous Project")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(HelmInk.primary)
                    Text("Pick a repo or folder — Helm automatically uses its name and deploys your crew.")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                // 1. Repo / Folder picker FIRST (auto-fills project name!)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Repository or Workspace Folder")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.secondary)
                        Spacer()
                        if !resolvedName.isEmpty {
                            Text("Project: \(resolvedName)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(HelmAccent.primary)
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("/path/to/your-repo", text: $workspacePath)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: workspacePath) { _, newPath in
                                if !didManuallyEditName {
                                    let derived = URL(fileURLWithPath: newPath).lastPathComponent
                                    if !derived.isEmpty && derived != "/" {
                                        name = derived
                                    }
                                }
                            }
                        Button {
                            pickFolder()
                        } label: {
                            Label("Choose Repo…", systemImage: "folder")
                        }
                        .buttonStyle(HelmSecondaryButtonStyle())
                    }
                }

                // 2. Goal
                VStack(alignment: .leading, spacing: 4) {
                    Text("Goal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmInk.secondary)
                    TextField("Describe what your autonomous crew should build, test, or monitor…", text: $goal, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }

                // 3. Optional Display Name override + AI Provider + Lead Personality
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Display Name (optional)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.muted)
                        TextField("Auto-filled from folder", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: name) { _, newVal in
                                let folderName = URL(fileURLWithPath: workspacePath).lastPathComponent
                                didManuallyEditName = !newVal.isEmpty && newVal != folderName
                            }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI Provider")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.muted)
                        Picker("AI Provider", selection: $backend) {
                            ForEach(LLMBackendKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 135)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lead Personality")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.muted)
                        Picker("Lead Personality", selection: $leadPersonality) {
                            ForEach(AgentPersonality.allCases, id: \.self) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 165)
                    }
                }

                // 4. Starter Specialists
                VStack(alignment: .leading, spacing: 6) {
                    Text("Starter Specialists (Compass Lead included automatically — add more anytime)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmInk.secondary)

                    HStack(spacing: 8) {
                        ForEach(optionalRoles, id: \.self) { role in
                            let selected = starterRoles.contains(role)
                            Button {
                                withAnimation(HelmMotion.micro) {
                                    if selected {
                                        starterRoles.remove(role)
                                    } else {
                                        starterRoles.insert(role)
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .font(.caption)
                                        .foregroundStyle(selected ? HelmAccent.primary : HelmInk.muted)
                                    Text(role.displayName)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(selected ? HelmInk.primary : HelmInk.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                                        .fill(selected ? HelmSurface.selectedWash : HelmSurface.elevated)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                                        .strokeBorder(selected ? HelmAccent.primary.opacity(0.45) : HelmSurface.line, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // 5. Project-Level Workspace Sandbox / Trust Policy
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Workspace Access & Sandbox Policy")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.secondary)
                        Spacer()
                        Picker("Sandbox Policy", selection: $sandboxTrustPolicy) {
                            ForEach(SandboxTrustPolicy.allCases, id: \.self) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    Text(sandboxTrustPolicy.summary)
                        .font(.caption)
                        .foregroundStyle(HelmInk.muted)
                }
            }

            if let validationError {
                Text(validationError)
                    .font(.callout)
                    .foregroundStyle(HelmSemantic.critical)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(HelmSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)

                Button("Create Project") {
                    submit()
                }
                .buttonStyle(HelmPrimaryButtonStyle())
                .disabled(isSubmitting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 580)
        .background(HelmSurface.canvas)
        .onAppear {
            backend = store.defaultBackend
            if workspacePath.isEmpty {
                let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
                let defaultRoot = docs.appendingPathComponent("Helm/workspaces/workspace-\(UUID().uuidString.prefix(5).lowercased())")
                workspacePath = defaultRoot.path
                name = defaultRoot.lastPathComponent
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            workspacePath = url.path
            name = url.lastPathComponent
            didManuallyEditName = false
        }
    }

    private func submit() {
        let trimmedPath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = resolvedName
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPath.isEmpty else {
            validationError = "Choose a repository or workspace folder."
            return
        }
        guard !trimmedName.isEmpty else {
            validationError = "Choose a valid folder or enter a display name."
            return
        }
        guard !trimmedGoal.isEmpty else {
            validationError = "Describe the goal for your autonomous crew."
            return
        }

        isSubmitting = true
        validationError = nil
        let url = URL(fileURLWithPath: trimmedPath, isDirectory: true)
        let ordered = optionalRoles.filter { starterRoles.contains($0) }
        Task {
            do {
                try await store.createProject(
                    name: trimmedName,
                    goal: trimmedGoal,
                    workspaceRoot: url,
                    backend: backend,
                    leadPersonality: leadPersonality,
                    starterRoles: ordered,
                    sandboxTrustPolicy: sandboxTrustPolicy
                )
                dismiss()
            } catch {
                validationError = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
