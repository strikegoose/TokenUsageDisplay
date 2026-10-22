import SwiftUI

struct UsageProgressBar: View {
    let percentage: Double  // 0.0 ... 1.0
    let status: ServiceStatus
    let height: CGFloat
    /// 时间进度 0...1（窗口已流逝比例）；nil = 不画时间标线。
    /// 标线落在 elapsed/duration 处：用量填充超过线 = 用量超前于时间。
    let timeProgress: Double?

    init(percentage: Double, status: ServiceStatus, height: CGFloat = 6, timeProgress: Double? = nil) {
        self.percentage = min(1, max(0, percentage))
        self.status = status
        self.height = height
        self.timeProgress = timeProgress.map { min(1, max(0, $0)) }
    }

    private var barColor: Color {
        // Apple-style: healthy state is grayscale, color only when attention is needed
        let remaining = 1.0 - percentage
        if remaining <= 0.05 { return Color(nsColor: .systemRed) }
        if remaining <= 0.20 { return Color(nsColor: .systemOrange) }
        return Color.primary.opacity(0.75)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.secondary.opacity(0.15))

                // Fill
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(barColor.gradient)
                    .frame(width: geometry.size.width * percentage)

                // Time marker: solid primary reads as darker than the 0.75-opacity
                // fill in light mode and lighter in dark mode, so it stays visible
                // on both the fill and the track without adding a new hue.
                if let timeProgress {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.9))
                        .frame(width: 2, height: height + 2)
                        .position(x: geometry.size.width * timeProgress, y: geometry.size.height / 2)
                }
            }
        }
        .frame(height: height)
        .modifier(TimeMarkerHelp(text: timeProgress == nil ? nil : "竖线 = 时间进度：填充超过线 = 用量偏快，未到线 = 余量宽松"))
    }
}

/// help() with an empty string still pops an empty tooltip, so only apply it
/// when the bar actually carries a time marker.
private struct TimeMarkerHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

struct StatusIndicator: View {
    let status: ServiceStatus
    let size: CGFloat

    init(status: ServiceStatus, size: CGFloat = 8) {
        self.status = status
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: size, height: size)
    }

    private var statusColor: Color {
        switch status {
        case .ok:       return Color(nsColor: .systemGreen)
        case .warning:  return Color(nsColor: .systemYellow)
        case .critical: return Color(nsColor: .systemRed)
        case .error:    return Color(nsColor: .systemOrange)
        }
    }
}
