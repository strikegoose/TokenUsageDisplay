import Foundation
import ServiceManagement

/// Registers/unregisters the app as a login item (macOS 13+).
enum LaunchAtLoginManager {
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[LaunchAtLogin] Failed to \(enabled ? "register" : "unregister"): \(error.localizedDescription)")
        }
    }
}
