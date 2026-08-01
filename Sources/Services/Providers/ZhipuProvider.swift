import Foundation

/// Zhipu GLM Coding Plan provider.
/// Reads the local ZCode API key and queries the same endpoint the official
/// `glm-plan-usage` plugin uses: GET {baseURL}/api/monitor/usage/quota/limit.
///
/// Verified response shape:
/// ```json
/// {"code":200,"msg":"操作成功","data":{
///   "limits":[
///     {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,
///      "currentValue":442,"remaining":1557,"percentage":22,
///      "nextResetTime":1785529141677},
///     {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,
///      "currentValue":620,"remaining":9379,"percentage":6,
///      "nextResetTime":1786069964998}
///   ],
///   "level":"lite"
/// }}
/// ```
/// Each quota limit becomes its own card, mirroring Kimi's multi-window layout.
struct ZhipuProvider: ServiceProvider, Sendable {
    let config: ServiceConfiguration

    private struct QuotaResponse: Decodable {
        let code: Int?
        let data: QuotaData?

        struct QuotaData: Decodable {
            let limits: [Limit]?
            let level: String?
        }

        struct Limit: Decodable {
            let type: String?
            let unit: Int?
            let number: Int?
            let usage: Double?       // total quota
            let currentValue: Double? // used
            let remaining: Double?
            let percentage: Int?      // 0-100
            let nextResetTime: Int64? // epoch ms
        }
    }

    func fetchUsage(apiKey: String) async throws -> [UsageData] {
        // Zhipu authenticates with the raw key (no "Bearer " prefix), unlike DeepSeek.
        guard let key = ZhipuAuthManager.getAPIKey(), !key.isEmpty else {
            throw ServiceError.unknown("未检测到 ZCode 智谱配置，请先在 ZCode 中登录智谱 Coding Plan")
        }

        guard let url = URL(string: "\(ZhipuAuthManager.baseURL)/api/monitor/usage/quota/limit") else {
            throw ServiceError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401:
            throw ServiceError.unknown("智谱 API Key 无效或已过期，请在 ZCode 中重新登录")
        case 429:
            let retry = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ServiceError.rateLimited(retryAfter: retry)
        case 500...599:
            throw ServiceError.serverError(httpResponse.statusCode)
        default:
            throw ServiceError.serverError(httpResponse.statusCode)
        }

        let decoded: QuotaResponse
        do {
            decoded = try JSONDecoder().decode(QuotaResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.parseError("Parse error: \(error). Raw: \(raw.prefix(200))")
        }

        guard decoded.code == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.parseError("API error. Raw: \(msg.prefix(200))")
        }

        var cards: [UsageData] = []
        for (index, limit) in (decoded.data?.limits ?? []).enumerated() {
            guard let used = limit.currentValue, let total = limit.usage, total > 0 else { continue }
            cards.append(UsageData(
                serviceId: "\(config.id)#limit\(index)",
                serviceType: config.serviceType,
                serviceName: "\(config.displayName)·\(Self.limitLabel(for: limit))",
                usedAmount: used,
                totalAmount: total,
                unitLabel: "积分",
                isUnlimited: false,
                resetTime: Self.parseResetTime(limit.nextResetTime)
            ))
        }

        guard !cards.isEmpty else {
            throw ServiceError.parseError("No quota limits in response")
        }
        return cards
    }

    func validateConnection(apiKey: String) async throws -> Bool {
        _ = try await fetchUsage(apiKey: apiKey)
        return true
    }

    // MARK: - Parsing helpers

    /// Maps a limit's unit/number to a human-readable window label.
    /// unit=3 → N-hour rolling window (~5h reset); unit=6 → weekly quota
    /// (~7-day reset, verified from nextResetTime).
    private static func limitLabel(for limit: QuotaResponse.Limit) -> String {
        switch limit.unit {
        case 3:
            let hours = limit.number ?? 5
            return "\(hours)小时额度"
        case 6:
            return "周额度"
        default:
            if let number = limit.number {
                return "额度\(number)"
            }
            return "额度"
        }
    }

    private static func parseResetTime(_ epochMs: Int64?) -> Date? {
        guard let epochMs else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
    }
}
