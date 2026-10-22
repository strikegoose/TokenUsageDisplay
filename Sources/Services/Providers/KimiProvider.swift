import Foundation
import TokenUsageCore

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
///   "boosterWallet": {"balance": {"type":"BOOSTER","amount":"5000000000","amountLeft":"5000000000"},
///                     "monthlyUsed": {"priceInCents":"0","currency":"CNY"},
///                     "monthlyChargeLimit": {"priceInCents":"0","currency":"CNY"},
///                     "monthlyChargeLimitEnabled": true}
/// }
/// ```
/// 注意：金额/数量字段服务端可能返回字符串也可能返回裸数字（历史上两种都出现过），
/// 解码时必须两种都兼容，见 `flexibleInt`。
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

            enum CodingKeys: String, CodingKey { case priceInCents, currency }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                currency = try c.decodeIfPresent(String.self, forKey: .currency)
                priceInCents = KimiProvider.flexibleInt(c, .priceInCents)
            }
        }
        struct BoosterWallet: Decodable {
            struct Balance: Decodable {
                let type: String?
                let amount: Int?
                let amountLeft: Int?

                enum CodingKeys: String, CodingKey { case type, amount, amountLeft }

                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    type = try c.decodeIfPresent(String.self, forKey: .type)
                    amount = KimiProvider.flexibleInt(c, .amount)
                    amountLeft = KimiProvider.flexibleInt(c, .amountLeft)
                }
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
        let duration: TimeInterval?
    }

    func fetchUsage(apiKey: String) async throws -> [UsageData] {
        guard let token = await KimiAuthManager.accessToken(), !token.isEmpty else {
            throw ServiceError.reauthRequired("未检测到 kimi-code 本地登录，请重新登录")
        }
        do {
            return try await fetchCards(token: token)
        } catch ServiceError.unauthorized {
            // Server rejected the token we thought was valid — force a refresh
            // and retry exactly once before asking the user to re-login.
            guard let fresh = await KimiAuthManager.accessToken(force: true), !fresh.isEmpty else {
                throw ServiceError.reauthRequired("kimi-code 登录态已过期，请重新登录")
            }
            do {
                return try await fetchCards(token: fresh)
            } catch ServiceError.unauthorized {
                throw ServiceError.reauthRequired("kimi-code 登录态已过期，请重新登录")
            }
        }
    }

    private func fetchCards(token: String) async throws -> [UsageData] {
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
            // Internal signal only — fetchUsage turns this into a force-refresh
            // retry or a reauthRequired error.
            throw ServiceError.unauthorized
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

        // 1. Weekly quota (周配额) — rolling 7-day window
        if let usage = decoded.usage, let w = Self.makeWindow(from: usage, label: "周配额", duration: 7 * 86400) {
            cards.append(quotaCard(w, suffix: "weekly"))
        }

        // 2. Rolling windows (5小时窗口 etc.) — duration straight from the API
        for item in decoded.limits ?? [] {
            guard let detail = item.detail,
                  let w = Self.makeWindow(from: detail, label: Self.windowLabel(item.window), duration: Self.windowDuration(item.window)) else { continue }
            let duration = item.window?.duration ?? 0
            cards.append(quotaCard(w, suffix: "win\(duration)"))
        }

        // 3. Monthly membership quota (totalQuota — empty object when not applicable)
        //    Calendar month: window start = reset minus one calendar month.
        if let totalQuota = decoded.totalQuota,
           let parsed = Self.makeWindow(from: totalQuota, label: "月配额", duration: nil) {
            let duration = parsed.resetTime
                .flatMap { Calendar.current.date(byAdding: .month, value: -1, to: $0) }
                .map { parsed.resetTime!.timeIntervalSince($0) }
            let w = WindowUsage(label: parsed.label, used: parsed.used, limit: parsed.limit,
                                resetTime: parsed.resetTime, duration: duration)
            cards.append(quotaCard(w, suffix: "monthly"))
        }

        // 4. Booster wallet balance (加油包余额) — the remaining balance of the
        //    加油包. Kimi reports it as a fixed-point value where 1_000_000 units
        //    == 1 cent (mirrors kimi-code's `fixedPointToCents`): amountLeft is
        //    the balance, amount is the total. Currency derives from the wallet's
        //    money fields (CNY → ¥).
        if let wallet = decoded.boosterWallet {
            let currency = wallet.monthlyUsed?.currency ?? wallet.monthlyChargeLimit?.currency
            let unit = Self.currencySymbol(currency)

            if let balance = wallet.balance, balance.type == "BOOSTER" {
                let totalCents = Self.fixedPointCents(balance.amount)
                let leftCents = Self.fixedPointCents(balance.amountLeft)
                if totalCents > 0 {
                    cards.append(UsageData(
                        serviceId: "\(config.id)#balance",
                        serviceType: config.serviceType,
                        serviceName: "\(config.displayName)·加油包余额",
                        usedAmount: Double(totalCents - leftCents) / 100,
                        totalAmount: Double(totalCents) / 100,
                        unitLabel: unit,
                        isUnlimited: false
                    ))
                }
            }

            // 5. Extra Usage (加油包) monthly spending — money-based, cents
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
                    unitLabel: unit,
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

    /// 解码可能是字符串（"295000"）或裸数字（295000）的整数字段——
    /// 服务端两种形式都返回过，任一解析失败按 nil 处理而不是让整个响应解码炸掉。
    private static func flexibleInt<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let int = try? container.decodeIfPresent(Int.self, forKey: key) { return int }
        if let string = try? container.decodeIfPresent(String.self, forKey: key) { return Int(string) }
        return nil
    }

    /// 加油包余额是定点数：1_000_000 单位 = 1 分（与 kimi-code 的 `fixedPointToCents`
    /// 一致）。转成整数分；极小的正数按 1 分兜底，避免显示 ¥0.00。
    private static func fixedPointCents(_ raw: Int?) -> Int {
        guard let raw, raw > 0 else { return 0 }
        let cents = Double(raw) / 1_000_000
        if cents > 0 && cents < 1 { return 1 }
        return Int(cents.rounded())
    }

    /// ISO 货币代码 → 界面符号（CNY → ¥，USD → $）。
    private static func currencySymbol(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "¥" }
        switch code.uppercased() {
        case "CNY": return "¥"
        case "USD": return "$"
        default: return code
        }
    }

    private func quotaCard(_ window: WindowUsage, suffix: String) -> UsageData {
        UsageData(
            serviceId: "\(config.id)#\(suffix)",
            serviceType: config.serviceType,
            serviceName: "\(config.displayName)·\(window.label)",
            usedAmount: window.used,
            totalAmount: max(window.limit, 1),
            unitLabel: window.label,
            isUnlimited: false,
            resetTime: window.resetTime,
            windowDuration: window.duration
        )
    }

    private static func makeWindow(from quota: UsagesResponse.Quota, label: String, duration: TimeInterval?) -> WindowUsage? {
        let limit = quota.limit.flatMap(Double.init)
        var used = quota.used.flatMap(Double.init)
        if used == nil, let limit, let remaining = quota.remaining.flatMap(Double.init) {
            used = limit - remaining
        }
        guard let used, let limit else { return nil }
        return WindowUsage(label: label, used: used, limit: limit, resetTime: parseResetTime(quota.resetTime), duration: duration)
    }

    /// 滚动窗口时长：复用 core 的 duration+timeUnit → 秒换算（自测直接覆盖）。
    private static func windowDuration(_ window: UsagesResponse.LimitItem.Window?) -> TimeInterval? {
        guard let window else { return nil }
        return QuotaTimeProgress.windowDuration(duration: window.duration ?? 0, timeUnit: window.timeUnit)
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
