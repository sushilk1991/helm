import Foundation
import HelmCore

public actor ExecutionRouter: SandboxExecutor {
    private let vmRunner: VirtualizationVMRunner
    private let seatbeltRunner: SeatbeltSandboxRunner
    private let powerGuard: PowerAssertionGuard
    private let batonPreflight: BatonPreflight

    public init(
        vmRunner: VirtualizationVMRunner = VirtualizationVMRunner(),
        seatbeltRunner: SeatbeltSandboxRunner = SeatbeltSandboxRunner(),
        powerGuard: PowerAssertionGuard = PowerAssertionGuard(),
        batonPreflight: BatonPreflight = BatonPreflight()
    ) {
        self.vmRunner = vmRunner
        self.seatbeltRunner = seatbeltRunner
        self.powerGuard = powerGuard
        self.batonPreflight = batonPreflight
    }

    public func execute(_ request: ExecutionRequest) async throws -> ExecutionResult {
        let trimmedCmd = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCmd.isEmpty else {
            throw HelmIsolationError.emptyCommand
        }
        _ = try SeatbeltSandboxRunner.resolveCanonicalWorkspace(request.workspacePath)

        let token = powerGuard.acquire(reason: "Helm Workspace Sandbox Execution")
        defer { powerGuard.release(token) }

        switch request.preferredMode {
        case .seatbeltSandbox:
            return try await seatbeltRunner.execute(request)

        case .virtualizationVM:
            guard EntitlementChecker.isVirtualizationSupported() else {
                throw HelmIsolationError.virtualizationUnsupported
            }
            guard EntitlementChecker.hasVirtualizationEntitlement() else {
                throw HelmIsolationError.missingEntitlement
            }
            let verdict = await batonPreflight.checkPreflight(requiredMemoryBytes: 768 * 1024 * 1024)
            if case .hold(let reason, _) = verdict {
                throw HelmIsolationError.insufficientHostMemory(reason: reason)
            }
            return try await vmRunner.execute(request)

        case nil:
            if EntitlementChecker.isVirtualizationAvailable() {
                let verdict = await batonPreflight.checkPreflight(requiredMemoryBytes: 768 * 1024 * 1024)
                let held: Bool
                if case .hold = verdict {
                    held = true
                } else {
                    held = false
                }
                if !held {
                    do {
                        return try await vmRunner.execute(request)
                    } catch HelmIsolationError.imageDownloadFailed,
                            HelmIsolationError.missingEntitlement,
                            HelmIsolationError.virtualizationUnsupported {
                        // Fall back cleanly to Seatbelt if VM provisioning/entitlement isn't available in auto mode.
                    }
                }
            }
            return try await seatbeltRunner.execute(request)
        }
    }

    public func shutdownWorkspace(_ projectID: UUID) async {
        await vmRunner.shutdownWorkspace(projectID)
        await seatbeltRunner.shutdownWorkspace(projectID)
    }

    public func shutdownAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.vmRunner.shutdownAll() }
            group.addTask { await self.seatbeltRunner.shutdownAll() }
        }
    }
}
