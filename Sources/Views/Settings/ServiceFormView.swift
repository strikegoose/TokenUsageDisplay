import SwiftUI

struct ServiceFormView: View {
    var existingConfig: ServiceConfiguration?
    var onSave: (ServiceConfiguration) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var serviceType: ServiceType = .kimi
    @State private var displayName: String = ""
    @State private var apiKey: String = ""
    @State private var secretKey: String = ""  // Only for ARK (火山 SK)
    @State private var showApiKey = false

    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSuccess = false

    // Local auth detection
    @State private var kimiAuthAvailable = false
    @State private var arkcliAvailable = false
    @State private var arkAuthValid = false

    private var isEditing: Bool { existingConfig != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "编辑服务" : "添加服务")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            .padding(16)

            Divider()

            Form {
                // Service type picker
                Section {
                    if !isEditing {
                        Picker("服务类型", selection: $serviceType) {
                            ForEach(ServiceType.allCases, id: \.self) { type in
                                HStack {
                                    Image(systemName: type.sfSymbol)
                                    Text(type.displayName)
                                }
                                .tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: serviceType) { _, newType in
                            displayName = newType.displayName
                            checkLocalAuth()
                        }
                    } else {
                        HStack {
                            Text("服务类型")
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: serviceType.sfSymbol)
                                Text(serviceType.displayName)
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("基本信息")
                }

                // Display name
                Section {
                    TextField(serviceType.displayName, text: $displayName)
                        .onAppear {
                            if displayName.isEmpty {
                                displayName = serviceType.displayName
                            }
                        }
                } header: {
                    Text("显示名称")
                }

                // Authentication — varies by service type
                Section {
                    authView
                } header: {
                    Text("认证")
                } footer: {
                    authFooter
                }

                // Test connection
                Section {
                    HStack {
                        Button(action: testConnection) {
                            HStack(spacing: 4) {
                                if isTesting {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "network")
                                }
                                Text("测试连接")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTesting || !canTest)

                        if let result = testResult {
                            HStack(spacing: 4) {
                                Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(testSuccess ? .green : .red)
                                Text(result)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.leading, 8)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear {
                if let config = existingConfig {
                    serviceType = config.serviceType
                    displayName = config.displayName
                    // Load stored credentials (file storage; Keychain is a legacy fallback)
                    if config.serviceType == .deepseek {
                        apiKey = AutoConfigDetector.readAPIKeyFromFile(for: config)
                            ?? (try? KeychainManager.shared.read(account: config.keychainAccount))
                            ?? ""
                    } else if config.serviceType == .ark,
                              let stored = AutoConfigDetector.readAPIKeyFromFile(for: config),
                              let creds = ARKProvider.parseCredentials(from: stored) {
                        apiKey = creds.ak
                        secretKey = creds.sk
                    }
                } else {
                    displayName = serviceType.displayName
                }
                checkLocalAuth()
            }

            Divider()

            // Bottom buttons
            HStack {
                if isEditing {
                    Button("删除服务", role: .destructive) {
                        if let config = existingConfig {
                            Task {
                                await ServiceManager.shared.removeConfiguration(config.id)
                                AutoConfigDetector.deleteAPIKeyFile(for: config)
                                try? KeychainManager.shared.delete(account: config.keychainAccount)
                            }
                        }
                        dismiss()
                    }
                }

                Spacer()

                Button("取消") { dismiss() }
                    .buttonStyle(.plain)

                Button("保存") {
                    saveConfiguration()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 440, height: 420)
    }

    // MARK: - Auth View

    @ViewBuilder
    private var authView: some View {
        switch serviceType {
        case .kimi:
            kimiAuthView
        case .deepseek:
            deepseekAuthView
        case .ark:
            arkAuthView
        }
    }

    private var kimiAuthView: some View {
        HStack {
            Image(systemName: kimiAuthAvailable ? "checkmark.shield.fill" : "xmark.shield.fill")
                .foregroundColor(kimiAuthAvailable ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(kimiAuthAvailable ? "本地 OAuth 认证已就绪" : "未检测到 Kimi 本地认证")
                    .font(.system(size: 13, weight: .medium))
                Text(kimiAuthAvailable
                     ? "使用 ~/.kimi-code/ 中的 OAuth 令牌自动鉴权"
                     : "请先安装并登录 kimi-code CLI 工具")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if kimiAuthAvailable {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 16))
            } else {
                Button("重新检测") { checkLocalAuth() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var deepseekAuthView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("API Key")
                    .font(.system(size: 12, weight: .medium))
                Text("(仅保存时可见，已存 Key 不可回显)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            HStack {
                if showApiKey {
                    TextField("sk-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                } else {
                    SecureField(isEditing && apiKey.isEmpty ? "输入新的 API Key（替换旧 Key）" : "sk-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                }

                Button(action: { showApiKey.toggle() }) {
                    Image(systemName: showApiKey ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
    }

    private var arkAuthView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("火山引擎 AK / SK")
                    .font(.system(size: 12, weight: .medium))
                Text("(用于查询费用中心可用余额)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            HStack {
                if showApiKey {
                    TextField("Access Key (AK 开头)", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                } else {
                    SecureField("Access Key (AK 开头)", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                }

                Button(action: { showApiKey.toggle() }) {
                    Image(systemName: showApiKey ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            SecureField("Secret Key", text: $secretKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
        }
    }

    @ViewBuilder
    private var authFooter: some View {
        switch serviceType {
        case .kimi:
            Text("Kimi Coding Plan 使用本地 OAuth 令牌认证，无需手动输入 API Key。")
                .font(.system(size: 10))
        case .deepseek:
            Text("DeepSeek API Key 仅用于查询余额，保存在 ~/.config/tokenusage/keys/ 下的本地文件中（权限 600）。编辑时如需更换 Key 请直接输入新 Key。")
                .font(.system(size: 10))
        case .ark:
            Text("已登录 arkcli 时自动复用其 SSO 凭证查询费用中心可用余额，无需填写；填入 AK/SK 则优先使用（建议 IAM 子账号 + 费用中心只读权限）。")
                .font(.system(size: 10))
        }
    }

    // MARK: - Computed

    private var canTest: Bool {
        switch serviceType {
        case .kimi:     return kimiAuthAvailable
        case .deepseek: return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .ark:      return (!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            || arkAuthValid
        }
    }

    // MARK: - Actions

    private func checkLocalAuth() {
        switch serviceType {
        case .kimi:
            kimiAuthAvailable = KimiAuthManager.isConfigured
        case .deepseek:
            break
        case .ark:
            arkcliAvailable = (try? ARKCLIExecutor.shared.findPath()) != nil
            arkAuthValid = arkcliAvailable && ((try? ARKCLIExecutor.shared.checkAuth()) ?? false)
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        Task {
            defer { isTesting = false }

            let config = makeConfiguration()
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let sk = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)

            // ARK provider expects the credentials as a JSON payload; others take the plain key
            let credentialPayload: String
            if serviceType == .ark {
                credentialPayload = Self.makeARKCredentialJSON(ak: key, sk: sk)
            } else {
                credentialPayload = key
            }

            let provider = makeProvider(for: config)
            do {
                _ = try await provider.validateConnection(apiKey: credentialPayload)
                await MainActor.run {
                    testSuccess = true
                    testResult = "连接成功"
                }
            } catch {
                await MainActor.run {
                    testSuccess = false
                    testResult = error.localizedDescription
                }
            }
        }
    }

    private func saveConfiguration() {
        let config = makeConfiguration()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let sk = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // File-based storage (Keychain is unreliable for unsigned apps)
        if serviceType == .deepseek && !key.isEmpty {
            AutoConfigDetector.saveAPIKeyToFile(key: key, for: config)
            // Clean up any legacy Keychain entry so it can't go stale
            try? KeychainManager.shared.delete(account: config.keychainAccount)
        } else if serviceType == .ark && !key.isEmpty && !sk.isEmpty {
            AutoConfigDetector.saveAPIKeyToFile(key: Self.makeARKCredentialJSON(ak: key, sk: sk), for: config)
        }

        onSave(config)
    }

    /// Serializes ARK AK/SK as the JSON payload the provider expects.
    private static func makeARKCredentialJSON(ak: String, sk: String) -> String {
        guard let data = try? JSONEncoder().encode(["ak": ak, "sk": sk]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func makeConfiguration() -> ServiceConfiguration {
        let id = existingConfig?.id ?? UUID().uuidString
        return ServiceConfiguration(
            id: id,
            serviceType: serviceType,
            displayName: displayName.trimmingCharacters(in: .whitespaces).isEmpty
                ? serviceType.displayName
                : displayName.trimmingCharacters(in: .whitespaces),
            isEnabled: true
        )
    }

    private func makeProvider(for config: ServiceConfiguration) -> any ServiceProvider {
        switch config.serviceType {
        case .kimi:     return KimiProvider(config: config)
        case .deepseek: return DeepSeekProvider(config: config)
        case .ark:      return ARKProvider(config: config)
        }
    }
}
