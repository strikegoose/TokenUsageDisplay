import SwiftUI

/// Claude Code provider switching: lists stored profiles, shows which one is
/// live, and switches by rewriting `~/.claude/settings.json`'s env block.
struct CCProfileListView: View {
    @State private var profiles: [CCProviderProfile] = []
    @State private var activeId: String?
    @State private var editingProfile: CCProviderProfile?
    @State private var showAddSheet = false
    @State private var switchError: String?
    @State private var switchSuccessId: String?

    private var hasBackup: Bool {
        FileManager.default.fileExists(atPath: CCConfigSwitcher.backupURL.path)
    }

    var body: some View {
        Form {
            Section {
                if profiles.isEmpty {
                    Text("暂无 profile，点击下方添加。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                ForEach(profiles) { profile in
                    profileRow(profile)
                }
            } header: {
                Text("Claude Code 接入模型")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let activeId, let p = profiles.first(where: { $0.id == activeId }) {
                        Text("当前接入：\(p.name)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    if hasBackup {
                        Text("首次切换已备份原配置至 ~/.config/tokenusage/cc-settings-backup.json")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    if let err = switchError {
                        Text(err)
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    }
                    Text("切换会改写 ~/.claude/settings.json 的 env 块，保留其它设置。切换后新建 Claude Code 会话即生效。")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Button {
                    showAddSheet = true
                } label: {
                    Label("添加 profile", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
        .sheet(isPresented: $showAddSheet) {
            CCProfileFormView { saved in
                profiles.append(saved)
                CCConfigSwitcher.saveProfiles(profiles)
                activeId = CCConfigSwitcher.detectActiveProfile()?.id
            }
        }
        .sheet(item: $editingProfile) { profile in
            CCProfileFormView(existing: profile) { saved in
                if let idx = profiles.firstIndex(where: { $0.id == saved.id }) {
                    profiles[idx] = saved
                    CCConfigSwitcher.saveProfiles(profiles)
                    activeId = CCConfigSwitcher.detectActiveProfile()?.id
                }
            }
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: CCProviderProfile) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .medium))
                    if activeId == profile.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 11))
                    }
                }
                Text(profile.baseURL)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("模型：\(profile.model)\(profile.useZhipuKey ? " · 用 ZCode Key" : "")")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if activeId == profile.id {
                Text("当前")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            } else {
                Button("切换") {
                    do {
                        _ = try CCConfigSwitcher.switchTo(profile)
                        switchError = nil
                        switchSuccessId = profile.id
                        activeId = profile.id
                    } catch {
                        switchError = error.localizedDescription
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Menu {
                Button("编辑") { editingProfile = profile }
                Button("删除", role: .destructive) {
                    profiles.removeAll { $0.id == profile.id }
                    CCConfigSwitcher.saveProfiles(profiles)
                    activeId = CCConfigSwitcher.detectActiveProfile()?.id
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        profiles = CCConfigSwitcher.loadProfiles()
        activeId = CCConfigSwitcher.detectActiveProfile()?.id
    }
}

// MARK: - Profile Form

struct CCProfileFormView: View {
    var existing: CCProviderProfile?
    var onSave: (CCProviderProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var sonnetModel = ""
    @State private var opusModel = ""
    @State private var haikuModel = ""
    @State private var authToken = ""
    @State private var useZhipuKey = false
    @State private var showToken = false

    private var isEditing: Bool { existing != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "编辑 profile" : "添加 profile")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            .padding(16)

            Divider()

            Form {
                Section("基本") {
                    TextField("名称（如 DeepSeek）", text: $name)
                    TextField("Base URL", text: $baseURL)
                        .font(.system(size: 12, design: .monospaced))
                    TextField("模型（ANTHROPIC_MODEL）", text: $model)
                        .font(.system(size: 12, design: .monospaced))
                }

                Section("分档模型（可选，留空则同上）") {
                    TextField("Sonnet 模型", text: $sonnetModel)
                        .font(.system(size: 12, design: .monospaced))
                    TextField("Opus 模型", text: $opusModel)
                        .font(.system(size: 12, design: .monospaced))
                    TextField("Haiku 模型", text: $haikuModel)
                        .font(.system(size: 12, design: .monospaced))
                }

                Section {
                    Toggle("使用 ZCode 的智谱 Key", isOn: $useZhipuKey)
                        .onChange(of: useZhipuKey) { _, on in
                            if on { authToken = "" }
                        }
                    if !useZhipuKey {
                        HStack {
                            Text("Auth Token").font(.system(size: 12))
                            Text("(仅保存时可见)").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        HStack {
                            if showToken {
                                TextField("sk-...", text: $authToken)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                            } else {
                                SecureField(isEditing && authToken.isEmpty ? "输入新 Token" : "sk-...", text: $authToken)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                            }
                            Button(action: { showToken.toggle() }) {
                                Image(systemName: showToken ? "eye.slash" : "eye")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("认证")
                } footer: {
                    Text(useZhipuKey
                         ? "切换时自动从 ~/.zcode/v2/config.json 取智谱 API Key。"
                         : "Token 保存在 ~/.config/tokenusage/cc-profiles.json 中。")
                        .font(.system(size: 10))
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.plain)
                Button("保存") {
                    var p = existing ?? CCProviderProfile(name: "", baseURL: "", model: "")
                    p.name = name.trimmingCharacters(in: .whitespaces)
                    p.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
                    p.model = model.trimmingCharacters(in: .whitespaces)
                    p.sonnetModel = sonnetModel.trimmingCharacters(in: .whitespaces)
                    p.opusModel = opusModel.trimmingCharacters(in: .whitespaces)
                    p.haikuModel = haikuModel.trimmingCharacters(in: .whitespaces)
                    p.authToken = authToken.trimmingCharacters(in: .whitespaces)
                    p.useZhipuKey = useZhipuKey
                    onSave(p)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                          || model.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 540)
        .onAppear {
            if let existing {
                name = existing.name
                baseURL = existing.baseURL
                model = existing.model
                sonnetModel = existing.sonnetModel == existing.model ? "" : existing.sonnetModel
                opusModel = existing.opusModel == existing.model ? "" : existing.opusModel
                haikuModel = existing.haikuModel == existing.model ? "" : existing.haikuModel
                authToken = existing.authToken
                useZhipuKey = existing.useZhipuKey
            }
        }
    }
}
