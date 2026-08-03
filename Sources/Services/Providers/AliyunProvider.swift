import Foundation

/// 阿里云 provider — 费用中心账户可用余额 via the BSS OpenAPI `QueryAccountBalance`.
///
/// Authenticates with an Access Key / Secret Key pair (stored as {"ak","sk"}
/// JSON in the key file, same shape as ARK). Suggest an RAM sub-account with
/// BSS read-only permission (AliyunBSSReadOnlyAccess) for least privilege.
///
/// Verified response shape (Format=JSON):
/// ```json
/// {"Code":"200","Success":true,"RequestId":"...",
///  "Data":{"AccountId":"123","AccountName":"...",
///          "BalanceAmount":"100.500000","Currency":"CNY",
///          "CreditAmount":"0","MybankCreditAmount":"0"}}
/// ```
struct AliyunProvider: ServiceProvider, Sendable {
    let config: ServiceConfiguration

    struct AKSK: Sendable {
        let ak: String
        let sk: String
    }

    func fetchUsage(apiKey: String) async throws -> [UsageData] {
        guard let creds = Self.parseCredentials(from: apiKey) else {
            throw ServiceError.notConfigured
        }

        let request = AliyunSigner.signedGetRequest(
            action: "QueryAccountBalance",
            version: "2017-12-14",
            credentials: .init(ak: creds.ak, sk: creds.sk)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.networkError("Invalid response")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.parseError("非 JSON 响应 (HTTP \(httpResponse.statusCode)). Raw: \(raw.prefix(200))")
        }

        // Alibaba RPC returns JSON error bodies even on 4xx; success carries Code "200".
        if let code = json["Code"] as? String, code != "200" {
            let message = (json["Message"] as? String) ?? "未知错误"
            if Self.isAuthFailure(code: code, message: message) {
                throw ServiceError.unauthorized
            }
            throw ServiceError.unknown("阿里云查询失败: \(message) (\(code))")
        }

        guard httpResponse.statusCode == 200 else {
            throw ServiceError.serverError(httpResponse.statusCode)
        }

        guard let dataDict = json["Data"] as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.parseError("响应中未找到 Data 字段. Raw: \(raw.prefix(200))")
        }

        // BalanceAmount is the available account balance (a String like "100.500000")
        let balanceString = (dataDict["BalanceAmount"] as? String)
            ?? (dataDict["AvailableAmount"] as? String)
            ?? "0"
        let balance = Double(balanceString) ?? 0
        let currency = (dataDict["Currency"] as? String) ?? "CNY"

        // Balance-type display: remaining balance, no hard cap (mirrors DeepSeek/ARK)
        return [UsageData(
            serviceId: config.id,
            serviceType: config.serviceType,
            serviceName: config.displayName,
            usedAmount: 0,
            totalAmount: balance > 0 ? balance : 1,
            unitLabel: currency == "CNY" ? "¥" : currency,
            isUnlimited: false
        )]
    }

    func validateConnection(apiKey: String) async throws -> Bool {
        _ = try await fetchUsage(apiKey: apiKey)
        return true
    }

    // MARK: - Helpers

    /// Parses the key-file content as {"ak": "...", "sk": "..."} JSON.
    /// Returns nil for empty/plain-string content (not configured).
    static func parseCredentials(from stored: String) -> AKSK? {
        guard let data = stored.data(using: .utf8),
              let json = try? JSONDecoder().decode([String: String].self, from: data),
              let ak = json["ak"], let sk = json["sk"],
              !ak.isEmpty, !sk.isEmpty else {
            return nil
        }
        return AKSK(ak: ak, sk: sk)
    }

    /// Recognizes signature / credential rejections so they surface as "API Key 无效".
    private static func isAuthFailure(code: String, message: String) -> Bool {
        let c = code.lowercased()
        let m = message.lowercased()
        if c.contains("signature") || c.contains("accesskey") || c.contains("forbidden") { return true }
        if m.contains("signature") || m.contains("accesskey") || m.contains("secret") { return true }
        return false
    }
}
