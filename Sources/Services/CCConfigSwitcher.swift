import Foundation

/// Reads, writes, and switches Claude Code's active provider by rewriting the
/// `env` block of `~/.claude/settings.json` — the single file Claude Code
/// reads to decide its API endpoint and model.
///
/// Unlike CC Switch (which overwrites the whole file), this preserves every
/// non-`env` key already present (e.g. `skipDangerousModePermissionPrompt`),
/// backs up the file before the first switch, and writes atomically.
enum CCConfigSwitcher {

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static let settingsURL = home.appendingPathComponent(".claude/settings.json")
    static let profilesURL = home.appendingPathComponent(".config/tokenusage/cc-profiles.json")
    static let backupURL = home.appendingPathComponent(".config/tokenusage/cc-settings-backup.json")

    // MARK: - Profile persistence

    static func loadProfiles() -> [CCProviderProfile] {
        guard let data = try? Data(contentsOf: profilesURL),
              let profiles = try? JSONDecoder().decode([CCProviderProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    static func saveProfiles(_ profiles: [CCProviderProfile]) {
        try? FileManager.default.createDirectory(at: profilesURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: profilesURL, options: .atomic)
        }
    }

    /// DeepSeek retired the `deepseek-chat` / `deepseek-reasoner` model names
    /// on 2026-07-24. The V4 API now offers `deepseek-v4-flash` and
    /// `deepseek-v4-pro` (V4-Pro-0813, released 2026-08-13); the default for
    /// any DeepSeek profile is the flagship Pro.
    static let deepseekDefaultModel = "deepseek-v4-pro"

    /// The cheap/fast tier: mapped to Claude Code's Haiku slot so `/model`
    /// still offers a low-cost option alongside the Pro default.
    static let deepseekFastModel = "deepseek-v4-flash"

    /// Migrate deprecated DeepSeek model names in stored profiles and in the
    /// live settings.json to the current default. Idempotent.
    static func migrateDeprecatedDeepSeekModels() {
        let deprecated: Set<String> = ["deepseek-chat", "deepseek-reasoner"]

        var profiles = loadProfiles()
        var changed = false
        for i in profiles.indices {
            if deprecated.contains(profiles[i].model) {
                profiles[i].model = deepseekDefaultModel
                changed = true
            }
            for keyPath in [\CCProviderProfile.sonnetModel, \.opusModel, \.haikuModel] {
                if deprecated.contains(profiles[i][keyPath: keyPath]) {
                    profiles[i][keyPath: keyPath] = deepseekDefaultModel
                    changed = true
                }
            }
        }
        if changed { saveProfiles(profiles) }

        // If the live settings.json still points at a retired model, fix it in
        // place — the old names no longer resolve on DeepSeek's API at all.
        guard let live = readLiveEnv(),
              let model = live["ANTHROPIC_MODEL"],
              deprecated.contains(model) else { return }
        var settings = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))) as? [String: Any] ?? [:]
        var envDict = settings["env"] as? [String: Any] ?? [:]
        for key in ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                    "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL"] {
            if let value = envDict[key] as? String, deprecated.contains(value) {
                envDict[key] = deepseekDefaultModel
            }
        }
        settings["env"] = envDict
        if let data = try? JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? writeAtomically(data, to: settingsURL)
        }
    }

    /// Seed the two default profiles on first launch by inferring the current
    /// DeepSeek config straight from the live `settings.json`.
    static func ensureDefaultProfiles() {
        migrateDeprecatedDeepSeekModels()
        guard loadProfiles().isEmpty else { return }

        var deepseekToken = ""
        var deepseekModel = deepseekDefaultModel
        if let live = readLiveEnv(),
           let token = live["ANTHROPIC_AUTH_TOKEN"], !token.isEmpty {
            deepseekToken = token
        }
        if let live = readLiveEnv(),
           let model = live["ANTHROPIC_MODEL"], !model.isEmpty {
            deepseekModel = model
        }

        let deepseek = CCProviderProfile(
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/anthropic",
            model: deepseekModel,
            haikuModel: deepseekFastModel,
            authToken: deepseekToken,
            useZhipuKey: false
        )
        let glm = CCProviderProfile(
            name: "GLM 5.2",
            baseURL: "https://open.bigmodel.cn/api/anthropic",
            model: "glm-5.2",
            useZhipuKey: true
        )
        saveProfiles([deepseek, glm])
    }

    // MARK: - Active detection

    /// Which stored profile the live settings.json currently points at, or nil
    /// when the endpoint/model don't match any stored profile (custom config).
    static func detectActiveProfile() -> CCProviderProfile? {
        guard let live = readLiveEnv(),
              let baseURL = live["ANTHROPIC_BASE_URL"],
              let model = live["ANTHROPIC_MODEL"] else { return nil }
        return loadProfiles().first { $0.matchesLiveEnv(baseURL: baseURL, model: model) }
    }

    /// A short label for the popover: the active profile name, or "自定义".
    static func activeDisplayName() -> String {
        detectActiveProfile()?.name ?? "自定义"
    }

    // MARK: - Switch

    /// Rewrite `~/.claude/settings.json`'s `env` block to the given profile,
    /// preserving all other top-level keys. Backs up the file on first switch.
    @discardableResult
    static func switchTo(_ profile: CCProviderProfile) throws -> CCProviderProfile {
        // Resolve the auth token (may pull from ZCode for GLM profiles).
        let token = profile.resolvedAuthToken
        if token.isEmpty {
            throw NSError(domain: "CCConfigSwitcher", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法解析 API Key（GLM 需先在 ZCode 登录）"])
        }

        // Read the current file. If it doesn't exist, start from an empty object.
        var settings: [String: Any]
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        } else {
            settings = [:]
        }

        // First-switch backup (only when no backup exists yet).
        if !FileManager.default.fileExists(atPath: backupURL.path),
           let existingData = try? Data(contentsOf: settingsURL) {
            try? FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? existingData.write(to: backupURL, options: .atomic)
        }

        // Merge: replace env wholesale, leave every other key untouched.
        var envDict = settings["env"] as? [String: Any] ?? [:]
        for (key, value) in profile.envDict {
            envDict[key] = value
        }
        settings["env"] = envDict

        // Pretty-printed, sorted keys (matches CC Switch's deterministic output).
        let outputData: Data
        do {
            outputData = try JSONSerialization.data(withJSONObject: settings,
                                                    options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw NSError(domain: "CCConfigSwitcher", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "配置序列化失败: \(error.localizedDescription)"])
        }

        // Atomic write via temp file + replaceItem so a crash mid-write can't
        // corrupt the settings file Claude Code depends on.
        do {
            try writeAtomically(outputData, to: settingsURL)
        } catch {
            throw NSError(domain: "CCConfigSwitcher", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "写入 settings.json 失败: \(error.localizedDescription)"])
        }
        return profile
    }

    // MARK: - Private helpers

    /// The live `env` dict from settings.json, or nil if unreadable/absent.
    private static func readLiveEnv() -> [String: String]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any] else { return nil }
        // Coerce values to String (they're always strings in practice).
        return env.mapValues { $0 as? String ?? "\($0)" }
    }

    /// Writes via a sibling temp file then `replaceItem`, so the original file
    /// is either fully updated or untouched — never half-written.
    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tmp) }

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        // Match typical settings.json perms.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
