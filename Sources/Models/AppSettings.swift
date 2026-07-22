import Foundation

struct AppSettings: Codable, Sendable {
    var refreshIntervalSeconds: TimeInterval = 300
    var launchAtLogin: Bool = false
    var showPercentageInMenuBar: Bool = true

    static let minRefreshInterval: TimeInterval = 60
    static let maxRefreshInterval: TimeInterval = 3600

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
        didSet { AppSettings.save(settings) }
    }

    private init() {
        self.settings = AppSettings.load()
    }
}
