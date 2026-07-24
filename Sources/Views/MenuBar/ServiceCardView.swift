import SwiftUI

struct ServiceCardView: View {
    let snapshot: UsageData
    var errorMessage: String? = nil
    var onRefresh: (() -> Void)?

    @State private var isRefreshing = false

    private var isErrorMode: Bool {
        snapshot.isUnlimited && snapshot.totalAmount <= 1 && snapshot.usedAmount <= 0
    }

    private var isBalanceMode: Bool {
        !isErrorMode && (snapshot.serviceType == .deepseek || snapshot.usedAmount <= 0)
    }

    var body: some View {
        if isErrorMode {
            errorCard
        } else {
            dataCard
        }
    }

    private var errorCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: snapshot.serviceType.sfSymbol)
                    .font(.title3)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .frame(width: 28, height: 28)
                    .background(Color(nsColor: .systemOrange).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.serviceName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(snapshot.unitLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Color(nsColor: .systemOrange))
                    .font(.system(size: 14))
            }

            HStack {
                Text("数据获取失败")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if let onRefresh = onRefresh {
                    Button("重试") { onRefresh() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var dataCard: some View {
        VStack(spacing: 8) {
            // Header row
            HStack(spacing: 8) {
                Image(systemName: snapshot.serviceType.sfSymbol)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                    .frame(width: 28, height: 28)
                    .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(snapshot.serviceName)
                            .font(.system(size: 13, weight: .semibold))
                        StatusIndicator(status: snapshot.status, size: 6)
                    }
                    Text("更新于 \(FormattingHelpers.formatRelativeTime(from: snapshot.lastUpdated))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isBalanceMode {
                    // Balance display — plain tabular number, no pill
                    Text(formattedBalance)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                } else {
                    // Usage percentage — plain tabular number, no pill
                    Text(snapshot.formattedPercentage)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(statusColor)
                }

                if let onRefresh = onRefresh {
                    Button(action: {
                        isRefreshing = true
                        onRefresh()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            isRefreshing = false
                        }
                    }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                            .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Progress bar (only for usage-based services)
            if !isBalanceMode {
                UsageProgressBar(percentage: snapshot.usagePercentage, status: snapshot.status)
            }

            // Detail row
            HStack {
                if isBalanceMode {
                    Text("余额")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                } else if snapshot.isUnlimited {
                    Text("已用 \(formattedUsed) \(snapshot.unitLabel)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("无上限")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text("剩余 \(formattedRemaining) \(snapshot.unitLabel)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("共 \(formattedTotal) \(snapshot.unitLabel)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            // Reset time (quota windows that carry one, e.g. Kimi weekly / 5h)
            if let resetTime = snapshot.resetTime {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("\(Self.resetTimeFormatter.string(from: resetTime)) 后重置")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            // Last fetch failure — the numbers above are stale when this shows
            if let errorMessage {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Color(nsColor: .systemOrange))
                    Text("刷新失败：\(errorMessage)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private static let resetTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private var formattedBalance: String {
        let amount = snapshot.remainingAmount
        let unit = snapshot.unitLabel
        if unit == "¥" || unit == "$" || unit == "CNY" {
            return String(format: "%@%.2f", unit, amount)
        }
        return "\(FormattingHelpers.formatTokens(amount)) \(unit)"
    }

    private var statusColor: Color {
        let remaining = 1.0 - snapshot.usagePercentage
        if remaining <= 0.05 { return Color(nsColor: .systemRed) }
        if remaining <= 0.20 { return Color(nsColor: .systemOrange) }
        return .primary
    }

    private var formattedRemaining: String {
        formatAmount(snapshot.remainingAmount)
    }

    private var formattedTotal: String {
        formatAmount(snapshot.totalAmount)
    }

    private var formattedUsed: String {
        formatAmount(snapshot.usedAmount)
    }

    private func formatAmount(_ amount: Double) -> String {
        switch snapshot.unitLabel {
        case "¥", "$", "CNY":
            return FormattingHelpers.formatCurrency(amount: amount, currency: "")
        default:
            // "tokens" and quota labels (周配额 / 小时窗口 etc.) read best as plain counts
            return FormattingHelpers.formatTokens(amount)
        }
    }
}
