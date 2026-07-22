import Foundation

actor ServiceManager {
    static let shared = ServiceManager()

    private var configurations: [ServiceConfiguration] = []
    private var snapshots: [String: UsageData] = [:]  // keyed by config.id
    private var pollingTask: Task<Void, Never>?
    private var isRefreshing = false

    private var onUpdate: (@Sendable ([UsageData]) async -> Void)?

    // MARK: - Configuration Management

    func loadConfigurations() {
        let configs = ConfigurationStore.shared.load()
        self.configurations = configs.filter(\.isEnabled)
        // Also load any previously saved snapshots (window-suffixed ids included)
        let cached = ConfigurationStore.shared.loadAllCachedSnapshots()
        for config in self.configurations {
            for snapshot in cached where snapshot.serviceId == config.id
                || snapshot.serviceId.hasPrefix("\(config.id)#") {
                snapshots[snapshot.serviceId] = snapshot
            }
        }
    }

    func addConfiguration(_ config: ServiceConfiguration) {
        configurations.append(config)
        ConfigurationStore.shared.save(configurations: configurations)
    }

    func removeConfiguration(_ id: String) {
        configurations.removeAll { $0.id == id }
        for key in snapshots.keys where key == id || key.hasPrefix("\(id)#") {
            snapshots.removeValue(forKey: key)
        }
        ConfigurationStore.shared.save(configurations: configurations)
        ConfigurationStore.shared.removeCachedSnapshots(for: id)
    }

    func updateConfiguration(_ config: ServiceConfiguration) {
        if let idx = configurations.firstIndex(where: { $0.id == config.id }) {
            configurations[idx] = config
            ConfigurationStore.shared.save(configurations: configurations)
        }
    }

    func allConfigurations() -> [ServiceConfiguration] {
        configurations
    }

    // MARK: - Snapshot Access

    func currentSnapshots() -> [UsageData] {
        // Fixed service order (Kimi → DeepSeek → ARK, as declared in ServiceType),
        // window-suffixed snapshots of one service stay together
        Array(snapshots.values).sorted { lhs, rhs in
            let li = ServiceType.allCases.firstIndex(of: lhs.serviceType) ?? 0
            let ri = ServiceType.allCases.firstIndex(of: rhs.serviceType) ?? 0
            if li != ri { return li < ri }
            return lhs.serviceId < rhs.serviceId
        }
    }

    func snapshot(for id: String) -> UsageData? {
        snapshots[id]
    }

    // MARK: - Fetching

    func setUpdateHandler(_ handler: @Sendable @escaping ([UsageData]) async -> Void) {
        onUpdate = handler
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await withTaskGroup(of: (String, Result<[UsageData], Error>).self) { group in
            for config in configurations {
                group.addTask { [config] in
                    let provider = makeProviderStatic(for: config)
                    do {
                        // API key from file storage, Keychain kept as legacy fallback.
                        // Only DeepSeek needs one; Kimi (OAuth) and ARK (arkcli) manage their own auth.
                        let apiKey = self.resolveAPIKey(for: config)
                        if config.serviceType == .deepseek && apiKey.isEmpty {
                            throw ServiceError.notConfigured
                        }
                        let usages = try await provider.fetchUsage(apiKey: apiKey)
                        return (config.id, .success(usages))
                    } catch {
                        return (config.id, .failure(error))
                    }
                }
            }

            for await (id, result) in group {
                switch result {
                case .success(let usages):
                    // Drop any legacy unsuffixed snapshot for this config
                    // (single-card era stored snapshots under the bare config id)
                    if !usages.contains(where: { $0.serviceId == id }) {
                        snapshots.removeValue(forKey: id)
                        ConfigurationStore.shared.removeCachedSnapshot(for: id)
                    }
                    for usage in usages {
                        snapshots[usage.serviceId] = usage
                        ConfigurationStore.shared.cacheSnapshot(usage)
                    }
                case .failure(let error):
                    print("[ServiceManager] Fetch failed for \(id): \(error.localizedDescription)")
                    // Only surface an error placeholder when this service has no
                    // data at all — transient failures must not clobber good snapshots
                    let hasAnySnapshot = snapshots.keys.contains { $0 == id || $0.hasPrefix("\(id)#") }
                    if !hasAnySnapshot {
                        if let cached = ConfigurationStore.shared.loadCachedSnapshot(for: id) {
                            snapshots[id] = cached
                        } else if let config = configurations.first(where: { $0.id == id }) {
                            snapshots[id] = UsageData.errorPlaceholder(
                                serviceId: id,
                                serviceType: config.serviceType,
                                serviceName: config.displayName,
                                error: error.localizedDescription
                            )
                        }
                    }
                }
            }
        }

        let current = currentSnapshots()
        await onUpdate?(current)
    }

    func refreshService(_ id: String) async {
        // Snapshot ids may carry a window suffix ("<configId>#weekly" etc.)
        let configId = id.components(separatedBy: "#").first ?? id
        guard let config = configurations.first(where: { $0.id == configId }) else { return }
        let provider = makeProvider(for: config)
        do {
            let apiKey = resolveAPIKey(for: config)
            if config.serviceType == .deepseek && apiKey.isEmpty {
                throw ServiceError.notConfigured
            }
            let usages = try await provider.fetchUsage(apiKey: apiKey)
            for usage in usages {
                snapshots[usage.serviceId] = usage
                ConfigurationStore.shared.cacheSnapshot(usage)
            }

            let current = currentSnapshots()
            await onUpdate?(current)
        } catch {
            print("[ServiceManager] Single refresh failed for \(id): \(error)")
        }
    }

    // MARK: - Auto-refresh

    func startPolling(intervalSeconds: TimeInterval) {
        stopPolling()
        let clampedInterval = max(AppSettings.minRefreshInterval, min(intervalSeconds, AppSettings.maxRefreshInterval))
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(for: .seconds(clampedInterval))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Private

    /// DeepSeek keys live in files (Keychain is unreliable for unsigned apps);
    /// Keychain is only consulted as a legacy fallback.
    private nonisolated func resolveAPIKey(for config: ServiceConfiguration) -> String {
        if let fromFile = AutoConfigDetector.readAPIKeyFromFile(for: config), !fromFile.isEmpty {
            return fromFile
        }
        return (try? KeychainManager.shared.read(account: config.keychainAccount)) ?? ""
    }

    private nonisolated func makeProvider(for config: ServiceConfiguration) -> any ServiceProvider {
        switch config.serviceType {
        case .kimi:
            return KimiProvider(config: config)
        case .deepseek:
            return DeepSeekProvider(config: config)
        case .ark:
            return ARKProvider(config: config)
        }
    }
}

// Non-isolated factory for use outside the actor
private func makeProviderStatic(for config: ServiceConfiguration) -> any ServiceProvider {
    switch config.serviceType {
    case .kimi:
        return KimiProvider(config: config)
    case .deepseek:
        return DeepSeekProvider(config: config)
    case .ark:
        return ARKProvider(config: config)
    }
}
