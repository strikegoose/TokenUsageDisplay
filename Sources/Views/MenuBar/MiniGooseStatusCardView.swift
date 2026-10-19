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

    private var cpuHistory: [Double] {
        status.history.compactMap(\.metrics.cpuUsagePercent)
    }

    private var memoryHistory: [Double] {
        status.history.compactMap(\.metrics.memoryUsedPercent)
    }

    private var rxHistory: [Double] {
        status.history.compactMap { sample in
            sample.metrics.rxBytesPerSecond.map(Double.init)
        }
    }

    private var txHistory: [Double] {
        status.history.compactMap { sample in
            sample.metrics.txBytesPerSecond.map(Double.init)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            Divider()
            metricRow(
                title: "CPU",
                value: "\(percent(metrics?.cpuUsagePercent)) · load \(loadText)",
                chart: .cpu
            )
            metricRow(
                title: "内存",
                value: "\(bytes(metrics?.memoryUsedBytes)) / \(bytes(metrics?.memoryTotalBytes)) · Swap \(bytes(metrics?.swapUsedBytes))",
                chart: .memory
            )
            metricRow(
                title: "磁盘",
                value: "\(percent(metrics?.diskUsedPercent)) · 剩余 \(bytes(metrics?.diskAvailableBytes))",
                chart: nil
            )
            metricRow(
                title: "网络",
                value: "\(metrics?.networkInterface ?? "--") ↓\(rate(metrics?.rxBytesPerSecond)) ↑\(rate(metrics?.txBytesPerSecond)) · 外网 \(pingText)",
                chart: .network
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

    private enum MiniGooseMetricChart {
        case cpu
        case memory
        case network
    }

    private func metricRow(title: String, value: String, chart: MiniGooseMetricChart?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
            }
            if let chart {
                chartView(chart)
            } else if let progress = metrics?.diskUsedPercent.map({ $0 / 100 }) {
                MiniGooseProgressBar(percentage: progress)
            }
        }
    }

    private func chartView(_ chart: MiniGooseMetricChart) -> AnyView {
        switch chart {
        case .cpu:
            return AnyView(MiniGooseSparkline(
                values: cpuHistory,
                maxValue: 100,
                color: Color(nsColor: .systemGreen)
            ))
        case .memory:
            return AnyView(MiniGooseSparkline(
                values: memoryHistory,
                maxValue: 100,
                color: Color(nsColor: .systemPurple)
            ))
        case .network:
            return AnyView(MiniGooseDualSparkline(rxValues: rxHistory, txValues: txHistory))
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

/// A tiny Activity-Monitor-style trend line. The data comes from the existing
/// successful SSH polls; drawing the curve itself does not increase polling.
private struct MiniGooseSparkline: View {
    let values: [Double]
    let maxValue: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            if values.count < 2 {
                waitingView
            } else {
                canvas(size: geometry.size)
            }
        }
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private var waitingView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.03))
            Text("曲线采样中 \(values.count)/2")
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }

    private func canvas(size: CGSize) -> some View {
        Canvas { context, _ in
            drawBaseline(in: &context, size: size)
            let points = normalizedPoints(values: values, maxValue: maxValue, size: size)
            let line = Self.pathForTesting(points: points)

            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(color), lineWidth: 1.3)
        }
    }

    private func drawBaseline(in context: inout GraphicsContext, size: CGSize) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
    }

    private func normalizedPoints(values: [Double], maxValue: Double, size: CGSize) -> [CGPoint] {
        let safeMax = max(maxValue, values.max() ?? 0, 0.0001)
        return values.enumerated().map { index, value in
            CGPoint(
                x: size.width * CGFloat(index) / CGFloat(max(1, values.count - 1)),
                y: size.height * (1 - CGFloat(max(0, min(safeMax, value)) / safeMax))
            )
        }
    }

    fileprivate static func pathForTesting(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)

        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }

        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let midpoint = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: midpoint, control: current)
        }
        if let last = points.last {
            path.addLine(to: last)
        }
        return path
    }
}

private struct MiniGooseDualSparkline: View {
    let rxValues: [Double]
    let txValues: [Double]

    var body: some View {
        GeometryReader { geometry in
            if min(rxValues.count, txValues.count) < 2 {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.03))
                    Text("曲线采样中 \(min(rxValues.count, txValues.count))/2")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            } else {
                Canvas { context, size in
                    var baseline = Path()
                    baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
                    baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                    context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)

                    let safeMax = max(
                        rxValues.max() ?? 0,
                        txValues.max() ?? 0,
                        0.0001
                    )
                    draw(
                        rxValues,
                        in: &context,
                        size: size,
                        maxValue: safeMax,
                        color: Color(nsColor: .systemBlue)
                    )
                    draw(
                        txValues,
                        in: &context,
                        size: size,
                        maxValue: safeMax,
                        color: Color(nsColor: .systemOrange)
                    )
                }
            }
        }
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func draw(
        _ values: [Double],
        in context: inout GraphicsContext,
        size: CGSize,
        maxValue: Double,
        color: Color
    ) {
        let points = values.enumerated().map { index, value in
            CGPoint(
                x: size.width * CGFloat(index) / CGFloat(max(1, values.count - 1)),
                y: size.height * (1 - CGFloat(max(0, min(maxValue, value)) / maxValue))
            )
        }
        let path = MiniGooseSparkline.pathForTesting(points: points)
        context.stroke(path, with: .color(color), lineWidth: 1.2)
    }
}
