import Foundation

/// Detects locally available credentials and auto-configures services.
enum AutoConfigDetector {

    // MARK: - DeepSeek API Key

    /// Try to find DeepSeek API key from Claude Code settings (ANTHROPIC_AUTH_TOKEN).
    static func detectDeepSeekAPIKey() -> String? {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        guard let data = try? Data(contentsOf: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: String] else {
            return nil
        }

        // Check if routing through DeepSeek
        guard let baseURL = env["ANTHROPIC_BASE_URL"],
              baseURL.contains("deepseek") else {
            return nil
        }

        // Use ANTHROPIC_AUTH_TOKEN which is the DeepSeek API key
        if let token = env["ANTHROPIC_AUTH_TOKEN"], token.hasPrefix("sk-") {
            return token
        }

        return nil
    }

    // MARK: - Auto-configure All

    struct AutoConfigResult {
        let serviceType: ServiceType
        let displayName: String
        let apiKey: String?       // Only for DeepSeek
        let keychainKey: String?  // Only for DeepSeek
    }

    static func detectAll() -> [AutoConfigResult] {
        var results: [AutoConfigResult] = []

        // 1. Kimi — local OAuth
        if KimiAuthManager.isConfigured {
            results.append(AutoConfigResult(
                serviceType: .kimi,
                displayName: "Kimi",
                apiKey: nil,
                keychainKey: nil
            ))
        }

        // 2. DeepSeek — API key from Claude Code settings
        if let apiKey = detectDeepSeekAPIKey() {
            results.append(AutoConfigResult(
                serviceType: .deepseek,
                displayName: "DeepSeek",
                apiKey: apiKey,
                keychainKey: nil  // Will be set when saving
            ))
        }

        // 3. ARK — arkcli
        if (try? ARKCLIExecutor.shared.findPath()) != nil {
            results.append(AutoConfigResult(
                serviceType: .ark,
                displayName: "ARK",
                apiKey: nil,
                keychainKey: nil
            ))
        }

        return results
    }

    // MARK: - File-based API Key Storage (Keychain unreliable for unsigned apps)

    private static func apiKeyFile(for config: ServiceConfiguration) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/tokenusage/keys")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(config.id).key")
    }

    static func saveAPIKeyToFile(key: String, for config: ServiceConfiguration) {
        let url = apiKeyFile(for: config)
        try? key.write(to: url, atomically: true, encoding: .utf8)
        // Restrict permissions
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func readAPIKeyFromFile(for config: ServiceConfiguration) -> String? {
        let url = apiKeyFile(for: config)
        return try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func deleteAPIKeyFile(for config: ServiceConfiguration) {
        try? FileManager.default.removeItem(at: apiKeyFile(for: config))
    }

    // MARK: - Auto-config

    /// Run auto-detection and save configurations if not already present.
    static func applyAutoConfig() async {
        let existing = ConfigurationStore.shared.load()
        let existingTypes = Set(existing.map(\.serviceType))
        let detected = detectAll()

        for item in detected {
            // Skip if already configured
            guard !existingTypes.contains(item.serviceType) else { continue }

            let config = ServiceConfiguration(
                serviceType: item.serviceType,
                displayName: item.displayName
            )

            // Save API key to file for DeepSeek (Keychain requires code signing)
            if let key = item.apiKey, item.serviceType == .deepseek {
                saveAPIKeyToFile(key: key, for: config)
            }

            // Save configuration
            await ServiceManager.shared.addConfiguration(config)
            print("[AutoConfig] Added \(item.displayName)")
        }

        // Reload and refresh
        await ServiceManager.shared.loadConfigurations()
        await ServiceManager.shared.refreshAll()
    }
}
