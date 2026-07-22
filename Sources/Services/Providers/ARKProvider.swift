import Foundation

/// ARK (火山方舟) provider.
///
/// Primary mode — 费用中心账户可用余额 via the billing OpenAPI
/// `QueryBalanceAcct`, signed either with an explicit AK/SK from settings
/// (stored as {"ak","sk"} JSON in the key file) or, zero-config, with the
/// STS temporary credentials from arkcli's SSO login.
///
/// Fallback — subscription plan balance via arkcli (only useful for users who
/// actually hold an ARK plan).
struct ARKProvider: ServiceProvider, Sendable {
    let config: ServiceConfiguration

    struct AKSK: Sendable {
        let ak: String
        let sk: String
    }

    func fetchUsage(apiKey: String) async throws -> [UsageData] {
        // Explicit AK/SK from settings wins
        if let creds = Self.parseCredentials(from: apiKey) {
            return try await [fetchAccountBalance(ak: creds.ak, sk: creds.sk, sessionToken: nil)]
        }
        // Zero-config: reuse the STS credentials from arkcli's SSO login
        let executor = ARKCLIExecutor.shared
        if executor.loadSTSCredentials() != nil {
            return try await [fetchAccountBalanceViaSTS(executor)]
        }
        // Legacy fallback: subscription plan balance via arkcli
        return try await [fetchPlanBalance()]
    }

    /// Signs the billing request with arkcli's STS credentials, asking arkcli
    /// to renew them first when they are missing or about to expire.
    private func fetchAccountBalanceViaSTS(_ executor: ARKCLIExecutor) async throws -> UsageData {
        var sts = executor.loadSTSCredentials()
        if sts == nil || sts!.expiresAt.timeIntervalSinceNow < 300 {
            executor.refreshSTSCredentials()
            sts = executor.loadSTSCredentials()
        }
        guard let creds = sts, creds.expiresAt > Date() else {
            throw ARKCLIError.authExpired
        }
        return try await fetchAccountBalance(ak: creds.ak, sk: creds.sk, sessionToken: creds.sessionToken)
    }

    func validateConnection(apiKey: String) async throws -> Bool {
        _ = try await fetchUsage(apiKey: apiKey)
        return true
    }

    // MARK: - Account balance (billing OpenAPI)

    /// Parses the key-file content as {"ak": "...", "sk": "..."} JSON.
    /// Returns nil for empty/plain-string content (legacy or not configured).
    static func parseCredentials(from stored: String) -> AKSK? {
        guard let data = stored.data(using: .utf8),
              let json = try? JSONDecoder().decode([String: String].self, from: data),
              let ak = json["ak"], let sk = json["sk"],
              !ak.isEmpty, !sk.isEmpty else {
            return nil
        }
        return AKSK(ak: ak, sk: sk)
    }

    private func fetchAccountBalance(ak: String, sk: String, sessionToken: String?) async throws -> UsageData {
        let request = VolcSigner.signedGetRequest(
            action: "QueryBalanceAcct",
            version: "2022-01-01",
            service: "billing",
            credentials: .init(ak: ak, sk: sk, sessionToken: sessionToken)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.networkError("Invalid response")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("非 JSON 响应 (HTTP \(httpResponse.statusCode))")
        }

        // Volc reports errors via ResponseMetadata.Error
        if let meta = json["ResponseMetadata"] as? [String: Any],
           let error = meta["Error"] as? [String: Any] {
            let code = error["Code"] as? String ?? ""
            let message = error["Message"] as? String ?? "未知错误"
            throw ServiceError.unknown("费用中心查询失败: \(message) (\(code))")
        }

        guard httpResponse.statusCode == 200 else {
            throw ServiceError.serverError(httpResponse.statusCode)
        }

        guard let balance = Self.findBalance(in: json) else {
            throw ServiceError.parseError("响应中未找到余额字段")
        }

        // Balance-type display: remaining balance, no hard cap
        return UsageData(
            serviceId: config.id,
            serviceType: config.serviceType,
            serviceName: config.displayName,
            usedAmount: 0,
            totalAmount: max(balance, 1),
            unitLabel: "¥",
            isUnlimited: false
        )
    }

    /// Tolerant search for the balance value anywhere in the response tree:
    /// AvailableBalance → CashBalance → Balance (exact key match, case-insensitive).
    private static func findBalance(in json: [String: Any]) -> Double? {
        for key in ["availablebalance", "cashbalance", "balance"] {
            if let value = search(json, forKey: key) { return value }
        }
        return nil
    }

    private static func search(_ value: Any, forKey target: String) -> Double? {
        if let dict = value as? [String: Any] {
            for (k, v) in dict where k.lowercased() == target {
                if let number = v as? Double { return number }
                if let string = v as? String { return Double(string) }
            }
            for (_, v) in dict {
                if let found = search(v, forKey: target) { return found }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let found = search(item, forKey: target) { return found }
            }
        }
        return nil
    }

    // MARK: - Plan balance fallback (arkcli)

    private func fetchPlanBalance() async throws -> UsageData {
        // ARK uses arkcli (SSO-based auth), not a direct API key
        let executor = ARKCLIExecutor.shared

        // Check auth first
        do {
            let authed = try executor.checkAuth()
            if !authed {
                throw ARKCLIError.authExpired
            }
        } catch let error as ARKCLIError {
            throw error
        } catch {
            // Auth check failed for other reasons, try fetching anyway
            print("[ARKProvider] Auth check warning: \(error)")
        }

        let response = try executor.fetchBalance()

        // Aggregate across all plan products and periods
        var totalUsed: Double = 0
        var totalQuota: Double = 0
        var label: String = ""
        var foundData = false

        if let items = response.items {
            for item in items {
                if let periods = item.periods {
                    for period in periods {
                        let used = period.used ?? 0
                        let total = period.total ?? 0
                        if total > 0 {
                            totalUsed += used
                            totalQuota += total
                            label = period.label ?? ""
                            foundData = true
                        }
                    }
                }
            }
        }

        guard foundData, totalQuota > 0 else {
            throw ServiceError.unknown("未检测到 arkcli 登录且账号无订阅套餐。请运行 arkcli auth login volc-sso，或在设置中填入火山引擎 AK/SK")
        }

        return UsageData(
            serviceId: config.id,
            serviceType: config.serviceType,
            serviceName: config.displayName,
            usedAmount: totalUsed,
            totalAmount: totalQuota,
            unitLabel: label.isEmpty ? "tokens" : label,
            isUnlimited: false
        )
    }
}
