import SwiftUI

/// One card for a service that exposes several quota windows (e.g. Kimi's
/// weekly + 5-hour limits). Keeps multi-window services visually distinct
/// from single-balance cards like DeepSeek.
struct GroupedServiceCardView: View {
    let snapshots: [UsageData]  // same service, one entry per quota window
    var errorMessage: String? = nil
    /// Session dead — offer a 重新登录 button next to the error hint.
    var needsRelogin: Bool = false
    var onRefresh: (() -> Void)?

    @State private var isRefreshing = false

    private var representative: UsageData? { snapshots.first }

    private var baseName: String {
        representative?.serviceName.components(separatedBy: "·").first ?? ""
    }

    private var serviceType: ServiceType { representative?.serviceType ?? .kimi }

    /// The window closest to exhaustion drives the header color and badge.
    private var worst: UsageData? {
        snapshots.max { $0.usagePercentage < $1.usagePercentage }
    }

    private var lastUpdated: Date? {
        snapshots.map(\.lastUpdated).max()
    }

    var body: some View {
        VStack(spacing: 10) {
            headerView

            VStack(spacing: 8) {
                ForEach(snapshots, id: \.serviceId) { snapshot in
                    windowRow(snapshot)
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
                    if needsRelogin {
                        Button("重新登录") { ReloginLauncher.relogin(for: serviceType) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Link(destination: serviceType.usageConsoleURL) {
                HStack(spacing: 8) {
                    Image(systemName: serviceType.sfSymbol)
                        .font(.title3)
                        .foregroundStyle(statusColor(for: worst))
                        .frame(width: 28, height: 28)
                        .background(statusColor(for: worst).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(baseName)
                                .font(.system(size: 13, weight: .semibold))
                            if let worst {
                                StatusIndicator(status: worst.status, size: 6)
                            }
                        }
                        Text("更新于 \(FormattingHelpers.formatRelativeTime(from: lastUpdated ?? Date()))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("打开 \(serviceType.displayName) 官网控制台")

            Spacer()

            if let worst {
                Text(worst.formattedPercentage)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(statusColor(for: worst))
            }

            if let onRefresh {
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
    }

    // MARK: - Window row

    /// Quota windows render as a percentage + progress bar; money rows (加油包
    /// 余额 / 月度加油包) render as a currency value instead — a progress bar on
    /// "¥99.87" makes no sense.
    @ViewBuilder
    private func windowRow(_ snapshot: UsageData) -> some View {
        if isMoneyRow(snapshot) {
            moneyRow(snapshot)
        } else {
            quotaRow(snapshot)
        }
    }

    private func isMoneyRow(_ snapshot: UsageData) -> Bool {
        snapshot.unitLabel == "¥" || snapshot.unitLabel == "$" || snapshot.unitLabel == "CNY"
    }

    private func quotaRow(_ snapshot: UsageData) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(windowLabel(snapshot))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary.opacity(0.85))

                Spacer()

                if let resetTime = snapshot.resetTime {
                    Text("\(Self.resetTimeFormatter.string(from: resetTime)) 重置")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                if snapshot.serviceType == .cursor {
                    Text("剩 \(remainingPercentageText(for: snapshot))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Text(snapshot.serviceType == .cursor ? "已用 \(snapshot.formattedPercentage)" : snapshot.formattedPercentage)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(statusColor(for: snapshot))
            }

            UsageProgressBar(percentage: snapshot.usagePercentage, status: snapshot.status, height: 5)
        }
    }

    /// Money rows: a balance card shows "剩余 / 共" (e.g. ¥99.87 / ¥150.00);
    /// an unlimited spending card shows "已用 … · 无上限".
    private func moneyRow(_ snapshot: UsageData) -> some View {
        HStack(spacing: 6) {
            Text(windowLabel(snapshot))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary.opacity(0.85))

            Spacer()

            if snapshot.isUnlimited {
                Text("已用 \(money(snapshot.usedAmount, unit: snapshot.unitLabel)) · 无上限")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(money(snapshot.remainingAmount, unit: snapshot.unitLabel)) / \(money(snapshot.totalAmount, unit: snapshot.unitLabel))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(statusColor(for: snapshot))
            }
        }
    }

    private func money(_ amount: Double, unit: String) -> String {
        String(format: "%@%.2f", unit, amount)
    }

    private func remainingPercentageText(for snapshot: UsageData) -> String {
        String(format: "%.0f%%", max(0, 1 - snapshot.usagePercentage) * 100)
    }

    private func windowLabel(_ snapshot: UsageData) -> String {
        let parts = snapshot.serviceName.components(separatedBy: "·")
        return parts.count > 1 ? parts.dropFirst().joined(separator: "·") : snapshot.unitLabel
    }

    private func statusColor(for snapshot: UsageData?) -> Color {
        guard let snapshot else { return .primary }
        let remaining = 1.0 - snapshot.usagePercentage
        if remaining <= 0.05 { return Color(nsColor: .systemRed) }
        if remaining <= 0.20 { return Color(nsColor: .systemOrange) }
        return .primary
    }

    private static let resetTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
