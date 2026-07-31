import SwiftUI

struct ServiceListView: View {
    @State private var configurations: [ServiceConfiguration] = []
    @State private var showAddSheet = false
    @State private var editingConfig: ServiceConfiguration?

    var body: some View {
        VStack(spacing: 0) {
            if configurations.isEmpty {
                emptyView
            } else {
                List {
                    ForEach(configurations) { config in
                        ServiceRow(config: config) {
                            editingConfig = config
                        }
                    }
                    .onDelete(perform: deleteConfigurations)
                }
                .listStyle(.inset)
            }

            // Bottom bar
            HStack {
                Button(action: { showAddSheet = true }) {
                    Label("添加服务", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
        .onAppear(perform: loadConfigurations)
        .sheet(isPresented: $showAddSheet) {
            ServiceFormView(onSave: { config in
                configurations.append(config)
                Task {
                    await ServiceManager.shared.addConfiguration(config)
                }
                showAddSheet = false
            })
        }
        .sheet(item: $editingConfig) { config in
            ServiceFormView(existingConfig: config) { updatedConfig in
                if let idx = configurations.firstIndex(where: { $0.id == updatedConfig.id }) {
                    configurations[idx] = updatedConfig
                }
                Task {
                    await ServiceManager.shared.updateConfiguration(updatedConfig)
                }
                editingConfig = nil
            }
        }
    }

    private func loadConfigurations() {
        configurations = ConfigurationStore.shared.load()
    }

    private func deleteConfigurations(at offsets: IndexSet) {
        for idx in offsets {
            let config = configurations[idx]
            Task {
                await ServiceManager.shared.removeConfiguration(config.id)
                AutoConfigDetector.deleteAPIKeyFile(for: config)
                try? KeychainManager.shared.delete(account: config.keychainAccount)
            }
        }
        configurations.remove(atOffsets: offsets)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.4))
            VStack(spacing: 4) {
                Text("尚未配置任何服务")
                    .font(.system(size: 16, weight: .medium))
                Text("添加 Kimi、DeepSeek 或 ARK API 来开始监控用量")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Button("添加第一个服务") {
                showAddSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Service Row

struct ServiceRow: View {
    let config: ServiceConfiguration
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: config.serviceType.sfSymbol)
                .font(.title3)
                .foregroundStyle(serviceColor)
                .frame(width: 28, height: 28)
                .background(serviceColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(config.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(config.serviceType.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if config.isEnabled {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
            } else {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var serviceColor: Color {
        switch config.serviceType {
        case .kimi:     return .purple
        case .deepseek: return .blue
        case .ark:      return .orange
        case .zhipu:    return .teal
        }
    }
}
