import Foundation

/// One successful mini sampling point. Keeping the samples with the status makes
/// a poll failure intentionally leave the last curve intact instead of clearing it.
public struct MiniGooseHistorySample: Equatable, Identifiable, Sendable {
    public let id: Date
    public let metrics: MiniGooseMetrics

    public init(date: Date, metrics: MiniGooseMetrics) {
        self.id = date
        self.metrics = metrics
    }
}

/// One read-only sample from minigoose. Every metric is optional on purpose:
/// a macOS output change must degrade a single field to `--`, not take down
/// the whole status item.
public struct MiniGooseMetrics: Equatable, Sendable {
    public var epochSeconds: Int?
    public var cpuUsagePercent: Double?
    public var load1: Double?
    public var load5: Double?
    public var load15: Double?
    public var cores: Int?
    public var memoryTotalBytes: Int?
    public var memoryUsedBytes: Int?
    public var memoryWiredBytes: Int?
    public var memoryCompressedBytes: Int?
    public var swapTotalBytes: Int?
    public var swapUsedBytes: Int?
    public var diskUsedPercent: Double?
    public var diskAvailableBytes: Int?
    public var networkInterface: String?
    public var rxBytesPerSecond: Int?
    public var txBytesPerSecond: Int?
    public var networkErrors: Int?
    public var publicPingMilliseconds: Double?
    public var healthStatus: String?
    public var healthFailures: Int?
    public var healthAgeSeconds: Int?
    public var uptimeSeconds: Int?

    public init() {}

    public var memoryUsedPercent: Double? {
        guard let used = memoryUsedBytes, let total = memoryTotalBytes, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }

    public var swapUsedPercent: Double? {
        guard let used = swapUsedBytes, let total = swapTotalBytes, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }
}

public enum MiniGooseSeverity: Int, Comparable, Sendable {
    case ok = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct MiniGooseStatus: Equatable, Sendable {
    public var metrics: MiniGooseMetrics?
    public private(set) var history: [MiniGooseHistorySample] = []
    public var lastSuccessAt: Date?
    public var lastError: String?
    public var isFetching: Bool = false

    public static let historyLimit = 120

    public static let idle = MiniGooseStatus()

    public var isReachable: Bool {
        lastError == nil && metrics != nil
    }

    public var lastSuccessAge: TimeInterval? {
        lastSuccessAt.map { Date().timeIntervalSince($0) }
    }

    public var severity: MiniGooseSeverity {
        if lastError != nil { return .critical }
        guard let metrics else { return .warning }

        if metrics.healthStatus?.uppercased() == "FAIL" { return .critical }
        if let status = metrics.healthStatus, status.uppercased() != "PASS" { return .warning }
        if let age = metrics.healthAgeSeconds, age > 600 { return .critical }
        if let failures = metrics.healthFailures, failures > 0 { return .critical }
        if let disk = metrics.diskUsedPercent, disk >= 90 { return .critical }
        if let cpu = metrics.cpuUsagePercent, cpu >= 90 { return .critical }

        if let age = metrics.healthAgeSeconds, age > 300 { return .warning }
        if let disk = metrics.diskUsedPercent, disk >= 85 { return .warning }
        if let cpu = metrics.cpuUsagePercent, cpu >= 80 { return .warning }
        if let memory = metrics.memoryUsedPercent, memory >= 90 { return .warning }
        if let swap = metrics.swapUsedPercent, swap >= 80 { return .warning }
        if let ping = metrics.publicPingMilliseconds, ping >= 200 { return .warning }
        if let errors = metrics.networkErrors, errors > 0 { return .warning }

        return .ok
    }

    public var shortMenuBarText: String {
        if lastError != nil {
            if metrics == nil { return "鹅--" }
            return "鹅失联"
        }
        guard let metrics else { return "鹅--" }

        func rounded(_ value: Double?) -> String {
            guard let value else { return "--" }
            return String(format: "%.0f", min(100, max(0, value)))
        }
        return "鹅 \(rounded(metrics.cpuUsagePercent))/\(rounded(metrics.memoryUsedPercent))"
    }

    public func markingFetching() -> MiniGooseStatus {
        var copy = self
        copy.isFetching = true
        return copy
    }

    public func success(_ newMetrics: MiniGooseMetrics, at date: Date = Date()) -> MiniGooseStatus {
        var copy = self
        copy.metrics = newMetrics
        copy.lastSuccessAt = date
        copy.lastError = nil
        copy.isFetching = false
        copy.history.append(MiniGooseHistorySample(date: date, metrics: newMetrics))
        if copy.history.count > Self.historyLimit {
            copy.history.removeFirst(copy.history.count - Self.historyLimit)
        }
        return copy
    }

    public func failure(_ message: String) -> MiniGooseStatus {
        var copy = self
        copy.lastError = message
        copy.isFetching = false
        return copy
    }
}

public enum MiniGooseMetricsError: LocalizedError, Equatable {
    case missingMarker
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case .missingMarker:
            return "迷你鹅返回格式缺少 MINIGOOSE_V1 标记"
        case .emptyOutput:
            return "迷你鹅返回为空"
        }
    }
}

public enum MiniGooseMetricsParser {
    public static func parse(_ rawOutput: String) throws -> MiniGooseMetrics {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MiniGooseMetricsError.emptyOutput }
        guard trimmed.contains("MINIGOOSE_V1") else { throw MiniGooseMetricsError.missingMarker }

        var values: [String: String] = [:]
        for rawLine in trimmed.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != "MINIGOOSE_V1" else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }

        var metrics = MiniGooseMetrics()
        metrics.epochSeconds = intValue(values["now"])

        // vm.loadavg prints `{ 2.07 2.10 2.07 }`.
        if let load = values["load"] {
            let numbers = load.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "}" })
                .compactMap { Double($0) }
            if numbers.count >= 3 {
                metrics.load1 = numbers[0]
                metrics.load5 = numbers[1]
                metrics.load15 = numbers[2]
            }
        }

        metrics.cpuUsagePercent = doubleValue(values["cpu_usage"])
        metrics.cores = intValue(values["cores"])
        metrics.memoryTotalBytes = intValue(values["mem_total"])
        metrics.memoryUsedBytes = intValue(values["mem_used"])
        metrics.memoryWiredBytes = intValue(values["mem_wired"])
        metrics.memoryCompressedBytes = intValue(values["mem_compressed"])
        metrics.swapTotalBytes = intValue(values["swap_total"])
        metrics.swapUsedBytes = intValue(values["swap_used"])
        metrics.diskUsedPercent = doubleValue(values["disk_used"])
        metrics.diskAvailableBytes = intValue(values["disk_avail"])
        metrics.networkInterface = values["iface"].flatMap { $0.isEmpty ? nil : $0 }
        metrics.rxBytesPerSecond = intValue(values["rx"])
        metrics.txBytesPerSecond = intValue(values["tx"])
        metrics.networkErrors = intValue(values["errors"])
        metrics.publicPingMilliseconds = doubleValue(values["ping_ms"])
        metrics.healthStatus = values["health_status"].flatMap { $0.isEmpty ? nil : $0 }
        metrics.healthFailures = intValue(values["health_failures"])
        metrics.healthAgeSeconds = intValue(values["health_age"])
        metrics.uptimeSeconds = intValue(values["uptime"])
        return metrics
    }

    private static func intValue(_ string: String?) -> Int? {
        guard let string, !string.isEmpty else { return nil }
        return Int(string)
    }

    private static func doubleValue(_ string: String?) -> Double? {
        guard let string, !string.isEmpty else { return nil }
        return Double(string)
    }
}
