import SwiftUI

@MainActor
@Observable
final class DashboardViewModel {

    private(set) var snapshots: [UsageData] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshDate: Date?
    private(set) var globalError: String?
    /// Last fetch error per service config id — drives the "刷新失败" hint on cards.
    private(set) var serviceErrors: [String: String] = [:]
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

    /// One representative figure per service config, for the menu-bar carousel.
    /// Each config's cards collapse to the value that matters most. Quota-based
    /// services (Kimi / 智谱) yield a used percentage; balance-based services
    /// (DeepSeek / ARK) yield a formatted balance — the carousel renders
    /// `menuBarText` and does not need to know the difference.
    struct ServiceSummary: Identifiable, Equatable {
        let id: String           // config id (without window suffix)
        let serviceType: ServiceType
        let menuBarText: String  // ready-to-show value, e.g. "6%" or "¥59.26"
        let status: ServiceStatus
    }

    var serviceSummaries: [ServiceSummary] {
        // Group by config id (the part before "#")
        var groups: [String: [UsageData]] = [:]
        var order: [String] = []
        for snapshot in snapshots {
            let key = snapshot.serviceId.components(separatedBy: "#").first ?? snapshot.serviceId
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(snapshot)
        }
        return order.compactMap { key in
            guard let cards = groups[key], let first = cards.first else { return nil }
            // A config's overall status is its most severe card
            let status = cards.map(\.status).max { a, b in
                let rank: [ServiceStatus: Int] = [.ok: 0, .warning: 1, .critical: 2, .error: 3]
                return (rank[a] ?? 0) < (rank[b] ?? 0)
            } ?? first.status
            let text = Self.isBalanceMode(cards)
                ? Self.representativeBalanceText(of: cards)
                : "\(Self.representativePercentage(of: cards))%"
            return ServiceSummary(id: key, serviceType: first.serviceType, menuBarText: text, status: status)
        }
    }

    /// A config is "balance mode" when none of its cards track usage — i.e. all
    /// cards report zero used (DeepSeek / ARK store the balance as totalAmount).
    private static func isBalanceMode(_ cards: [UsageData]) -> Bool {
        cards.allSatisfy { $0.usedAmount <= 0 }
    }

    /// The most useful balance to surface: the largest remaining balance among
    /// the config's cards, formatted with its currency/token unit.
    private static func representativeBalanceText(of cards: [UsageData]) -> String {
        let card = cards.max(by: { $0.remainingAmount < $1.remainingAmount }) ?? cards[0]
        let amount = card.remainingAmount
        let unit = card.unitLabel
        if unit == "¥" || unit == "$" || unit == "CNY" {
            return String(format: "%@%.2f", unit, amount)
        }
        if unit == "tokens" {
            return FormattingHelpers.formatTokens(amount)
        }
        return "\(FormattingHelpers.formatTokens(amount)) \(unit)"
    }

    /// The percentage that best represents a single config's pressure:
    /// short rolling windows win, otherwise the highest used percentage.
    private static func representativePercentage(of cards: [UsageData]) -> Int {
        let rolling = cards.filter { $0.serviceId.contains("#win") && !$0.isUnlimited }
        if !rolling.isEmpty {
            return Int((rolling.map(\.usagePercentage).max() ?? 0) * 100)
        }
        let usage = cards.filter { !$0.isUnlimited && $0.totalAmount > 0 }
        if let maxUsed = usage.map(\.usagePercentage).max(), maxUsed > 0 {
            return Int(maxUsed * 100)
        }
        return 0
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
            let errors = await ServiceManager.shared.allLastErrors()
            await MainActor.run {
                model.snapshots = newSnapshots
                model.serviceErrors = errors
                model.lastRefreshDate = Date()
                model.globalError = nil
                model.isRefreshing = false
            }
        }

        // Load existing configs
        await ServiceManager.shared.loadConfigurations()

        // Auto-detect on every launch, not just the first: services whose
        // credentials appeared later (kimi CLI login, Claude Code settings,
        // arkcli install) are picked up automatically. No-op otherwise.
        await AutoConfigDetector.applyAutoConfig()
        await ServiceManager.shared.loadConfigurations()
        let configs = await ServiceManager.shared.allConfigurations()

        // Seed Claude Code provider profiles (DeepSeek + GLM) on first launch,
        // inferring the current DeepSeek token from the live settings.json.
        CCConfigSwitcher.ensureDefaultProfiles()

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
        serviceErrors = await ServiceManager.shared.allLastErrors()
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
