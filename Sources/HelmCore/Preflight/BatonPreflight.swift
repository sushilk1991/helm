import Foundation

public struct BatonStatusSnapshot: Codable, Sendable, Equatable {
    public struct Lane: Codable, Sendable, Equatable {
        public let name: String
        public let used: Int
        public let total: Int
        public let configuredTotal: Int

        enum CodingKeys: String, CodingKey {
            case name, used, total
            case configuredTotal = "configured_total"
        }

        public init(name: String, used: Int, total: Int, configuredTotal: Int) {
            self.name = name
            self.used = used
            self.total = total
            self.configuredTotal = configuredTotal
        }
    }

    public struct Memory: Codable, Sendable, Equatable {
        public let pressure: String
        public let totalBytes: UInt64
        public let availableBytes: UInt64
        public let swapTotalBytes: UInt64
        public let swapUsedBytes: UInt64
        public let someAvg10: Double?

        enum CodingKeys: String, CodingKey {
            case pressure
            case totalBytes = "total_bytes"
            case availableBytes = "available_bytes"
            case swapTotalBytes = "swap_total_bytes"
            case swapUsedBytes = "swap_used_bytes"
            case someAvg10 = "some_avg10"
        }

        public init(
            pressure: String,
            totalBytes: UInt64,
            availableBytes: UInt64,
            swapTotalBytes: UInt64,
            swapUsedBytes: UInt64,
            someAvg10: Double? = nil
        ) {
            self.pressure = pressure
            self.totalBytes = totalBytes
            self.availableBytes = availableBytes
            self.swapTotalBytes = swapTotalBytes
            self.swapUsedBytes = swapUsedBytes
            self.someAvg10 = someAvg10
        }
    }

    public let time: String
    public let lanes: [Lane]
    public let memory: Memory

    public init(time: String, lanes: [Lane], memory: Memory) {
        self.time = time
        self.lanes = lanes
        self.memory = memory
    }
}

public enum PreflightVerdict: Sendable, Equatable {
    case proceed(availableBytes: UInt64, pressure: String)
    case warn(reason: String, availableBytes: UInt64)
    case hold(reason: String, availableBytes: UInt64)
    case unavailable(diagnostic: String)
}

public struct BatonPreflight: Sendable {
    public let executablePath: String

    public init(executablePath: String = BatonPreflight.defaultExecutablePath()) {
        self.executablePath = executablePath
    }

    public static func defaultExecutablePath() -> String {
        let homebrew = "/opt/homebrew/bin/baton"
        if FileManager.default.isExecutableFile(atPath: homebrew) {
            return homebrew
        }
        return "/usr/bin/env"
    }

    public static func evaluate(
        snapshot: BatonStatusSnapshot,
        requiredMemoryBytes: UInt64 = 768 * 1024 * 1024
    ) -> PreflightVerdict {
        let pressure = snapshot.memory.pressure.lowercased()
        let available = snapshot.memory.availableBytes
        if pressure == "critical" || available < requiredMemoryBytes {
            return .hold(
                reason: "Host memory pressure=\(snapshot.memory.pressure), available=\(available) bytes < required \(requiredMemoryBytes) bytes",
                availableBytes: available
            )
        }
        if pressure == "warn" || pressure == "warning" || available < 2 * 1024 * 1024 * 1024 {
            return .warn(
                reason: "Host memory constrained (pressure=\(snapshot.memory.pressure), available=\(available) bytes)",
                availableBytes: available
            )
        }
        return .proceed(availableBytes: available, pressure: snapshot.memory.pressure)
    }

    public static func decodeSnapshot(from data: Data) throws -> BatonStatusSnapshot {
        try JSONDecoder().decode(BatonStatusSnapshot.self, from: data)
    }

    public func checkPreflight(
        requiredMemoryBytes: UInt64 = 768 * 1024 * 1024,
        timeoutSeconds: TimeInterval = 3.0
    ) async -> PreflightVerdict {
        let execURL: URL
        let args: [String]
        if executablePath == "/usr/bin/env" {
            execURL = URL(fileURLWithPath: "/usr/bin/env")
            args = ["baton", "status", "--json"]
        } else {
            guard FileManager.default.isExecutableFile(atPath: executablePath) else {
                return .unavailable(diagnostic: "baton executable not found at \(executablePath)")
            }
            execURL = URL(fileURLWithPath: executablePath)
            args = ["status", "--json"]
        }

        do {
            let output = try await ProcessRunner.run(
                executableURL: execURL,
                arguments: args,
                timeoutSeconds: timeoutSeconds
            )
            guard output.exitCode == 0 else {
                return .unavailable(diagnostic: "baton status exited \(output.exitCode): \(output.stderr)")
            }
            let snapshot = try Self.decodeSnapshot(from: output.stdoutData)
            return Self.evaluate(snapshot: snapshot, requiredMemoryBytes: requiredMemoryBytes)
        } catch {
            return .unavailable(diagnostic: error.localizedDescription)
        }
    }
}
