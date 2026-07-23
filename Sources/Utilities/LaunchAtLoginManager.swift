import Foundation
import ServiceManagement

/// Registers/unregisters the app as a login item (macOS 13+).
enum LaunchAtLoginManager {
    /// Whether the login item is currently active in the system.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers the login item unless it is already registered (possibly
    /// awaiting user approval in System Settings). Used at app launch to
    /// recover a registration lost after the .app was rebuilt or moved.
    static func ensureRegistered() {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            break
        default:
            _ = setEnabled(true)
        }
    }

    /// Returns true on success. When macOS requires the user to approve the
    /// login item manually, opens System Settings → Login Items and returns
    /// false so callers can reflect the real state.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[LaunchAtLogin] Failed to \(enabled ? "register" : "unregister"): \(error)")
            return false
        }
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            NSLog("[LaunchAtLogin] Login item requires approval in System Settings → Login Items")
            SMAppService.openSystemSettingsLoginItems()
            return false
        }
        return true
    }
}
