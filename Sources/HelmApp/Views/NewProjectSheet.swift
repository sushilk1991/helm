import Foundation
import HelmCore
import SwiftUI

public struct NewProjectSheet: View {
    @Bindable var store: HelmWorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var goal: String = ""
    @State private var workspacePath: String = ""
    @State private var validationError: String?
    @State private var isSubmitting: Bool = false

    public init(store: HelmWorkspaceStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HelmSpace.xl) {
            VStack(alignment: .leading, spacing: HelmSpace.xs) {
                Text("New Autonomous Project")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(HelmInk.primary)
                Text("Each project launches with an exception-only Orchestrator and an isolated local workspace.")
                    .font(.callout)
                    .foregroundStyle(HelmInk.secondary)
            }

            VStack(alignment: .leading, spacing: HelmSpace.l) {
                VStack(alignment: .leading, spacing: HelmSpace.xs) {
                    Text("Project Name")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(HelmInk.primary)
                    TextField("e.g., Harbor Telemetry Pipeline", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: HelmSpace.xs) {
                    Text("Goal")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(HelmInk.primary)
                    TextField("Describe the outcome the Orchestrator should achieve…", text: $goal, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: HelmSpace.xs) {
                    Text("Workspace Root")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(HelmInk.primary)
                    HStack(spacing: HelmSpace.m) {
                        TextField("/path/to/workspace", text: $workspacePath)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            pickFolder()
                        }
                        .buttonStyle(.bordered)
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
                .keyboardShortcut(.cancelAction)

                Button("Create Project") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .tint(HelmAccent.primary)
                .disabled(isSubmitting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(HelmSpace.xxl)
        .frame(width: 480)
        .onAppear {
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
        Task {
            do {
                try await store.createProject(name: trimmedName, goal: trimmedGoal, workspaceRoot: url)
                dismiss()
            } catch {
                validationError = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
