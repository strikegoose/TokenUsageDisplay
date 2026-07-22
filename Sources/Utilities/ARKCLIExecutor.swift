import Foundation

enum ARKCLIError: LocalizedError {
    case notFound
    case authExpired
    case executionFailed(String)
    case parseError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "找不到 arkcli，请先安装 arkcli"
        case .authExpired:
            return "ARK 登录已过期，请运行: arkcli auth login volc-sso"
        case .executionFailed(let msg):
            return "arkcli 执行失败: \(msg)"
        case .parseError(let msg):
            return "arkcli 输出解析失败: \(msg)"
        case .timeout:
            return "arkcli 命令超时"
        }
    }
}

struct ARKBalanceResponse: Codable, Sendable {
    let ok: Bool?
    let items: [ARKBalanceItem]?
    let error: ARKErrorBody?

    struct ARKErrorBody: Codable, Sendable {
        let type: String?
        let message: String?
    }

    struct ARKBalanceItem: Codable, Sendable {
        let product: String?
        let edition: String?
        let tier: String?
        let periods: [ARKPeriod]?
    }

    struct ARKPeriod: Codable, Sendable {
        let label: String?
        let used: Double?
        let total: Double?
        let percent: Double?
        let resetAt: String?
    }
}

final class ARKCLIExecutor: @unchecked Sendable {
    static let shared = ARKCLIExecutor()

    private let lock = NSLock()
    private var _cachedPath: String?

    private var cachedPath: String? {
        get { lock.withLock { _cachedPath } }
        set { lock.withLock { _cachedPath = newValue } }
    }

    private init() {}

    // MARK: - Path resolution

    /// Extra bin directories arkcli commonly lives in. GUI apps launched from
    /// Finder get a minimal PATH, so nvm/homebrew locations must be checked
    /// explicitly.
    private static func extraBinDirs() -> [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        let nvmRoot = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            // Newest version first
            for version in versions.sorted().reversed() {
                dirs.append("\(nvmRoot)/\(version)/bin")
            }
        }
        return dirs
    }

    func findPath() throws -> String {
        if let cached = cachedPath { return cached }

        var candidates = Self.extraBinDirs()
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: pathEnv.split(separator: ":").map(String.init))
        }

        for dir in candidates {
            let path = "\(dir)/arkcli"
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedPath = path
                return path
            }
        }

        throw ARKCLIError.notFound
    }

    // MARK: - Commands

    func checkAuth() throws -> Bool {
        let output = try execute([
            "auth", "status",
            "--format", "json"
        ])

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        guard let controlPlane = json["control_plane_auth"] as? [String: Any],
              let status = controlPlane["status"] as? String else {
            // Cannot determine — be optimistic and let the actual fetch surface any error
            return true
        }

        switch status {
        case "needs_login", "expired", "invalid", "logged_out":
            return false
        default:
            return true
        }
    }

    func fetchBalance() throws -> ARKBalanceResponse {
        let output = try execute([
            "usage", "balance",
            "--type", "plan",
            "--format", "json"
        ])

        guard let data = output.data(using: .utf8) else {
            throw ARKCLIError.parseError("无法将输出转为数据")
        }

        let response: ARKBalanceResponse
        do {
            response = try JSONDecoder().decode(ARKBalanceResponse.self, from: data)
        } catch {
            print("[ARKCLI] Parse error: \(error)")
            print("[ARKCLI] Raw output: \(output.prefix(500))")
            throw ARKCLIError.parseError(error.localizedDescription)
        }

        // arkcli reports failures as {"ok": false, "error": {...}} — sometimes with exit code 0
        if response.ok == false {
            let message = response.error?.message ?? "未知错误"
            if Self.looksLikeAuthError(message) {
                throw ARKCLIError.authExpired
            }
            throw ARKCLIError.executionFailed(message)
        }

        return response
    }

    // MARK: - STS credentials (from arkcli SSO login)

    struct STSCredentials: Sendable {
        let ak: String
        let sk: String
        let sessionToken: String
        let expiresAt: Date
    }

    /// Reads the STS temporary credentials arkcli stores after SSO login
    /// (~/.arkcli/identities/volc-*/sts.json). When several identities exist,
    /// the one with the latest expiry wins.
    func loadSTSCredentials() -> STSCredentials? {
        let fileManager = FileManager.default
        let identitiesDir = NSHomeDirectory() + "/.arkcli/identities"
        guard let dirs = try? fileManager.contentsOfDirectory(atPath: identitiesDir) else { return nil }

        var best: STSCredentials?
        for dir in dirs where dir.hasPrefix("volc-") {
            let path = "\(identitiesDir)/\(dir)/sts.json"
            guard let data = fileManager.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ak = json["ak"] as? String,
                  let sk = json["sk"] as? String,
                  let token = json["session_token"] as? String,
                  let expiresMs = (json["expires_at"] as? NSNumber)?.doubleValue else { continue }
            let creds = STSCredentials(
                ak: ak, sk: sk, sessionToken: token,
                expiresAt: Date(timeIntervalSince1970: expiresMs / 1000)
            )
            if creds.expiresAt > (best?.expiresAt ?? .distantPast) {
                best = creds
            }
        }
        return best
    }

    /// arkcli renews its STS credentials on any authenticated call;
    /// `auth status` is the cheapest way to force a refresh.
    func refreshSTSCredentials() {
        _ = try? execute(["auth", "status", "--format", "json"])
    }

    // MARK: - Process execution

    private func execute(_ arguments: [String]) throws -> String {
        let path = try findPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Keep the inherited environment; only prepend extra bin dirs to PATH
        // (arkcli is a node script, so node must stay reachable)
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (Self.extraBinDirs() + [existingPath]).joined(separator: ":")
        process.environment = env

        do {
            try process.run()
        } catch {
            throw ARKCLIError.executionFailed(error.localizedDescription)
        }

        // Timeout after 30 seconds
        let deadline = DispatchTime.now() + .seconds(30)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            throw ARKCLIError.timeout
        }

        let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let raw = errorOutput.isEmpty ? output : errorOutput
            let message = Self.extractErrorMessage(from: raw)
                ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.looksLikeAuthError(message) {
                throw ARKCLIError.authExpired
            }
            throw ARKCLIError.executionFailed(message)
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Error helpers

    /// Extracts `error.message` from arkcli's JSON error payloads.
    private static func extractErrorMessage(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String,
              !message.isEmpty else {
            return nil
        }
        return message
    }

    /// Auth failures should get a dedicated error so the UI can tell the user
    /// to re-login instead of showing a generic execution failure.
    private static func looksLikeAuthError(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("auth login")
            || m.contains("needs_login")
            || m.contains("refresh_token")
            || m.contains("not logged")
            || m.contains("volc sso")
            || m.contains("unauthorized")
    }
}
