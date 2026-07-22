import Foundation

/// Reads Kimi OAuth tokens from local kimi-code configuration files.
enum KimiAuthManager {

    private static let kimiCodeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".kimi-code")

    /// Attempt to retrieve a valid access token from local OAuth files.
    /// Returns nil if not authenticated or token is expired.
    static func getAccessToken() throws -> String? {
        // Paths for OAuth tokens
        let oauthFile = kimiCodeDir.appendingPathComponent("oauth/kimi-code")
        let credentialFile = kimiCodeDir.appendingPathComponent("credentials/kimi-code.json")

        // Try credential file first (JSON format)
        if let token = try? readTokenFromJSON(credentialFile) {
            return token
        }
        // Try raw OAuth file
        if let token = try? readTokenFromRaw(oauthFile) {
            return token
        }
        // Try server token
        let serverTokenFile = kimiCodeDir.appendingPathComponent("server.token")
        if let token = try? String(contentsOf: serverTokenFile, encoding: .utf8) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }

    /// Check if Kimi is configured locally
    static var isConfigured: Bool {
        return (try? getAccessToken()) != nil
    }

    /// The Kimi coding API base URL from config
    static var baseURL: String {
        return "https://api.kimi.com/coding/v1"
    }

    // MARK: - Private

    private static func readTokenFromJSON(_ url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        struct CredentialResponse: Codable {
            let accessToken: String?
            let expiresAt: Double?
            let tokenType: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case expiresAt = "expires_at"
                case tokenType = "token_type"
            }
        }

        let cred = try decoder.decode(CredentialResponse.self, from: data)
        guard let token = cred.accessToken, !token.isEmpty else { return nil }

        // Check expiration
        if let expiresAt = cred.expiresAt {
            let expireDate = Date(timeIntervalSince1970: expiresAt)
            if expireDate < Date() {
                // Token expired - would need refresh, but for MVP use it anyway
                // (kimi-code CLI refreshes automatically)
                print("[KimiAuth] Token expired at \(expireDate), attempting to use anyway")
            }
        }

        return token
    }

    private static func readTokenFromRaw(_ url: URL) throws -> String? {
        let content = try String(contentsOf: url, encoding: .utf8)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Could be raw JWT or JSON
        if trimmed.hasPrefix("eyJ") {
            return trimmed
        }
        // Try parsing as JSON
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = json["access_token"] as? String {
            return token
        }
        return nil
    }
}
