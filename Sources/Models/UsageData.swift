import Foundation
import TokenUsageCore

enum ServiceStatus: String, Codable, Sendable {
    case ok
    case warning
    case critical
    case error

    var sfSymbol: String {
        switch self {
        case .ok:       return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "xmark.circle.fill"
        case .error:    return "questionmark.circle.fill"
        }
    }
}

struct UsageData: Codable, Equatable, Sendable {
    let serviceId: String
    let serviceType: ServiceType
    let serviceName: String

    // Core metrics
    let usedAmount: Double
    let totalAmount: Double
    let remainingAmount: Double
    let usagePercentage: Double  // 0.0 ... 1.0

    let unitLabel: String
    let lastUpdated: Date
    let isUnlimited: Bool  // true if no hard cap
    let resetTime: Date?   // when this quota window resets (if known)
    let windowDuration: TimeInterval?  // whole window length; with resetTime it positions the time marker

    /// 时间进度 0...1：窗口已流逝的比例。仅当 resetTime 与 windowDuration 都
    /// 已知时存在（余额类卡片永远没有）。用于进度条上的时间标线。
    var timeProgress: Double? {
        guard let resetTime, let windowDuration else { return nil }
        let windowStart = resetTime.addingTimeInterval(-windowDuration)
        return QuotaTimeProgress.fraction(
            elapsed: Date().timeIntervalSince(windowStart),
            duration: windowDuration
        )
    }

    var status: ServiceStatus {
        if isUnlimited { return .ok }
        if usagePercentage >= 0.95 { return .critical }
        if usagePercentage >= 0.80 { return .warning }
        return .ok
    }

    var formattedPercentage: String {
        String(format: "%.0f%%", usagePercentage * 100)
    }

    init(
        serviceId: String,
        serviceType: ServiceType,
        serviceName: String,
        usedAmount: Double,
        totalAmount: Double,
        unitLabel: String,
        isUnlimited: Bool = false,
        resetTime: Date? = nil,
        windowDuration: TimeInterval? = nil
    ) {
        self.serviceId = serviceId
        self.serviceType = serviceType
        self.serviceName = serviceName
        self.usedAmount = usedAmount
        self.totalAmount = totalAmount
        self.remainingAmount = max(0, totalAmount - usedAmount)
        self.usagePercentage = totalAmount > 0 ? usedAmount / totalAmount : 0
        self.unitLabel = unitLabel
        self.lastUpdated = Date()
        self.isUnlimited = isUnlimited
        self.resetTime = resetTime
        self.windowDuration = windowDuration
    }

    /// Creates a placeholder entry for services that failed to fetch data.
    static func errorPlaceholder(serviceId: String, serviceType: ServiceType, serviceName: String, error: String) -> UsageData {
        UsageData(
            serviceId: serviceId,
            serviceType: serviceType,
            serviceName: serviceName,
            usedAmount: 0,
            totalAmount: 1,
            unitLabel: error,
            isUnlimited: true
        )
    }
}
