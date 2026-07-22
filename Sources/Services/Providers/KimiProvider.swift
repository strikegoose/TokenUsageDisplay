import Foundation

/// Kimi Coding Plan provider.
/// Uses the local kimi-code OAuth token to query the same endpoint the CLI's
/// `/usage` command uses: GET {baseURL}/usages.
///
/// Verified response shape:
/// ```json
/// {
///   "usage":  {"limit":"100","used":"45","remaining":"55","resetTime":"2026-07-26T02:11:35.486655Z"},
///   "limits": [{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
///               "detail":{"limit":"100","used":"5","remaining":"95","resetTime":"..."}}],
///   "totalQuota": {},
///   "boosterWallet": {"balance": {"type":"BOOSTER","amount":...,"amountLeft":...},
///                     "monthlyUsed": {"priceInCents":...,"currency":"CNY"},
///                     "monthlyChargeLimit": {"priceInCents":...,"currency":"CNY"},
///                     "monthlyChargeLimitEnabled": true}
/// }
/// ```
/// Each quota window (weekly / rolling 5h / monthly) becomes its own card.
struct KimiProvider: ServiceProvider, Sendable {
    let config: ServiceConfiguration

    private struct UsagesResponse: Decodable {
        struct Quota: Decodable {
            let limit: String?
            let used: String?
            let remaining: String?
            let resetTime: String?
        }
        struct LimitItem: Decodable {
            struct Window: Decodable {
                let duration: Int?
                let timeUnit: String?
            }
            let window: Window?
            let detail: Quota?
        }
        struct Money: Decodable {
            let priceInCents: Int?
            let currency: String?
        }
        struct BoosterWallet: Decodable {
            struct Balance: Decodable {
                let type: String?
                let amount: Int?
                let amountLeft: Int?
            }
            let balance: Balance?
            let monthlyUsed: Money?
            let monthlyChargeLimit: Money?
            let monthlyChargeLimitEnabled: Bool?
        }
        let usage: Quota?
        let limits: [LimitItem]?
        let totalQuota: Quota?
        let boosterWallet: BoosterWallet?
    }

    private struct WindowUsage {
        let label: String
        let used: Double
        let limit: Double
        let resetTime: Date?
    }

    func fetchUsage(apiKey: String) async throws -> [UsageData] {
        guard let token = try? KimiAuthManager.getAccessToken(), !token.isEmpty else {
            throw ServiceError.unknown("未检测到 kimi-code 本地登录，请先运行 kimi CLI 登录")
        }

        guard let url = URL(string: "\(KimiAuthManager.baseURL)/usages") else {
            throw ServiceError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401:
            throw ServiceError.unknown("kimi-code 登录态已过期，请打开一次 kimi CLI 刷新登录")
        case 429:
            throw ServiceError.rateLimited(retryAfter: nil)
        default:
            throw ServiceError.serverError(httpResponse.statusCode)
        }

        let decoded: UsagesResponse
        do {
            decoded = try JSONDecoder().decode(UsagesResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.parseError("Parse error: \(error). Raw: \(raw.prefix(200))")
        }

        var cards: [UsageData] = []

        // 1. Weekly quota (周配额)
        if let usage = decoded.usage, let w = Self.makeWindow(from: usage, label: "周配额") {
            cards.append(quotaCard(w, suffix: "weekly"))
        }

        // 2. Rolling windows (5小时窗口 etc.)
        for item in decoded.limits ?? [] {
            guard let detail = item.detail,
                  let w = Self.makeWindow(from: detail, label: Self.windowLabel(item.window)) else { continue }
            let duration = item.window?.duration ?? 0
            cards.append(quotaCard(w, suffix: "win\(duration)"))
        }

        // 3. Monthly membership quota (totalQuota — empty object when not applicable)
        if let totalQuota = decoded.totalQuota, let w = Self.makeWindow(from: totalQuota, label: "月配额") {
            cards.append(quotaCard(w, suffix: "monthly"))
        }

        // 4. Extra Usage (加油包) monthly spending — money-based, CNY cents
        if let wallet = decoded.boosterWallet {
            let usedCents = wallet.monthlyUsed?.priceInCents ?? 0
            let limitCents = wallet.monthlyChargeLimit?.priceInCents ?? 0
            let hasCap = wallet.monthlyChargeLimitEnabled == true && limitCents > 0
            if usedCents > 0 || hasCap {
                cards.append(UsageData(
                    serviceId: "\(config.id)#booster",
                    serviceType: config.serviceType,
                    serviceName: "\(config.displayName)·月度加油包",
                    usedAmount: Double(usedCents) / 100,
                    totalAmount: hasCap ? Double(limitCents) / 100 : 0,
                    unitLabel: "¥",
                    isUnlimited: !hasCap
                ))
            }
        }

        guard !cards.isEmpty else {
            throw ServiceError.parseError("No usage data in response")
        }
        return cards
    }

    func validateConnection(apiKey: String) async throws -> Bool {
        _ = try await fetchUsage(apiKey: apiKey)
        return true
    }

    // MARK: - Parsing helpers

    private func quotaCard(_ window: WindowUsage, suffix: String) -> UsageData {
        UsageData(
            serviceId: "\(config.id)#\(suffix)",
            serviceType: config.serviceType,
            serviceName: "\(config.displayName)·\(window.label)",
            usedAmount: window.used,
            totalAmount: max(window.limit, 1),
            unitLabel: window.label,
            isUnlimited: false,
            resetTime: window.resetTime
        )
    }

    private static func makeWindow(from quota: UsagesResponse.Quota, label: String) -> WindowUsage? {
        let limit = quota.limit.flatMap(Double.init)
        var used = quota.used.flatMap(Double.init)
        if used == nil, let limit, let remaining = quota.remaining.flatMap(Double.init) {
            used = limit - remaining
        }
        guard let used, let limit else { return nil }
        return WindowUsage(label: label, used: used, limit: limit, resetTime: parseResetTime(quota.resetTime))
    }

    /// Parses "2026-07-26T02:11:35.486655Z" (with or without fractional seconds).
    private static func parseResetTime(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func windowLabel(_ window: UsagesResponse.LimitItem.Window?) -> String {
        guard let duration = window?.duration else { return "滚动窗口" }
        let unit = window?.timeUnit ?? ""
        if unit.contains("MINUTE") {
            if duration >= 60, duration % 60 == 0 { return "\(duration / 60)小时窗口" }
            return "\(duration)分钟窗口"
        }
        if unit.contains("HOUR") { return "\(duration)小时窗口" }
        if unit.contains("DAY") { return "\(duration)天窗口" }
        return "滚动窗口"
    }
}
