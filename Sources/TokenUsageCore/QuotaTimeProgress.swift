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
}
