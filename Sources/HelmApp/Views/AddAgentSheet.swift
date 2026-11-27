import HelmCore
import SwiftUI

public struct AgentRolePreset: Sendable, Equatable {
    public let name: String
    public let goal: String
    public let capabilities: Set<AgentCapability>

    public static func preset(for role: AgentRole) -> AgentRolePreset {
        switch role {
        case .researcher:
            return AgentRolePreset(
                name: "Chart Researcher",
                goal: "Investigate specifications, synthesize facts into shared state, and verify sources.",
                capabilities: [.readSharedState, .proposeSharedState, .requestHumanDecision]
            )
        case .coder:
            return AgentRolePreset(
                name: "Forge Coder",
                goal: "Implement and test workspace artifacts inside the isolated sandbox.",
                capabilities: [.codeExec, .readSharedState, .proposeSharedState, .requestHumanDecision]
            )
        case .browserAnalyst:
            return AgentRolePreset(
                name: "Lookout Browser",
                goal: "Navigate web targets headlessly, extract OCR/DOM observations, and report findings.",
                capabilities: [.browser, .ocr, .readSharedState, .proposeSharedState, .requestHumanDecision]
            )
        case .qaVerifier:
            return AgentRolePreset(
                name: "Harbor Verifier",
                goal: "Independently run verification checks in isolation and confirm acceptance criteria.",
                capabilities: [.codeExec, .browser, .ocr, .readSharedState, .requestHumanDecision]
            )
        case .specialist:
            return AgentRolePreset(
                name: "Harbor Specialist",
                goal: "Execute domain-specific tasks and collaborate via verified shared state.",
                capabilities: [.readSharedState, .proposeSharedState, .requestHumanDecision]
            )
        case .orchestrator:
            return AgentRolePreset(
                name: "Helm Orchestrator",
                goal: "Coordinate specialists, track shared state, and surface exceptions only when human intervention is needed.",
                capabilities: [.readSharedState, .proposeSharedState, .delegateTasks, .requestHumanDecision]
            )
        }
    }

    public static func apply(
        role: AgentRole,
        name: inout String,
        goal: inout String,
        capabilities: inout Set<AgentCapability>,
        lastAutoName: inout String,
        lastAutoGoal: inout String
    ) {
        let preset = Self.preset(for: role)
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == lastAutoName {
            name = preset.name
            lastAutoName = preset.name
        }
        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || goal == lastAutoGoal {
            goal = preset.goal
            lastAutoGoal = preset.goal
        }
        capabilities = preset.capabilities
    }
}

public struct AddAgentSheet: View {
    @Bindable var store: HelmWorkspaceStore
    public let projectID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var role: AgentRole = .researcher
    @State private var goal: String = ""
    @State private var lastAutoName: String = ""
    @State private var lastAutoGoal: String = ""
    @State private var backend: LLMBackendKind = .claudeCLI
    @State private var capabilities: Set<AgentCapability> = [.readSharedState, .proposeSharedState, .requestHumanDecision]
    @State private var validationError: String?
    @State private var isSubmitting: Bool = false

    private let selectableRoles: [AgentRole] = [.researcher, .coder, .browserAnalyst, .qaVerifier, .specialist]

    public init(store: HelmWorkspaceStore, projectID: UUID) {
        self.store = store
        self.projectID = projectID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HelmSpace.xl) {
            VStack(alignment: .leading, spacing: HelmSpace.xs) {
                Text("Deploy Specialized Agent")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(HelmInk.primary)
                Text("Assign a distinct role, goal, backend provider, and sandbox permissions.")
                    .font(.callout)
                    .foregroundStyle(HelmInk.secondary)
            }

            VStack(alignment: .leading, spacing: HelmSpace.l) {
                HStack(spacing: HelmSpace.l) {
                    VStack(alignment: .leading, spacing: HelmSpace.xs) {
                        Text("Role Preset")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(HelmInk.primary)
                        Picker("Role", selection: $role) {
                            ForEach(selectableRoles, id: \.self) { r in
                                Text(r.displayName).tag(r)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: role) { _, newRole in
                            applyPreset(for: newRole)
                        }
                    }

                    VStack(alignment: .leading, spacing: HelmSpace.xs) {
                        Text("LLM Backend")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(HelmInk.primary)
                        Picker("Backend", selection: $backend) {
                            ForEach(LLMBackendKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                    }
                }

                VStack(alignment: .leading, spacing: HelmSpace.xs) {
                    Text("Agent Name")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(HelmInk.primary)
                    TextField("e.g., Chart Researcher", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: HelmSpace.xs) {
                    Text("Goal")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(HelmInk.primary)
                    TextField("Describe this agent's specific responsibility…", text: $goal, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: HelmSpace.s) {
                    Text("Capabilities")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(HelmInk.primary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: HelmSpace.s) {
                        ForEach(AgentCapability.allCases, id: \.self) { cap in
                            Toggle(cap.displayName, isOn: Binding(
                                get: { capabilities.contains(cap) },
                                set: { enabled in
                                    if enabled {
                                        capabilities.insert(cap)
                                    } else {
                                        capabilities.remove(cap)
                                    }
                                }
                            ))
                            .toggleStyle(.checkbox)
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
                .keyboardShortcut(.cancelAction)

                Button("Deploy Agent") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .tint(HelmAccent.primary)
                .disabled(isSubmitting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(HelmSpace.xxl)
        .frame(width: 500)
        .onAppear {
            applyPreset(for: role)
        }
    }

    private func applyPreset(for role: AgentRole) {
        AgentRolePreset.apply(
            role: role,
            name: &name,
            goal: &goal,
            capabilities: &capabilities,
            lastAutoName: &lastAutoName,
            lastAutoGoal: &lastAutoGoal
        )
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationError = "Agent name cannot be empty."
            return
        }
        guard !trimmedGoal.isEmpty else {
            validationError = "Agent goal cannot be empty."
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
                    capabilities: capabilities
                )
                dismiss()
            } catch {
                validationError = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
