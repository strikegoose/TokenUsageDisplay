import Foundation

/// 配额窗口的时间进度（与用量无关）：窗口已流逝时长占整个窗口的比例。
/// 纯函数，供菜单栏进度条画「时间标线」用——线落在 elapsed/duration 处，
/// 用量填充超过线 = 用量超前于时间，低于线 = 余量宽松。
public enum QuotaTimeProgress {
    /// 返回钳位在 0...1 的时间比例；duration 非法（<=0 / NaN / 无穷）返回 nil。
    public static func fraction(elapsed: TimeInterval, duration: TimeInterval) -> Double? {
        guard duration.isFinite, duration > 0 else { return nil }
        guard elapsed.isFinite else { return nil }
        return min(1, max(0, elapsed / duration))
    }

    /// 服务端滚动窗口描述（duration 数值 + timeUnit 语义）→ 秒。
    /// duration 非正或 timeUnit 无法识别时返回 nil（该窗口不画时间标线）。
    /// 与 KimiProvider.windowLabel 对同一字段的解释保持一致。
    public static func windowDuration(duration: Int, timeUnit: String?) -> TimeInterval? {
        guard duration > 0 else { return nil }
        let unit = timeUnit ?? ""
        if unit.contains("MINUTE") { return TimeInterval(duration) * 60 }
        if unit.contains("HOUR") { return TimeInterval(duration) * 3600 }
        if unit.contains("DAY") { return TimeInterval(duration) * 86400 }
        return nil
    }
}
