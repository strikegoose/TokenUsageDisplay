import SwiftUI

/// Manually creates and manages the settings window for LSUIElement apps.
final class SettingsWindowController: @unchecked Sendable {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let existing = window, existing.isVisible {
            place(existing)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hosting = NSHostingController(rootView: settingsView)

        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "TokenUsage 设置"
        let contentSize = NSSize(width: 480, height: 440)
        newWindow.setContentSize(contentSize)
        newWindow.styleMask = [.titled, .closable, .miniaturizable]
        newWindow.isReleasedWhenClosed = false
        newWindow.isRestorable = false
        place(newWindow)
        newWindow.level = .floating

        // When window closes, clean up
        newWindow.delegate = WindowDelegate.shared

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// LSUIElement windows are not tied to a visible document. Prefer the
    /// screen that currently contains the mouse, so the settings window can
    /// never be restored/centered onto an inactive display.
    private func place(_ window: NSWindow) {
        window.setContentSize(NSSize(width: 480, height: 440))

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }

        let size = window.frame.size
        let x = visibleFrame.midX - size.width / 2
        let y = visibleFrame.midY - size.height / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func close() {
        // Clear the reference first: closing the window re-enters this method
        // via windowWillClose, and a non-nil window would recurse until the
        // stack overflows (SIGSEGV).
        let closing = window
        window = nil
        closing?.close()
    }
}

private final class WindowDelegate: NSObject, NSWindowDelegate, @unchecked Sendable {
    static let shared = WindowDelegate()

    func windowWillClose(_ notification: Notification) {
        SettingsWindowController.shared.close()
    }
}
