import Foundation

struct AppSettings: Codable, Sendable {
    var refreshIntervalSeconds: TimeInterval = 300
    var launchAtLogin: Bool = false
    var showPercentageInMenuBar: Bool = true
    var showMiniGooseInMenuBar: Bool = true
    var miniGooseRefreshIntervalSeconds: TimeInterval = 30
    var miniGooseHost: String = "minigoose"

    static let minRefreshInterval: TimeInterval = 60
    static let maxRefreshInterval: TimeInterval = 3600

    enum CodingKeys: String, CodingKey {
        case refreshIntervalSeconds
        case launchAtLogin
        case showPercentageInMenuBar
        case showMiniGooseInMenuBar
        case miniGooseRefreshIntervalSeconds
        case miniGooseHost
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshIntervalSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .refreshIntervalSeconds) ?? 300
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        showPercentageInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showPercentageInMenuBar) ?? true
        showMiniGooseInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showMiniGooseInMenuBar) ?? true
        miniGooseRefreshIntervalSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .miniGooseRefreshIntervalSeconds) ?? 30
        miniGooseHost = try container.decodeIfPresent(String.self, forKey: .miniGooseHost) ?? "minigoose"
    }

    private static var settingsFile: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/tokenusage/settings.json")
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsFile),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    static func save(_ settings: AppSettings) {
        let dir = settingsFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsFile, options: .atomic)
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    var settings: AppSettings {
        didSet {
            AppSettings.save(settings)
            if oldValue.miniGooseHost != settings.miniGooseHost ||
                oldValue.miniGooseRefreshIntervalSeconds != settings.miniGooseRefreshIntervalSeconds {
                onMiniGooseSettingsChanged?()
            }
        }
    }

    /// DashboardViewModel installs this callback so MiniGoose polling picks up
    /// host/interval changes without coupling the settings window to the view model.
    var onMiniGooseSettingsChanged: (() -> Void)?

    private init() {
        self.settings = AppSettings.load()
    }
}
