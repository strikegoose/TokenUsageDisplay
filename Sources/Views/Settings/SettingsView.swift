import SwiftUI

struct SettingsView: View {
    @State private var selectedTab = "general"

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }
                .tag("general")

            ServiceListView()
                .tabItem {
                    Label("服务", systemImage: "server.rack")
                }
                .tag("services")
        }
        .frame(width: 480, height: 440)
    }
}

struct GeneralSettingsView: View {
    @Bindable private var settingsStore = SettingsStore.shared
    @State private var selectedInterval: RefreshInterval = .fiveMinutes
    @State private var miniGooseHost = ""

    enum RefreshInterval: TimeInterval, CaseIterable {
        case oneMinute    = 60
        case fiveMinutes  = 300
        case fifteenMinutes = 900
        case thirtyMinutes  = 1800
        case oneHour       = 3600

        var label: String {
            switch self {
            case .oneMinute:      return "1 分钟"
            case .fiveMinutes:    return "5 分钟"
            case .fifteenMinutes: return "15 分钟"
            case .thirtyMinutes:  return "30 分钟"
            case .oneHour:        return "1 小时"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("自动刷新间隔", selection: $selectedInterval) {
                    ForEach(RefreshInterval.allCases, id: \.rawValue) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .onChange(of: selectedInterval) { _, newValue in
                    settingsStore.settings.refreshIntervalSeconds = newValue.rawValue
                }
                .onAppear {
                    // Match current setting
                    if let match = RefreshInterval.allCases.first(where: { $0.rawValue == settingsStore.settings.refreshIntervalSeconds }) {
                        selectedInterval = match
                    }
                }

                Text("更频繁的刷新可能更快发现额度变化，但也会增加 API 请求次数。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } header: {
                Text("刷新设置")
            }

            Section {
                Toggle("开机自动启动", isOn: Binding(
                    get: { settingsStore.settings.launchAtLogin },
                    set: { newValue in
                        if LaunchAtLoginManager.setEnabled(newValue) {
                            settingsStore.settings.launchAtLogin = newValue
                        } else {
                            // Registration failed or needs manual approval in
                            // System Settings — reflect the real system state.
                            settingsStore.settings.launchAtLogin = LaunchAtLoginManager.isEnabled
                        }
                    }
                ))
                .onAppear {
                    // The login item can also be toggled from System Settings,
                    // so always show the real system status.
                    settingsStore.settings.launchAtLogin = LaunchAtLoginManager.isEnabled
                }

                Toggle("状态栏显示百分比", isOn: $settingsStore.settings.showPercentageInMenuBar)
                Toggle("状态栏显示迷你鹅", isOn: $settingsStore.settings.showMiniGooseInMenuBar)
            } header: {
                Text("显示")
            }

            Section {
                Picker("迷你鹅刷新间隔", selection: $settingsStore.settings.miniGooseRefreshIntervalSeconds) {
                    Text("10 秒").tag(TimeInterval(10))
                    Text("30 秒").tag(TimeInterval(30))
                    Text("1 分钟").tag(TimeInterval(60))
                    Text("5 分钟").tag(TimeInterval(300))
                }

                HStack {
                    TextField("SSH 主机", text: $miniGooseHost)
                    Button("应用") {
                        let trimmed = miniGooseHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        settingsStore.settings.miniGooseHost = trimmed
                        miniGooseHost = trimmed
                    }
                    .disabled(miniGooseHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              miniGooseHost.trimmingCharacters(in: .whitespacesAndNewlines) == settingsStore.settings.miniGooseHost)
                }

                Text("默认使用本机 SSH 配置里的 minigoose 别名；只读采集，不在迷你鹅安装服务。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } header: {
                Text("迷你鹅")
            }
            .onAppear {
                miniGooseHost = settingsStore.settings.miniGooseHost
            }

            Section {
                HStack {
                    Text("版本")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("关于")
            }
        }
        .formStyle(.grouped)
    }
}
