import SwiftUI

struct MenuBarContentView: View {
    @Environment(DashboardViewModel.self) private var viewModel
    @State private var hoveredServiceId: String?
    @State private var ccProfiles: [CCProviderProfile] = []
    @State private var ccActiveId: String?
    @State private var ccSwitchError: String?

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            if viewModel.snapshots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(snapshotGroups, id: \.key) { group in
                            cardView(for: group.values)
                                .scaleEffect(hoveredServiceId == group.key ? 1.01 : 1.0)
                                .animation(.easeInOut(duration: 0.15), value: hoveredServiceId)
                                .onHover { hovering in
                                    hoveredServiceId = hovering ? group.key : nil
                                }
                        }
                    }
                    .padding(12)
                }
            }

            Divider()

            bottomActions
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 320, idealWidth: 360)
        .background(.ultraThinMaterial)
        .onAppear {
            Task { await viewModel.onAppear() }
            reloadCCProfiles()
        }
    }

    // MARK: - Header

    /// Snapshots grouped by owning service config (window-suffixed ids like
    /// "<configId>#weekly" belong to one card), preserving name sort order.
    private var snapshotGroups: [(key: String, values: [UsageData])] {
        var order: [String] = []
        var groups: [String: [UsageData]] = [:]
        for snapshot in viewModel.snapshots {
            let key = snapshot.serviceId.components(separatedBy: "#").first ?? snapshot.serviceId
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(snapshot)
        }
        // Most urgent window (soonest reset) first; windows without a reset time go last
        return order.map { ($0, groups[$0]!.sorted { ($0.resetTime ?? .distantFuture) < ($1.resetTime ?? .distantFuture) }) }
    }

    @ViewBuilder
    private func cardView(for snapshots: [UsageData]) -> some View {
        let configId = snapshots.first?.serviceId.components(separatedBy: "#").first ?? ""
        let errorMessage = viewModel.serviceErrors[configId]
        if snapshots.count > 1 {
            GroupedServiceCardView(snapshots: snapshots, errorMessage: errorMessage) {
                if let first = snapshots.first {
                    Task { await viewModel.refreshService(first.serviceId) }
                }
            }
        } else if let snapshot = snapshots.first {
            ServiceCardView(snapshot: snapshot, errorMessage: errorMessage) {
                Task { await viewModel.refreshService(snapshot.serviceId) }
            }
        }
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.menuBarSymbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(viewModel.menuBarColor)
                .symbolEffect(.pulse, options: .repeating, isActive: viewModel.isRefreshing)

            VStack(alignment: .leading, spacing: 1) {
                Text("TokenUsage")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(viewModel.serviceCount) 个服务 · \(viewModel.lastRefreshText())")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                ccProviderMenu
            }

            Spacer()

            if viewModel.hasAnyCritical {
                Label("危急", systemImage: "xmark.circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .systemRed), in: RoundedRectangle(cornerRadius: 4))
            } else if viewModel.hasAnyWarning {
                Label("告警", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .systemYellow), in: RoundedRectangle(cornerRadius: 4))
            } else if !viewModel.snapshots.isEmpty {
                Label("正常", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    // MARK: - Claude Code Provider Switch

    /// Inline provider switcher in the popover header. Clicking shows a menu
    /// of stored profiles; selecting one switches immediately.
    private var ccProviderMenu: some View {
        Menu {
            ForEach(ccProfiles) { profile in
                Button {
                    switchTo(profile)
                } label: {
                    if profile.id == ccActiveId {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button("管理…") { SettingsWindowController.shared.show() }
        } label: {
            HStack(spacing: 3) {
                Text("Claude Code：\(activeCCName)")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .font(.system(size: 10))
            .foregroundColor(ccSwitchError != nil ? .red : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var activeCCName: String {
        ccProfiles.first(where: { $0.id == ccActiveId })?.name
            ?? CCConfigSwitcher.activeDisplayName()
    }

    private func switchTo(_ profile: CCProviderProfile) {
        do {
            _ = try CCConfigSwitcher.switchTo(profile)
            ccActiveId = profile.id
            ccSwitchError = nil
        } catch {
            ccSwitchError = error.localizedDescription
        }
    }

    private func reloadCCProfiles() {
        ccProfiles = CCConfigSwitcher.loadProfiles()
        ccActiveId = CCConfigSwitcher.detectActiveProfile()?.id
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.5))
            Text("未配置服务")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text("点击下方设置按钮添加 API 服务")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
            Button("打开设置") {
                SettingsWindowController.shared.show()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(height: 160)
    }

    // MARK: - Bottom Actions

    private var bottomActions: some View {
        HStack(spacing: 16) {
            Button(action: {
                Task { await viewModel.manualRefresh() }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                    Text("刷新")
                        .font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .disabled(viewModel.isRefreshing)

            Spacer()

            Button(action: { SettingsWindowController.shared.show() }) {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                    Text("设置")
                        .font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 11))
                    Text("退出")
                        .font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
    }

}

// MARK: - Auto-fit sizing

/// Auto-fits the menu-bar popover/panel height to the number of service cards
/// so every card is visible without scrolling. The ScrollView only takes over
/// once the list outgrows the screen. Used by StatusBarController (popover)
/// and HotkeyManager (floating panel).
enum MenuBarSizing {
    static let width: CGFloat = 360

    static func contentHeight(for snapshots: [UsageData], serviceErrors: [String: String]) -> CGFloat {
        let header: CGFloat = 52      // header view + divider
        let bottom: CGFloat = 44      // divider + bottom action bar
        let listPadding: CGFloat = 24 // ScrollView VStack .padding(12) × 2
        let groupSpacing: CGFloat = 8 // VStack(spacing: 8) between cards
        let safety: CGFloat = 12      // guard against estimate drift clipping the last card

        var order: [String] = []
        var groups: [String: [UsageData]] = [:]
        for s in snapshots {
            let key = s.serviceId.components(separatedBy: "#").first ?? s.serviceId
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(s)
        }

        var cards: CGFloat = 0
        for key in order { cards += cardHeight(groups[key] ?? [], hasError: serviceErrors[key] != nil) }
        cards += groupSpacing * CGFloat(max(0, order.count - 1))

        let natural = header + listPadding + cards + bottom + safety
        let screenMax = (NSScreen.main?.visibleFrame.height ?? 820) - 60
        return min(max(natural, 300), screenMax)
    }

    /// Estimated height of one card (single or grouped), mirroring the layouts
    /// in ServiceCardView / GroupedServiceCardView. Close enough to never clip;
    /// the ScrollView is the backstop if estimates drift.
    private static func cardHeight(_ group: [UsageData], hasError: Bool) -> CGFloat {
        let pad: CGFloat = 24
        if group.count > 1 {
            let headerRow: CGFloat = 28
            let innerSpacing: CGFloat = 10
            let perWindow: CGFloat = 24
            let windowSpacing: CGFloat = 8
            let n = CGFloat(group.count)
            var h = pad + headerRow + innerSpacing + perWindow * n + windowSpacing * (n - 1)
            // 刷新失败错误行：外层 VStack 间距 + 最多两行 10 号字（约 28pt）
            if hasError { h += innerSpacing + 28 }
            return h
        }
        guard let s = group.first else { return 0 }
        let isBalance = s.usedAmount <= 0
        var h: CGFloat = pad + 28 + 8 + 14   // padding + header row + spacing + detail row
        if !isBalance { h += 8 + 6 }          // progress bar (+ spacing)
        if s.resetTime != nil { h += 8 + 14 } // reset-time row (+ spacing)
        if hasError { h += 8 + 28 }           // 刷新失败错误行 (+ spacing)，最多两行 10 号字
        return h
    }
}
