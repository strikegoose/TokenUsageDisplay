import SwiftUI

/// Manually creates and manages the settings window for LSUIElement apps.
final class SettingsWindowController: @unchecked Sendable {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hosting = NSHostingController(rootView: settingsView)

        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "TokenUsage 设置"
        newWindow.setContentSize(NSSize(width: 480, height: 400))
        newWindow.styleMask = [.titled, .closable, .miniaturizable]
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.level = .floating

        // When window closes, clean up
        newWindow.delegate = WindowDelegate.shared

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}

private final class WindowDelegate: NSObject, NSWindowDelegate, @unchecked Sendable {
    static let shared = WindowDelegate()

    func windowWillClose(_ notification: Notification) {
        SettingsWindowController.shared.close()
    }
}
