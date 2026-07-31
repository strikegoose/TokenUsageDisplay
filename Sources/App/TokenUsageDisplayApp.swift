import SwiftUI
import AppKit

// MARK: - Status Bar Controller (replaces MenuBarExtra for better positioning control)

@MainActor
final class StatusBarController: @unchecked Sendable {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var viewModel: DashboardViewModel?
    private var eventMonitor: Any?

    /// Menu-bar carousel: cycles through services so each one's usage shows
    /// in turn instead of collapsing to a single aggregate.
    private var carouselIndex = 0
    private var carouselTimer: Timer?

    private init() {}

    func setup(with viewModel: DashboardViewModel) {
        self.viewModel = viewModel

        // Create status item in the menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Use autosaveName so macOS remembers position (tends to place new items on the right)
        statusItem.autosaveName = "com.tokenusage.statusitem"

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 500)
        popover.behavior = .transient
        popover.animates = true

        let contentView = MenuBarContentView().environment(viewModel)
        popover.contentViewController = NSHostingController(rootView: contentView)

        refreshIcon()
        observeViewModel()

        // Trigger initial data load
        Task { await viewModel.onAppear() }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        // NOTE: no NSApp.activate here — activating the app makes macOS jump
        // to whatever Space/screen it associates with the app. The popover
        // works fine without it.
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startMonitoringOutsideClicks()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        stopMonitoringOutsideClicks()
    }

    /// A .transient popover only auto-dismisses reliably when the app is
    /// active, which we deliberately avoid (it causes Space switching).
    /// Instead, close on any click that lands outside our own process.
    private func startMonitoringOutsideClicks() {
        stopMonitoringOutsideClicks()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // event.window is non-nil for clicks inside our own app
            // (the popover itself, the status button) — those are fine
            guard event.window == nil else { return }
            self?.closePopover()
        }
    }

    private func stopMonitoringOutsideClicks() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    // MARK: - Icon

    /// Colored dot + the current carousel service's short label and percentage,
    /// rendered as an attributed title so colors survive the menu bar's template
    /// rendering. When only one service exists (or none), this collapses to the
    /// legacy single-value look.
    private func refreshIcon() {
        guard let button = statusItem?.button, let viewModel else { return }

        let summaries = viewModel.serviceSummaries

        // Empty state — just a gray dot.
        if summaries.isEmpty {
            button.attributedTitle = NSAttributedString(string: "●", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 9)
            ])
            stopCarousel()
            return
        }

        // Single service — no need to carousel, show label + percentage.
        if summaries.count == 1 {
            stopCarousel()
            renderServiceIcon(summaries[0])
            return
        }

        // Multiple services — keep the carousel running and render the current slot.
        startCarousel(count: summaries.count)
        let clamped = min(carouselIndex, summaries.count - 1)
        renderServiceIcon(summaries[clamped])
    }

    /// Renders `● <label> <percentage>%` for one service summary.
    private func renderServiceIcon(_ summary: DashboardViewModel.ServiceSummary) {
        // Apple-style: healthy stays monochrome, color means attention needed
        let color: NSColor
        switch summary.status {
        case .ok:       color = .labelColor
        case .warning:  color = .systemOrange
        case .critical: color = .systemRed
        case .error:    color = .systemOrange
        }

        let title = NSMutableAttributedString(string: "●", attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 9)
        ])

        if SettingsStore.shared.settings.showPercentageInMenuBar {
            title.append(NSAttributedString(string: " \(summary.serviceType.shortLabel) \(summary.percentage)%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]))
        }

        statusItem?.button?.attributedTitle = title
    }

    // MARK: - Carousel

    private func startCarousel(count: Int) {
        guard carouselTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let viewModel = self.viewModel else { return }
                let summaries = viewModel.serviceSummaries
                guard summaries.count > 1 else { self.stopCarousel(); return }
                self.carouselIndex = (self.carouselIndex + 1) % summaries.count
                self.renderServiceIcon(summaries[self.carouselIndex])
            }
        }
        // Run on the common mode so it keeps firing while the popover/menu is open.
        RunLoop.main.add(timer, forMode: .common)
        carouselTimer = timer
    }

    private func stopCarousel() {
        carouselTimer?.invalidate()
        carouselTimer = nil
        carouselIndex = 0
    }

    /// Re-render the icon whenever the underlying values change.
    /// `withObservationTracking` fires once, so it re-registers itself.
    private func observeViewModel() {
        withObservationTracking {
            _ = viewModel?.snapshots.count
            _ = viewModel?.aggregatePercentage
            _ = viewModel?.worstStatus
            _ = SettingsStore.shared.settings.showPercentageInMenuBar
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.refreshIcon()
                self?.observeViewModel()
            }
        }
    }
}

// MARK: - App Entry Point

@main
struct TokenUsageDisplayApp: App {
    @State private var viewModel = DashboardViewModel()

    init() {
        // Set up traditional NSStatusBar for better positioning.
        // Auto-config + initial fetch happen in viewModel.onAppear().
        let vm = viewModel
        DispatchQueue.main.async {
            StatusBarController.shared.setup(with: vm)
            DashboardWindowController.shared.setViewModel(vm)

            // Recover the login item if it was enabled but the system
            // registration was lost (e.g. after rebuilding the .app).
            if SettingsStore.shared.settings.launchAtLogin {
                LaunchAtLoginManager.ensureRegistered()
            }
        }

        // Register global hotkey
        HotkeyManager.shared.onHotkey = {
            DashboardWindowController.shared.toggle()
        }
        HotkeyManager.shared.register()
    }

    var body: some Scene {
        // No WindowGroup — a window (even a 1×1 one) anchors the app to a
        // Space/screen and makes macOS jump there on activation.
        // A Settings scene satisfies SwiftUI's scene requirement without
        // creating any window.
        Settings {
            EmptyView()
        }
    }
}
