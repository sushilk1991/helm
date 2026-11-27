import AppKit
import Foundation
import HelmCore
import SwiftUI

public struct NewProjectSheet: View {
    @Bindable var store: HelmWorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var goal: String = ""
    @State private var workspacePath: String = ""
    @State private var backend: LLMBackendKind = .mock
    @State private var starterRoles: Set<AgentRole> = [.researcher, .coder]
    @State private var validationError: String?
    @State private var isSubmitting: Bool = false

    private let optionalRoles: [AgentRole] = [.researcher, .coder, .browserAnalyst, .qaVerifier]

    public init(store: HelmWorkspaceStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                CompassHelmLogo(size: 36, style: .emblem)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Autonomous Project")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(HelmInk.primary)
                    Text("Deploys an exception-only Orchestrator plus your chosen starter crew in an isolated local workspace.")
                        .font(.caption)
                        .foregroundStyle(HelmInk.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Project Name")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.secondary)
                        TextField("e.g., Harbor Telemetry Pipeline", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI Provider")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.secondary)
                        Picker("AI Provider", selection: $backend) {
                            ForEach(LLMBackendKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Goal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmInk.secondary)
                    TextField("Describe the outcome the Orchestrator should achieve…", text: $goal, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace Folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HelmInk.secondary)
                    HStack(spacing: 8) {
                        TextField("/path/to/workspace", text: $workspacePath)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            pickFolder()
                        }
                        .buttonStyle(HelmSecondaryButtonStyle())
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Starter Specialists (Compass Orchestrator included automatically)")
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
        .frame(width: 540)
        .background(HelmSurface.canvas)
        .onAppear {
            backend = store.defaultBackend
            if workspacePath.isEmpty {
                let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
                let defaultRoot = docs.appendingPathComponent("Helm/workspaces/project-\(UUID().uuidString.prefix(6).lowercased())")
                workspacePath = defaultRoot.path
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
        }
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            validationError = "Project name cannot be empty."
            return
        }
        guard !trimmedGoal.isEmpty else {
            validationError = "Project goal cannot be empty."
            return
        }
        guard !trimmedPath.isEmpty else {
            validationError = "Workspace path cannot be empty."
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
                    starterRoles: ordered
                )
                dismiss()
            } catch {
                validationError = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
