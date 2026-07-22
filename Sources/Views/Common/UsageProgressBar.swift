import SwiftUI

struct UsageProgressBar: View {
    let percentage: Double  // 0.0 ... 1.0
    let status: ServiceStatus
    let height: CGFloat

    init(percentage: Double, status: ServiceStatus, height: CGFloat = 6) {
        self.percentage = min(1, max(0, percentage))
        self.status = status
        self.height = height
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
            }
        }
        .frame(height: height)
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
