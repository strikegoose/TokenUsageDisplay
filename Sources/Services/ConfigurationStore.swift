import Foundation

/// Persists service configurations and cached snapshots using JSON files.
/// Uses ~/.config/tokenusage/ as the storage directory.
struct ConfigurationStore: Sendable {

    static let shared = ConfigurationStore()

    private var configDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/tokenusage")
    }

    private var configsFile: URL {
        configDir.appendingPathComponent("configurations.json")
    }

    private func cacheFile(for serviceId: String) -> URL {
        configDir.appendingPathComponent("cache_\(serviceId).json")
    }

    private init() {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    }

    // MARK: - Configurations

    func load() -> [ServiceConfiguration] {
        guard let data = try? Data(contentsOf: configsFile) else { return [] }
        return (try? JSONDecoder().decode([ServiceConfiguration].self, from: data)) ?? []
    }

    func save(configurations: [ServiceConfiguration]) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(configurations) {
            try? data.write(to: configsFile, options: .atomic)
        }
    }

    // MARK: - Cached Snapshots

    func cacheSnapshot(_ snapshot: UsageData) {
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: cacheFile(for: snapshot.serviceId), options: .atomic)
        }
    }

    func loadCachedSnapshot(for serviceId: String) -> UsageData? {
        guard let data = try? Data(contentsOf: cacheFile(for: serviceId)) else { return nil }
        return try? JSONDecoder().decode(UsageData.self, from: data)
    }

    /// All cached snapshots on disk, regardless of id (window-suffixed ids included).
    func loadAllCachedSnapshots() -> [UsageData] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: configDir.path) else { return [] }
        return files.compactMap { file in
            guard file.hasPrefix("cache_"), file.hasSuffix(".json") else { return nil }
            guard let data = try? Data(contentsOf: configDir.appendingPathComponent(file)) else { return nil }
            return try? JSONDecoder().decode(UsageData.self, from: data)
        }
    }

    func removeCachedSnapshot(for serviceId: String) {
        try? FileManager.default.removeItem(at: cacheFile(for: serviceId))
    }

    /// Removes every cache file belonging to a config, window-suffixed ids included.
    func removeCachedSnapshots(for configId: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: configDir.path) else { return }
        for file in files where file.hasPrefix("cache_\(configId)") {
            try? FileManager.default.removeItem(at: configDir.appendingPathComponent(file))
        }
    }
}
