import Foundation

/// A Claude Code provider profile. One complete `settings.json` env block maps
/// to one profile; switching providers rewrites that block while preserving
/// every other key in the file.
struct CCProviderProfile: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    var model: String
    var sonnetModel: String
    var opusModel: String
    var haikuModel: String
    /// Auth token for `ANTHROPIC_AUTH_TOKEN`. Empty when `useZhipuKey` is on —
    /// the key is then resolved from `~/.zcode` at switch time.
    var authToken: String
    var useZhipuKey: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String,
        model: String,
        sonnetModel: String = "",
        opusModel: String = "",
        haikuModel: String = "",
        authToken: String = "",
        useZhipuKey: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        // Empty tier slots fall back to the default model at write time.
        self.sonnetModel = sonnetModel.isEmpty ? model : sonnetModel
        self.opusModel = opusModel.isEmpty ? model : opusModel
        self.haikuModel = haikuModel.isEmpty ? model : haikuModel
        self.authToken = authToken
        self.useZhipuKey = useZhipuKey
    }

    /// The env block written into `settings.json` on switch.
    var envDict: [String: String] {
        [
            "ANTHROPIC_BASE_URL": baseURL,
            "ANTHROPIC_AUTH_TOKEN": resolvedAuthToken,
            "ANTHROPIC_MODEL": model,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": sonnetModel,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": opusModel,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": haikuModel,
        ]
    }

    /// Picks the real token: ZCode's GLM key when `useZhipuKey` is on.
    var resolvedAuthToken: String {
        if useZhipuKey {
            return ZhipuAuthManager.getAPIKey() ?? ""
        }
        return authToken
    }

    /// Two profiles are "the same provider" if their endpoint + model match —
    /// used to detect which stored profile the live settings.json points at.
    func matchesLiveEnv(baseURL: String, model: String) -> Bool {
        self.baseURL == baseURL && self.model == model
    }
}
