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
    @State private var personality: AgentPersonality = .methodicalArchitect
    @State private var personalityNotes: String = ""
    @State private var lastAutoName: String = ""
    @State private var lastAutoGoal: String = ""
    @State private var backend: LLMBackendKind = .claudeCLI
    @State private var capabilities: Set<AgentCapability> = [.readSharedState, .proposeSharedState, .requestHumanDecision]
    @State private var previewSeed: AgentCharacterSeed = AgentCharacterSeed(agentID: UUID(), isOrchestrator: false)
    @State private var validationError: String?
    @State private var isSubmitting: Bool = false

    private let selectableRoles: [AgentRole] = [.researcher, .coder, .browserAnalyst, .qaVerifier, .specialist]
    private let orderedCapabilities: [AgentCapability] = [
        .codeExec, .browser, .ocr, .readSharedState, .proposeSharedState, .delegateTasks, .requestHumanDecision,
    ]

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

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Hero Live Bot Character Preview
                HStack(spacing: 16) {
                    AgentCharacterCanvas(
                        seed: previewSeed,
                        state: previewState,
                        size: 68,
                        showStageBacking: true,
                        interactive: true
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Deploy Specialized Agent")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(HelmInk.primary)
                        Text("Assign a role, personality, AI engine, and clear permissions.")
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
                                applyPreset(for: newRole)
                                personality = AgentPersonality.defaultForRole(newRole)
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
                            Text("Custom Style Note (optional)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HelmInk.secondary)
                            TextField("e.g., Blunt, test-first, Swift 6", text: $personalityNotes)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Responsibility")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.secondary)
                        TextField("Describe this agent's specific responsibility…", text: $goal, axis: .vertical)
                            .lineLimit(2...3)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Permissions")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HelmInk.secondary)

                        VStack(spacing: 8) {
                            ForEach(orderedCapabilities, id: \.self) { cap in
                                let isOn = capabilities.contains(cap)
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: cap.symbolName)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(isOn ? HelmAccent.primary : HelmInk.muted)
                                        .frame(width: 24, height: 24)
                                        .background((isOn ? HelmAccent.primarySoft : HelmSurface.well), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(cap.displayName)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(isOn ? HelmInk.primary : HelmInk.secondary)
                                        Text(cap.humanDescription)
                                            .font(.system(size: 10))
                                            .foregroundStyle(HelmInk.muted)
                                    }

                                    Spacer()

                                    Toggle("", isOn: Binding(
                                        get: { capabilities.contains(cap) },
                                        set: { enabled in
                                            if enabled {
                                                capabilities.insert(cap)
                                            } else {
                                                capabilities.remove(cap)
                                            }
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                    .labelsHidden()
                                }
                            }
                        }
                        .padding(12)
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
            applyPreset(for: role)
            personality = AgentPersonality.defaultForRole(role)
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
                    capabilities: capabilities,
                    personality: personality,
                    personalityNotes: personalityNotes
                )
                dismiss()
            } catch {
                validationError = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
