import Foundation
import Security
import Virtualization

public enum EntitlementChecker {
    public static let virtualizationEntitlementKey = "com.apple.security.virtualization"

    public static func hasVirtualizationEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else {
            return false
        }
        var error: Unmanaged<CFError>?
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            virtualizationEntitlementKey as CFString,
            &error
        ) else {
            return false
        }
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }
        return false
    }

    public static func isVirtualizationSupported() -> Bool {
        VZVirtualMachine.isSupported
    }

    public static func isVirtualizationAvailable() -> Bool {
        isVirtualizationSupported() && hasVirtualizationEntitlement()
    }
}
