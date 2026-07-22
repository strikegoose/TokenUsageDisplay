import Foundation

enum FormattingHelpers {

    static func formatCurrency(amount: Double, currency: String = "¥") -> String {
        if amount >= 10_000 {
            return String(format: "%@%.1f万", currency, amount / 10_000)
        }
        return String(format: "%@%.2f", currency, amount)
    }

    static func formatTokens(_ count: Double) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", count / 1_000_000_000)
        }
        if count >= 1_000_000 {
            return String(format: "%.1fM", count / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", count / 1_000)
        }
        return String(format: "%.0f", count)
    }

    static func formatRelativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "刚刚"
        }
        if interval < 3600 {
            return "\(Int(interval / 60)) 分钟前"
        }
        if interval < 86400 {
            return "\(Int(interval / 3600)) 小时前"
        }
        return "\(Int(interval / 86400)) 天前"
    }

    static func formatRemaining(_ amount: Double, total: Double, unit: String) -> String {
        let used = max(0, total - amount)
        if unit == "tokens" {
            return "\(formatTokens(used)) / \(formatTokens(total)) \(unit)"
        }
        return "\(formatCurrency(amount: amount, currency: unit)) / \(formatCurrency(amount: total, currency: unit))"
    }
}
