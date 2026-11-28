import HelmCore
import SwiftUI

public typealias AgentRolePreset = AgentProfile.RolePreset

public struct AddAgentSheet: View {
    @Bindable var store: HelmWorkspaceStore
    public let projectID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var role: AgentRole = .researcher
    @State private var goal: String = ""
    @State private var personality: AgentPersonality = .methodicalArchitect
    @State private var systemPrompt: String = ""
    @State private var lastAutoName: String = ""
    @State private var lastAutoGoal: String = ""
    @State private var lastAutoSystemPrompt: String = ""
    @State private var backend: LLMBackendKind = .claudeCLI
    @State private var previewSeed: AgentCharacterSeed = AgentCharacterSeed(agentID: UUID(), isOrchestrator: false)
    @State private var validationError: String?
    @State private var isSubmitting: Bool = false

    private let selectableRoles: [AgentRole] = [.researcher, .coder, .browserAnalyst, .qaVerifier, .specialist]

    public init(store: HelmWorkspaceStore, projectID: UUID) {
        self.store = store
        self.projectID = projectID
    }

    private var previewState: AgentActivityState {
        switch role {
        case .coder: return .executing
        case .browserAnalyst: return .browsing
        case .qaVerifier: return .completed
        case .researcher: return .thinking
        default: return .idle
        }
    }

    private var activeProject: Project? {
        store.projects.first(where: { $0.id == projectID }) ?? store.selectedProject
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Hero Live Bot Character Preview
                HStack(spacing: 16) {
                    AgentCharacterCanvas(
                        seed: previewSeed,
                        state: previewState,
                        size: 64,
                        showStageBacking: true,
                        interactive: true
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Deploy Specialized Agent")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(HelmInk.primary)
                        Text("Assign a role, personality, AI engine, and editable system prompt.")
                            .font(.caption)
                            .foregroundStyle(HelmInk.secondary)
                        Button {
                            withAnimation(HelmMotion.bouncy) {
                                previewSeed = AgentCharacterSeed(agentID: UUID(), isOrchestrator: false)
                            }
                        } label: {
                            Label("Preview another bot", systemImage: "dice")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(HelmAccent.primary)
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .helmCard(cornerRadius: HelmRadius.card)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Role")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HelmInk.secondary)
                            Picker("Role", selection: $role) {
                                ForEach(selectableRoles, id: \.self) { r in
                                    Text(r.displayName).tag(r)
                                }
                            }
                            .labelsHidden()
                            .onChange(of: role) { _, newRole in
                                let resolvedPersonality = AgentPersonality.defaultForRole(newRole)
                                personality = resolvedPersonality
                                applyPreset(for: newRole, personality: resolvedPersonality)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Personality")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HelmInk.secondary)
                            Picker("Personality", selection: $personality) {
                                ForEach(AgentPersonality.allCases, id: \.self) { p in
                                    Text(p.displayName).tag(p)
                                }
                            }
                            .labelsHidden()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("AI Provider")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HelmInk.secondary)
                            Picker("Backend", selection: $backend) {
                                ForEach(LLMBackendKind.allCases, id: \.self) { kind in
                                    Text(kind.displayName).tag(kind)
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    Text(personality.tagline)
                        .font(.caption)
                        .foregroundStyle(HelmInk.muted)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Agent Name")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HelmInk.secondary)
                            TextField("e.g., Chart Researcher", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Role Summary")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HelmInk.secondary)
                            TextField("Describe this agent's responsibility…", text: $goal)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("System Prompt")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HelmInk.secondary)
                            Spacer()
                            Button {
                                let generated = AgentProfile.buildSystemPromptTemplate(
                                    role: role,
                                    personality: personality,
                                    goal: goal,
                                    notes: ""
                                )
                                systemPrompt = generated
                                lastAutoSystemPrompt = generated
                            } label: {
                                Label("Apply Preset Template", systemImage: "wand.and.stars")
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(HelmSecondaryButtonStyle())
                        }

                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 140, maxHeight: 210)
                            .background(HelmSurface.well, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
                                    .strokeBorder(HelmSurface.line, lineWidth: 1)
                            )

                        Text("Customize instructions freely. Changing Personality never locks or overwrites your custom prompt.")
                            .font(.system(size: 10))
                            .foregroundStyle(HelmInk.muted)
                    }

                    if let project = activeProject {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "folder.badge.gearshape")
                                .font(.callout)
                                .foregroundStyle(HelmAccent.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Workspace & Tool Access · \(project.sandboxTrustPolicy.displayName)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(HelmInk.primary)
                                Text("Uses \(project.workspaceRoot.lastPathComponent) directly under project policy: \(project.sandboxTrustPolicy.summary).")
                                    .font(.system(size: 11))
                                    .foregroundStyle(HelmInk.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .helmCard(cornerRadius: HelmRadius.panel)
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

                    Button("Deploy Agent") {
                        submit()
                    }
                    .buttonStyle(HelmPrimaryButtonStyle())
                    .disabled(isSubmitting)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
        }
        .frame(width: 580, height: 610)
        .background(HelmSurface.canvas)
        .onAppear {
            backend = store.defaultBackend
            let initialPersonality = AgentPersonality.defaultForRole(role)
            personality = initialPersonality
            applyPreset(for: role, personality: initialPersonality)
        }
    }

    private func applyPreset(for role: AgentRole, personality: AgentPersonality) {
        let preset = AgentProfile.RolePreset.preset(for: role)
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == lastAutoName {
            name = preset.name
            lastAutoName = preset.name
        }
        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || goal == lastAutoGoal {
            goal = preset.goal
            lastAutoGoal = preset.goal
        }
        if systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || systemPrompt == lastAutoSystemPrompt {
            let generated = AgentProfile.buildSystemPromptTemplate(
                role: role,
                personality: personality,
                goal: goal,
                notes: ""
            )
            systemPrompt = generated
            lastAutoSystemPrompt = generated
        }
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationError = "Agent name cannot be empty."
            return
        }
        guard !trimmedGoal.isEmpty else {
            validationError = "Agent role summary cannot be empty."
            return
        }
        guard !trimmedPrompt.isEmpty else {
            validationError = "System prompt cannot be empty."
            return
        }

        isSubmitting = true
        validationError = nil
        Task {
            do {
                try await store.addAgent(
                    projectID: projectID,
                    name: trimmedName,
                    role: role,
                    goal: trimmedGoal,
                    backend: backend,
                    personality: personality,
                    systemPrompt: trimmedPrompt
                )
                dismiss()
            } catch {
                validationError = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
