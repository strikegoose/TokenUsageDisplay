import Foundation

/// Reads the Zhipu (GLM Coding Plan) API key from the local ZCode configuration.
///
/// ZCode stores provider credentials in `~/.zcode/v2/config.json` under
/// `provider["builtin:bigmodel-coding-plan"].options.apiKey`. The same key
/// authenticates the usage-monitoring endpoint.
enum ZhipuAuthManager {

    private static let zcodeConfigFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".zcode/v2/config.json")

    /// The provider key used by ZCode for the GLM Coding Plan.
    static let providerKey = "builtin:bigmodel-coding-plan"

    /// Retrieve the Zhipu API key from the local ZCode config.
    /// Returns nil when the file is missing, the provider isn't configured, or the key is empty.
    static func getAPIKey() -> String? {
        guard let data = try? Data(contentsOf: zcodeConfigFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = json["provider"] as? [String: Any],
              let provider = providers[providerKey] as? [String: Any],
              let options = provider["options"] as? [String: Any],
              let apiKey = options["apiKey"] as? String,
              !apiKey.isEmpty else {
            return nil
        }
        return apiKey
    }

    /// Whether a usable Zhipu API key is available locally.
    static var isConfigured: Bool {
        return getAPIKey() != nil
    }

    /// The Zhipu open-platform base URL.
    static var baseURL: String {
        return "https://open.bigmodel.cn"
    }
}
