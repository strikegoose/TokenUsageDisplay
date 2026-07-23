import SwiftUI

@MainActor
@Observable
final class DashboardViewModel {

    private(set) var snapshots: [UsageData] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshDate: Date?
    private(set) var globalError: String?
    private var settings = SettingsStore.shared.settings

    // MARK: - Computed

    /// Color-coded status text + symbol for the menu bar
    var menuBarText: String {
        guard !snapshots.isEmpty else { return "--" }
        return "\(aggregatePercentage)%"
    }

    var menuBarSymbol: String {
        guard !snapshots.isEmpty else { return "gauge.with.dots.needle.0percent" }
        switch worstStatus {
        case .ok:       return "gauge.with.dots.needle.33percent"
        case .warning:  return "gauge.with.dots.needle.50percent"
        case .critical: return "gauge.with.dots.needle.67percent"
        case .error:    return "exclamationmark.triangle.fill"
        }
    }

    var menuBarColor: Color {
        guard !snapshots.isEmpty else { return .secondary }
        switch worstStatus {
        case .ok:       return .primary
        case .warning:  return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        case .error:    return Color(nsColor: .systemOrange)
        }
    }

    var worstStatus: ServiceStatus {
        snapshots.map(\.status).max { a, b in
            let rank: [ServiceStatus: Int] = [.ok: 0, .warning: 1, .critical: 2, .error: 3]
            return (rank[a] ?? 0) < (rank[b] ?? 0)
        } ?? .ok
    }

    var aggregatePercentage: Int {
        guard !snapshots.isEmpty else { return 0 }
        // Prefer short rolling windows (Kimi's 5-hour limit, id suffix "#win...")
        // over long-term quotas — that's the number that bites first.
        // Select rolling windows by identity, not by current usage: a window
        // sitting at exactly 0% must not silently fall back to the weekly quota.
        // Shows USED percentage (not remaining).
        let rolling = snapshots.filter { $0.serviceId.contains("#win") && !$0.isUnlimited }
        let source: [UsageData]
        if !rolling.isEmpty {
            source = rolling
        } else {
            // For usage-based services, show the worst used percentage
            let usageSnapshots = snapshots.filter { $0.usedAmount > 0 || (!$0.isUnlimited && $0.totalAmount > 0 && $0.usagePercentage > 0) }
            guard !usageSnapshots.isEmpty else {
                // All balance-type services — show OK
                return 100
            }
            source = usageSnapshots
        }
        let maxUsed = source.map(\.usagePercentage).max() ?? 0
        return Int(maxUsed * 100)
    }

    var hasAnyCritical: Bool {
        snapshots.contains { $0.status == .critical }
    }

    var hasAnyWarning: Bool {
        snapshots.contains { $0.status == .warning }
    }

    var serviceCount: Int {
        snapshots.count
    }

    // MARK: - Lifecycle

    private var hasStarted = false

    func onAppear() async {
        // May be triggered from several places (status bar setup, popover open,
        // dashboard window) — only wire everything up once.
        guard !hasStarted else { return }
        hasStarted = true

        let model = self
        await ServiceManager.shared.setUpdateHandler { newSnapshots in
            await MainActor.run {
                model.snapshots = newSnapshots
                model.lastRefreshDate = Date()
                model.globalError = nil
                model.isRefreshing = false
            }
        }

        // Load existing configs
        await ServiceManager.shared.loadConfigurations()
        var configs = await ServiceManager.shared.allConfigurations()

        // Auto-configure on first launch
        if configs.isEmpty {
            await AutoConfigDetector.applyAutoConfig()
            // Reload after auto-config
            await ServiceManager.shared.loadConfigurations()
            configs = await ServiceManager.shared.allConfigurations()
        }

        // Immediately fetch data if we have configured services
        if !configs.isEmpty {
            await ServiceManager.shared.refreshAll()
        }

        snapshots = await ServiceManager.shared.currentSnapshots()
        lastRefreshDate = snapshots.map(\.lastUpdated).max()

        let interval = settings.refreshIntervalSeconds
        await ServiceManager.shared.startPolling(intervalSeconds: interval)
    }

    func manualRefresh() async {
        isRefreshing = true
        globalError = nil
        await ServiceManager.shared.refreshAll()
        // onUpdate handler will set isRefreshing = false
    }

    func refreshService(_ id: String) async {
        await ServiceManager.shared.refreshService(id)
        snapshots = await ServiceManager.shared.currentSnapshots()
    }

    func updateRefreshInterval(_ interval: TimeInterval) {
        settings.refreshIntervalSeconds = interval
        SettingsStore.shared.settings = settings
        Task {
            await ServiceManager.shared.startPolling(intervalSeconds: interval)
        }
    }

    func lastRefreshText() -> String {
        guard let date = lastRefreshDate else { return "未刷新" }
        return FormattingHelpers.formatRelativeTime(from: date)
    }
}
