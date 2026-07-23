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
        .frame(width: 480, height: 400)
    }
}

struct GeneralSettingsView: View {
    @Bindable private var settingsStore = SettingsStore.shared
    @State private var selectedInterval: RefreshInterval = .fiveMinutes

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
            } header: {
                Text("显示")
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
