import Foundation

/// Reads the Cursor login session from the editor's local state database.
///
/// Cursor stores its session in `state.vscdb` (SQLite):
/// - `cursorAuth/accessToken` — a JWT (newer Cursor) or opaque secret
/// - user id — recoverable from `cursorAuth/cachedSignUpId` /
///   `adminSettings.cachedAuthId` (format "auth0|user_…"), or from the JWT
///   `sub` claim, or the legacy token format "user_…%3A%3Atoken".
/// The usage API authenticates via cookie:
/// `WorkosCursorSessionToken={userId}%3A%3A{accessToken}`.
enum CursorAuthManager {

    private static let dbPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        .path

    struct Session: Sendable {
        let userId: String
        let accessToken: String

        /// Cookie value for WorkosCursorSessionToken.
        var cookieValue: String { "\(userId)%3A%3A\(accessToken)" }
    }

    /// Loads the local Cursor session, or nil when Cursor isn't logged in.
    static func loadSession() -> Session? {
        guard let accessToken = queryValue(forKey: "cursorAuth/accessToken"),
              !accessToken.isEmpty else {
            return nil
        }
        return Session(userId: resolveUserId(token: accessToken) ?? "", accessToken: accessToken)
    }

    /// Whether a usable Cursor session exists locally.
    static var isConfigured: Bool {
        loadSession() != nil
    }

    /// The usage API base URL.
    static var baseURL: String {
        return "https://cursor.com"
    }

    // MARK: - User id resolution

    /// Order mirrors how official tooling resolves it: cached auth ids in the
    /// DB first, then the JWT `sub` claim, then the legacy token format.
    private static func resolveUserId(token: String) -> String? {
        for key in ["cursorAuth/cachedSignUpId", "adminSettings.cachedAuthId"] {
            if let raw = queryValue(forKey: key),
               let userId = extractUserId(from: raw) {
                return userId
            }
        }
        if let sub = jwtSubClaim(of: token),
           let userId = extractUserId(from: sub) {
            return userId
        }
        // Legacy token format: "user_xxx%3A%3Atoken" / "user_xxx::token"
        let decoded = token.replacingOccurrences(of: "%3A%3A", with: "::")
        if decoded.contains("::"), let userId = extractUserId(from: String(decoded.split(separator: ":").first ?? "")) {
            return userId
        }
        return nil
    }

    /// Normalizes "auth0|user_…" / "user_…" into a bare "user_…" id.
    private static func extractUserId(from raw: String) -> String? {
        for part in raw.split(separator: "|") where part.hasPrefix("user_") {
            guard part.count > "user_".count else { continue }
            return String(part)
        }
        if raw.hasPrefix("user_") && raw.count > "user_".count {
            return raw
        }
        return nil
    }

    /// Decodes the `sub` claim of a JWT without signature verification
    /// (the claim is only used locally, never trusted for authorization).
    private static func jwtSubClaim(of token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String else {
            return nil
        }
        return sub
    }

    // MARK: - Database access

    /// Reads one value from Cursor's state.vscdb via the system sqlite3 CLI,
    /// opened read-only so the live editor is never disturbed. The key is a
    /// compile-time constant, so embedding it in the SQL text is safe.
    private static func queryValue(forKey key: String) -> String? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", dbPath, "SELECT value FROM ItemTable WHERE key = '\(key)' LIMIT 1;"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stderr so a busy database can't block on a full pipe
        var stderrData = Data()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrData.append(handle.availableData)
        }
        process.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
    }
}
