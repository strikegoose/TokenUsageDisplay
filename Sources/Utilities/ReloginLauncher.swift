import AppKit

/// Launches the interactive re-login flow for services whose session has
/// expired (Kimi / ARK). The login command runs in a visible Terminal window
/// via a temporary .command file — both flows need user interaction (browser
/// SSO / device code), and this needs no AppleScript automation permission.
enum ReloginLauncher {

    /// Whether this service type has a known re-login command at all.
    static func canRelogin(_ serviceType: ServiceType) -> Bool {
        switch serviceType {
        case .kimi, .ark: return true
        default: return false
        }
    }

    /// Opens Terminal running the service's login command.
    static func relogin(for serviceType: ServiceType) {
        guard let command = loginCommand(for: serviceType) else { return }

        let script = """
        #!/bin/zsh
        echo "正在启动登录流程，请按提示完成登录（可能会在浏览器中操作）…"
        echo ""
        \(command)
        echo ""
        echo "登录流程已结束，可关闭此窗口。回到 TokenUsage 点「重试」即可恢复。"

        """

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenusage-relogin-\(serviceType.rawValue).command")
        do {
            try script.write(to: fileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.path)
            NSWorkspace.shared.open(fileURL)
        } catch {
            print("[Relogin] Failed to launch login command: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    /// Absolute path when resolvable (Terminal starts a fresh shell whose PATH
    /// may differ from the app's), falling back to the bare command name.
    private static func loginCommand(for serviceType: ServiceType) -> String? {
        switch serviceType {
        case .kimi:
            let cli = NSHomeDirectory() + "/.kimi-code/bin/kimi"
            let path = FileManager.default.isExecutableFile(atPath: cli) ? cli : "kimi"
            return "\(quoted(path)) login"
        case .ark:
            let path = (try? ARKCLIExecutor.shared.findPath()) ?? "arkcli"
            return "\(quoted(path)) auth login volc-sso"
        default:
            return nil
        }
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
