import Carbon
import Cocoa
import SwiftUI

/// Registers a global hotkey (Cmd+Shift+T) to show the dashboard even when the menu bar icon is hidden behind the notch.
/// Uses Carbon RegisterEventHotKey which does NOT require Accessibility permissions.
final class HotkeyManager: @unchecked Sendable {

    static let shared = HotkeyManager()

    private var hotkeyRef: EventHotKeyRef?
    private var isRegistered = false
    var onHotkey: (() -> Void)?

    private init() {}

    func register() {
        guard !isRegistered else { return }

        // Cmd+Shift+T
        // Carbon key codes: T = 0x11 (17)
        // Modifiers: cmdKey=256, shiftKey=512
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        // Install handler on the event target
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return -1 }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.onHotkey?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            nil
        )

        // Register hotkey: Cmd+Shift+T
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(cmdKey | shiftKey),
            EventHotKeyID(signature: 0x544F4B55, id: 1), // "TOKU"
            GetEventDispatcherTarget(),
            0,
            &hotkeyRef
        )

        if status == noErr {
            isRegistered = true
            print("[Hotkey] Cmd+Shift+T registered")
        } else {
            print("[Hotkey] Registration failed: \(status)")
        }
    }

    func unregister() {
        guard let ref = hotkeyRef else { return }
        UnregisterEventHotKey(ref)
        hotkeyRef = nil
        isRegistered = false
    }
}

/// Floating dashboard window shown by the global hotkey.
final class DashboardWindowController: @unchecked Sendable {
    static let shared = DashboardWindowController()

    private var window: NSWindow?
    private var viewModel: DashboardViewModel?

    private init() {}

    func setViewModel(_ vm: DashboardViewModel) {
        viewModel = vm
    }

    func toggle() {
        if let existing = window, existing.isVisible {
            existing.close()
            window = nil
            return
        }
        show()
    }

    func show() {
        guard let vm = viewModel else { return }

        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = MenuBarContentView()
            .environment(vm)

        let hosting = NSHostingController(rootView: contentView)

        let newWindow = NSPanel(contentViewController: hosting)
        newWindow.title = "TokenUsage"
        // vm.snapshots is @MainActor-isolated; this UI code always runs on main.
        let panelHeight = MainActor.assumeIsolated { MenuBarSizing.contentHeight(for: vm.snapshots) }
        newWindow.setContentSize(NSSize(width: MenuBarSizing.width, height: panelHeight))
        newWindow.styleMask = [.borderless, .nonactivatingPanel]
        newWindow.isReleasedWhenClosed = false
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.level = .popUpMenu
        newWindow.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        newWindow.hidesOnDeactivate = true
        newWindow.isMovableByWindowBackground = false

        // Position near the menu bar (top center of screen)
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = newWindow.frame
            let x = screenFrame.midX - windowFrame.width / 2
            let y = screenFrame.maxY - windowFrame.height
            newWindow.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Trigger data load
        Task { await vm.onAppear() }
    }

    func close() {
        window?.close()
        window = nil
    }
}
