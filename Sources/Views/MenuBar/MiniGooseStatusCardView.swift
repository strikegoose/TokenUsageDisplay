import SwiftUI
import TokenUsageCore

struct MiniGooseSummaryView: View {
    let status: MiniGooseStatus

    private var text: String {
        if status.lastError != nil {
            if let age = status.lastSuccessAge, age < 600 {
                return "迷你鹅失联 · \(Int(age / 60)) 分钟前有数据"
            }
            return "迷你鹅失联"
        }
        guard let metrics = status.metrics else {
            return status.isFetching ? "迷你鹅连接中" : "迷你鹅等待数据"
        }

        let cpu = percent(metrics.cpuUsagePercent)
        let memory = percent(metrics.memoryUsedPercent)
        let health: String
        if let value = metrics.healthStatus, !value.isEmpty {
            if let failures = metrics.healthFailures, failures > 0 {
                health = "健康 \(value)(\(failures))"
            } else {
                health = "健康 \(value)"
            }
        } else {
            health = "健康 --"
        }
        return "迷你鹅 C\(cpu) · M\(memory) · \(health)"
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(status.severity == .ok ? .secondary : Color(nsColor: .systemOrange))
            .lineLimit(1)
            .help(status.lastError ?? "迷你鹅只读 SSH 指标")
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f%%", min(100, max(0, value)))
    }
}

struct MiniGooseStatusCardView: View {
    let status: MiniGooseStatus
    let onRefresh: () -> Void

    private var metrics: MiniGooseMetrics? {
        status.metrics
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            Divider()
            metricRow(
                title: "CPU",
                value: "\(percent(metrics?.cpuUsagePercent)) · load \(loadText)",
                progress: metrics?.cpuUsagePercent.map { $0 / 100 }
            )
            metricRow(
                title: "内存",
                value: "\(bytes(metrics?.memoryUsedBytes)) / \(bytes(metrics?.memoryTotalBytes)) · Swap \(bytes(metrics?.swapUsedBytes))",
                progress: metrics?.memoryUsedPercent.map { $0 / 100 }
            )
            metricRow(
                title: "磁盘",
                value: "\(percent(metrics?.diskUsedPercent)) · 剩余 \(bytes(metrics?.diskAvailableBytes))",
                progress: metrics?.diskUsedPercent.map { $0 / 100 }
            )
            metricRow(
                title: "网络",
                value: "\(metrics?.networkInterface ?? "--") ↓\(rate(metrics?.rxBytesPerSecond)) ↑\(rate(metrics?.txBytesPerSecond)) · 外网 \(pingText)",
                progress: nil
            )
            HStack {
                Text(healthText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Text("开机 \(duration(metrics?.uptimeSeconds))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            HStack {
                Text(footerText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(status.isFetching ? 360 : 0))
                        .animation(
                            status.isFetching ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                            value: status.isFetching
                        )
                }
                .buttonStyle(.plain)
                .disabled(status.isFetching)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("迷你鹅")
                    .font(.system(size: 13, weight: .semibold))
                Text("CPU / 内存 / 网络 / 中央健康")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if status.lastError != nil {
                Label("失联", systemImage: "wifi.exclamationmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .systemRed), in: RoundedRectangle(cornerRadius: 4))
            } else if status.severity != .ok {
                Label("注意", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .systemYellow), in: RoundedRectangle(cornerRadius: 4))
            } else {
                Label("正常", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private func metricRow(title: String, value: String, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
            }
            if let progress {
                MiniGooseProgressBar(percentage: progress)
            }
        }
    }

    private var loadText: String {
        guard let one = metrics?.load1 else { return "--" }
        let five = metrics?.load5.map { String(format: "%.2f", $0) } ?? "--"
        let fifteen = metrics?.load15.map { String(format: "%.2f", $0) } ?? "--"
        return String(format: "%.2f/%@/%@", one, five, fifteen)
    }

    private var pingText: String {
        guard let ping = metrics?.publicPingMilliseconds else { return "不通" }
        return String(format: "%.0fms", ping)
    }

    private var healthText: String {
        if status.lastError != nil {
            return "中央健康：未知（SSH 失败）"
        }
        guard let value = metrics?.healthStatus, !value.isEmpty else {
            return "中央健康：--"
        }
        var text = "中央健康：\(value)"
        if let failures = metrics?.healthFailures {
            text += "（失败 \(failures)）"
        }
        if let age = metrics?.healthAgeSeconds {
            text += " · \(duration(age))"
        }
        return text
    }

    private var footerText: String {
        if let error = status.lastError {
            return "刷新失败：\(error)"
        }
        guard let date = status.lastSuccessAt else {
            return status.isFetching ? "正在采集…" : "尚未采集"
        }
        return "上次成功 \(FormattingHelpers.formatRelativeTime(from: date))"
    }

    private var statusColor: Color {
        switch status.severity {
        case .ok: return Color(nsColor: .systemGreen)
        case .warning: return Color(nsColor: .systemYellow)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f%%", min(100, max(0, value)))
    }

    private func bytes(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "--" }
        let byte = Double(value)
        if byte >= 1_073_741_824 {
            return String(format: "%.1fGB", byte / 1_073_741_824)
        }
        if byte >= 1_048_576 {
            return String(format: "%.0fMB", byte / 1_048_576)
        }
        return String(format: "%.0fKB", max(0, byte / 1024))
    }

    private func rate(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "--" }
        let byte = Double(value)
        if byte >= 1_048_576 {
            return String(format: "%.1fMB/s", byte / 1_048_576)
        }
        return String(format: "%.0fKB/s", byte / 1024)
    }

    private func duration(_ seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return "--" }
        if seconds < 60 {
            return "\(seconds)秒"
        }
        if seconds < 3600 {
            return "\(seconds / 60)分钟"
        }
        if seconds < 86_400 {
            return "\(seconds / 3600)小时"
        }
        return "\(seconds / 86_400)天"
    }
}

private struct MiniGooseProgressBar: View {
    let percentage: Double

    init(percentage: Double) {
        self.percentage = min(1, max(0, percentage))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: geometry.size.width * percentage)
            }
        }
        .frame(height: 4)
    }
}
