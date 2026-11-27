import Foundation
import HelmCore

public enum HelmIsolationError: Error, Sendable, LocalizedError, Equatable {
    case invalidWorkspace(String)
    case emptyCommand
    case virtualizationUnsupported
    case missingEntitlement
    case insufficientHostMemory(reason: String)
    case imageDownloadFailed(String)
    case invalidKernelImage(String)
    case vmStartFailed(String)
    case vmStoppedUnexpectedly(String)
    case rpcTimeout
    case rpcProtocolError(String)
    case seatbeltFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidWorkspace(let detail):
            return "Invalid workspace path: \(detail)"
        case .emptyCommand:
            return "Sandbox command must not be empty."
        case .virtualizationUnsupported:
            return "Apple Virtualization.framework is not supported on this host."
        case .missingEntitlement:
            return "Process is missing the 'com.apple.security.virtualization' entitlement."
        case .insufficientHostMemory(let reason):
            return "Insufficient host memory for VM execution: \(reason)"
        case .imageDownloadFailed(let detail):
            return "Failed to download Alpine VM assets: \(detail)"
        case .invalidKernelImage(let detail):
            return "Invalid Alpine Linux kernel/initramfs image: \(detail)"
        case .vmStartFailed(let detail):
            return "Failed to start Virtualization.framework VM: \(detail)"
        case .vmStoppedUnexpectedly(let detail):
            return "Virtualization.framework VM stopped unexpectedly: \(detail)"
        case .rpcTimeout:
            return "Timed out waiting for VM guest RPC response."
        case .rpcProtocolError(let detail):
            return "VM guest RPC protocol error: \(detail)"
        case .seatbeltFailed(let detail):
            return "Seatbelt sandbox execution failed: \(detail)"
        }
    }
}
