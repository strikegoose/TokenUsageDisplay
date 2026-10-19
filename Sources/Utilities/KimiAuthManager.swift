import Foundation

/// Reads Kimi OAuth tokens from local kimi-code configuration files, refreshing
/// the access token itself when it has expired.
///
/// Refresh protocol (mirrors kimi-code CLI, recovered from its binary):
///   POST https://auth.kimi.com/api/oauth/token
///   Content-Type: application/x-www-form-urlencoded
///   client_id=17e5f671-d194-4dfb-9706-5516cb48c098
///   grant_type=refresh_token
///   refresh_token=<stored refresh token>
/// The server rotates the refresh token on every refresh, so the response must
/// be written back to `~/.kimi-code/credentials/kimi-code.json`.
enum KimiAuthManager {

    private static let kimiCodeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".kimi-code")

    private static let credentialFile = kimiCodeDir
        .appendingPathComponent("credentials/kimi-code.json")

    private static let oauthHost = "https://auth.kimi.com"
    private static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    /// Single-flight guard: concurrent callers (and the provider's 401 retry)
    /// join the refresh already in flight instead of starting their own, and
    /// the app never races itself writing rotated credentials.
    private static var inFlightRefresh: Task<String?, Never>?
    private static let refreshStateLock = NSLock()

    private struct Credentials {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    // MARK: - Public

    /// Returns a usable access token, refreshing it first when expired.
    /// `force` skips the local validity check (the provider's 401 retry path:
    /// the server has already rejected the current token).
    /// Returns nil when not authenticated or the refresh token is dead —
    /// the user must run `kimi login` again.
    static func accessToken(force: Bool = false) async -> String? {
        // The token the server just rejected (force path) must not be handed
        // out again from the local re-check below.
        let knownBad = force ? readCredentials()?.accessToken : nil

        if !force, let token = currentValidToken() {
            return token
        }

        let task: Task<String?, Never> = refreshStateLock.withLock {
            if let running = inFlightRefresh {
                return running
            }
            let newTask = Task<String?, Never> {
                await refreshFlow(knownBad: knownBad)
            }
            inFlightRefresh = newTask
            return newTask
        }

        let result = await task.value

        refreshStateLock.withLock { inFlightRefresh = nil }

        return result
    }

    /// Synchronous check used at configuration time: is there any token on
    /// disk (valid or not)? Never touches the network.
    static var isConfigured: Bool {
        if let creds = readCredentials() { return !creds.accessToken.isEmpty }
        return fallbackToken() != nil
    }

    /// The Kimi coding API base URL from config
    static var baseURL: String {
        return "https://api.kimi.com/coding/v1"
    }

    // MARK: - Token reading

    private static func isUsable(_ creds: Credentials) -> Bool {
        guard !creds.accessToken.isEmpty else { return false }
        // Missing expiry means a long-lived/unknown token: use it as-is.
        guard let expiresAt = creds.expiresAt else { return true }
        return expiresAt.timeIntervalSinceNow > 60
    }

    /// The stored access token when it is still valid (60s safety margin),
    /// falling back to legacy non-refreshable sources.
    private static func currentValidToken() -> String? {
        if let creds = readCredentials(), isUsable(creds) {
            return creds.accessToken
        }
        return fallbackToken()
    }

    private static func readCredentials() -> Credentials? {
        guard let data = try? Data(contentsOf: credentialFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else {
            return nil
        }
        var expiresAt: Date?
        if let ts = (json["expires_at"] as? NSNumber)?.doubleValue {
            expiresAt = Date(timeIntervalSince1970: ts)
        }
        return Credentials(
            accessToken: token,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: expiresAt
        )
    }

    /// Non-refreshable token sources kept for backwards compatibility:
    /// `oauth/kimi-code` (raw JWT or JSON) and `server.token`.
    private static func fallbackToken() -> String? {
        let oauthFile = kimiCodeDir.appendingPathComponent("oauth/kimi-code")
        if let content = try? String(contentsOf: oauthFile, encoding: .utf8) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("eyJ") { return trimmed }
            if let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = json["access_token"] as? String, !token.isEmpty {
                return token
            }
        }
        let serverTokenFile = kimiCodeDir.appendingPathComponent("server.token")
        if let token = try? String(contentsOf: serverTokenFile, encoding: .utf8) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - Refresh

    /// Runs as the single in-flight refresh task. Re-checks the file first —
    /// another caller (or a running kimi CLI) may have refreshed already.
    private static func refreshFlow(knownBad: String?) async -> String? {
        if let creds = readCredentials(), creds.accessToken != knownBad,
           isUsable(creds) {
            return creds.accessToken
        }

        guard let refreshToken = readCredentials()?.refreshToken, !refreshToken.isEmpty else {
            print("[KimiAuth] No refresh token on disk; re-login required")
            // Without a refresh token there is nothing to renew; hand back the
            // stale token on the non-force path (server will 401, which then
            // forces the refresh attempt that surfaces re-login).
            return knownBad == nil ? (readCredentials()?.accessToken ?? fallbackToken()) : nil
        }

        switch await performRefresh(refreshToken: refreshToken) {
        case .success:
            print("[KimiAuth] Access token refreshed")
            return readCredentials()?.accessToken
        case .rejected:
            // Refresh token rotated underneath us — a concurrently running
            // kimi CLI refreshed first. Retry once with whatever is on disk now.
            guard let retryToken = readCredentials()?.refreshToken,
                  !retryToken.isEmpty, retryToken != refreshToken else {
                return nil
            }
            if case .success = await performRefresh(refreshToken: retryToken) {
                print("[KimiAuth] Access token refreshed on retry")
                return readCredentials()?.accessToken
            }
            return nil
        case .transient:
            // Network/server hiccup; the next polling cycle retries. The
            // provider treats nil like a dead token and may briefly show the
            // re-login hint — acceptable, it heals itself on the next cycle.
            return nil
        }
    }

    private enum RefreshOutcome {
        case success
        case rejected  // 4xx (e.g. invalid_grant) — refresh token stale or dead
        case transient // network error / 5xx
    }

    /// Only ever runs inside the single-flight task. Writes the rotated
    /// credentials back on success. Never logs token material.
    private static func performRefresh(refreshToken: String) async -> RefreshOutcome {
        guard let url = URL(string: "\(oauthHost)/api/oauth/token") else { return .transient }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let fields = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        request.httpBody = fields
            .map { key, value in
                let escaped = value.addingPercentEncoding(withAllowedCharacters: .urlFormValueAllowed) ?? value
                return "\(key)=\(escaped)"
            }
            .sorted().joined(separator: "&")
            .data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            print("[KimiAuth] Refresh network error: \(error.localizedDescription)")
            return .transient
        }

        guard let http = response as? HTTPURLResponse else { return .transient }
        guard http.statusCode == 200 else {
            print("[KimiAuth] Refresh HTTP \(http.statusCode)")
            return (400..<500).contains(http.statusCode) ? .rejected : .transient
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = json["access_token"] as? String, !newAccess.isEmpty,
              let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty,
              let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0 else {
            print("[KimiAuth] Refresh response missing fields")
            return .transient
        }

        writeBack(response: json, accessToken: newAccess, refreshToken: newRefresh, expiresIn: expiresIn)
        return .success
    }

    /// Persists the rotated credentials, preserving extra fields already in
    /// the file and its 0600 permissions.
    private static func writeBack(response: [String: Any], accessToken: String, refreshToken: String, expiresIn: Double) {
        var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: credentialFile))) as? [String: Any] ?? [:]
        json["access_token"] = accessToken
        json["refresh_token"] = refreshToken
        json["expires_at"] = Date().timeIntervalSince1970 + expiresIn
        json["expires_in"] = expiresIn
        if let scope = response["scope"] { json["scope"] = scope }
        if let type = response["token_type"] { json["token_type"] = type }

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        do {
            try data.write(to: credentialFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialFile.path)
        } catch {
            print("[KimiAuth] Failed to write credentials: \(error.localizedDescription)")
        }
    }
}

private extension CharacterSet {
    /// Form values must not keep "+&=" unescaped (URLSearchParams semantics).
    static let urlFormValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=")
        return set
    }()
}
