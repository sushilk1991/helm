#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public enum DriftViolation: Error, Sendable, LocalizedError, Equatable {
    case workspaceEscape(candidatePath: String, workspaceRoot: String)
    case schemaDrift(detail: String)
    case ruleTamperAttempt(key: String)
    case goalDivergence(detail: String)

    public var errorDescription: String? {
        switch self {
        case .workspaceEscape(let candidate, let root):
            return "Workspace boundary violation: '\(candidate)' escapes project root '\(root)'."
        case .schemaDrift(let detail):
            return "Action schema contract drift: \(detail)"
        case .ruleTamperAttempt(let key):
            return "Protected rule tamper attempt on '\(key)'."
        case .goalDivergence(let detail):
            return "Execution drifted from project goal: \(detail)"
        }
    }
}

public struct DriftDetector: Sendable {
    private static let maxSymlinkHops = 32

    public init() {}

    @discardableResult
    public func validateWorkspacePath(_ candidatePath: String, workspaceRoot: URL) throws -> URL {
        guard let safeURL = Self.resolveSafeWorkspaceURL(candidatePath, workspaceRoot: workspaceRoot) else {
            let rootDisplay = Self.canonicalPath(for: workspaceRoot) ?? workspaceRoot.path
            throw DriftViolation.workspaceEscape(
                candidatePath: candidatePath,
                workspaceRoot: rootDisplay
            )
        }
        return safeURL
    }

    public func isPathInsideWorkspace(_ candidatePath: String, workspaceRoot: URL) -> Bool {
        Self.resolveSafeWorkspaceURL(candidatePath, workspaceRoot: workspaceRoot) != nil
    }

    public static func canonicalPath(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        return canonicalPath(forRawPath: url.path)
    }

    private static func resolveSafeWorkspaceURL(_ candidatePath: String, workspaceRoot: URL) -> URL? {
        let trimmed = candidatePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
        guard workspaceRoot.isFileURL else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        guard !expanded.isEmpty, !expanded.contains("\0") else { return nil }

        let rootPath = workspaceRoot.path
        guard rootPath.hasPrefix("/"), !rootPath.contains("\0") else { return nil }

        let rawCandidate: String
        if expanded.hasPrefix("/") {
            rawCandidate = expanded
        } else {
            rawCandidate = (rootPath.hasSuffix("/") ? rootPath : rootPath + "/") + expanded
        }

        guard let canonicalRoot = canonicalPath(forRawPath: rootPath),
              let canonicalTarget = canonicalPath(forRawPath: rawCandidate) else {
            return nil
        }

        let normalizedRoot = canonicalRoot == "/" ? "/" : canonicalRoot + "/"
        guard canonicalTarget == canonicalRoot || canonicalTarget.hasPrefix(normalizedRoot) else {
            return nil
        }
        return URL(fileURLWithPath: canonicalTarget)
    }

    private static func canonicalPath(forRawPath rawPath: String) -> String? {
        guard rawPath.hasPrefix("/"), !rawPath.contains("\0") else { return nil }

        var resolved: [String] = []
        var pendingReversed: [String] = rawPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .reversed()
        var remainingHops = maxSymlinkHops
        let fm = FileManager.default

        while let component = pendingReversed.popLast() {
            if component == "." { continue }
            if component == ".." {
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            }

            let probePath = "/" + (resolved + [component]).joined(separator: "/")
            var st = stat()
            let rc = lstat(probePath, &st)
            let lstatErrno = errno
            if rc == 0 {
                let fileType = st.st_mode & S_IFMT
                if fileType == S_IFLNK {
                    guard remainingHops > 0 else { return nil }
                    remainingHops -= 1
                    guard let target = try? fm.destinationOfSymbolicLink(atPath: probePath),
                          !target.isEmpty,
                          !target.contains("\0") else {
                        return nil
                    }
                    if target.hasPrefix("/") {
                        resolved.removeAll(keepingCapacity: true)
                    }
                    let targetParts = target
                        .split(separator: "/", omittingEmptySubsequences: true)
                        .map(String.init)
                    pendingReversed.append(contentsOf: targetParts.reversed())
                    continue
                }
                if !pendingReversed.isEmpty && fileType != S_IFDIR {
                    return nil
                }
                resolved.append(component)
            } else {
                guard lstatErrno == ENOENT else { return nil }
                resolved.append(component)
            }
        }

        return "/" + resolved.joined(separator: "/")
    }
}
