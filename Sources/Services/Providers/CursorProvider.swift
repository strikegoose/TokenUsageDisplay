import Foundation

/// Cursor (cursor.com) provider.
/// Reads the local Cursor login session and queries the same endpoint the
/// official dashboard uses: GET {baseURL}/api/usage-summary with cookie
/// `WorkosCursorSessionToken={userId}%3A%3A{accessToken}`.
///
/// Verified response shape (individual Pro):
/// ```json
/// {"billingCycleStart":"2026-07-22T05:21:55.000Z","billingCycleEnd":"…",
///  "membershipType":"pro","limitType":"user","isUnlimited":false,
///  "autoModelSelectedDisplayMessage":"You've used 23% of your included total usage",
///  "namedModelSelectedDisplayMessage":"You've used 0% of your included API usage",
///  "individualUsage":{"plan":{"enabled":true,"used":2000,"limit":2000,"remaining":0,
///    "breakdown":{"included":2000,"bonus":6076,"total":8076},
///    "autoPercentUsed":26.92,"apiPercentUsed":0,"totalPercentUsed":23.41},
///   "onDemand":{"enabled":false,"used":0,"limit":null,"remaining":null}},
///  "teamUsage":{}}
/// ```
/// Individual plans get Auto/API quota-pool cards; team plans get a single
/// $ used/$ limit card. Per-model spend is intentionally omitted: Cursor's
/// spend endpoint has no quota ceiling, which makes it both slow to fetch and
/// confusing in a quota dashboard.
struct CursorProvider: ServiceProvider, Sendable {
    let config: ServiceConfiguration

    private struct UsageSummaryResponse: Decodable {
        let billingCycleStart: String?
        let billingCycleEnd: String?
        let membershipType: String?
        let individualUsage: IndividualUsage?
        let teamUsage: TeamUsage?

        struct IndividualUsage: Decodable {
            let plan: Plan?
            let onDemand: OnDemand?
        }

        struct TeamUsage: Decodable {
            let onDemand: OnDemand?
        }

        struct Plan: Decodable {
            let enabled: Bool?
            let used: Double?
            let limit: Double?
            let breakdown: Breakdown?
            let autoPercentUsed: Double?      // 0-100
            let apiPercentUsed: Double?       // 0-100
            let totalPercentUsed: Double?     // 0-100
        }

        struct Breakdown: Decodable {
            let included: Double?
            let bonus: Double?
            let total: Double?
        }

        struct OnDemand: Decodable {
            let enabled: Bool?
            let used: Double?
            let usedCents: Double?
            let limit: Double?
        }
    }

    func fetchUsage(apiKey: String) async throws -> [UsageData] {
        guard let session = CursorAuthManager.loadSession() else {
            throw ServiceError.unknown("未检测到 Cursor 登录态，请先在 Cursor 中登录账号")
        }

        guard let url = URL(string: "\(CursorAuthManager.baseURL)/api/usage-summary") else {
            throw ServiceError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("WorkosCursorSessionToken=\(session.cookieValue)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(CursorAuthManager.baseURL, forHTTPHeaderField: "Origin")
        request.setValue("\(CursorAuthManager.baseURL)/dashboard/usage", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401:
            throw ServiceError.reauthRequired("Cursor 登录已过期，请打开 Cursor 重新登录账号")
        case 429:
            let retry = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ServiceError.rateLimited(retryAfter: retry)
        default:
            throw ServiceError.serverError(httpResponse.statusCode)
        }

        let decoded: UsageSummaryResponse
        do {
            decoded = try JSONDecoder().decode(UsageSummaryResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.parseError("Parse error: \(error). Raw: \(raw.prefix(200))")
        }

        let resetTime = Self.parseDate(decoded.billingCycleEnd)

        // Team / Enterprise: usage is a dollar figure (cents or dollars), not pool percents
        let teamOnDemand = decoded.teamUsage?.onDemand
        let teamUsed = teamOnDemand?.used ?? teamOnDemand?.usedCents.map { $0 / 100 }
        if teamUsed != nil {
            let teamLimit = teamOnDemand?.limit
            return [UsageData(
                serviceId: "\(config.id)#team",
                serviceType: config.serviceType,
                serviceName: "\(config.displayName)·团队用量",
                usedAmount: teamUsed ?? 0,
                totalAmount: teamLimit ?? max(teamUsed ?? 0, 1),
                unitLabel: "$",
                isUnlimited: teamLimit == nil,
                resetTime: resetTime
            )]
        }

        guard let plan = decoded.individualUsage?.plan, plan.enabled != false else {
            throw ServiceError.parseError("No usage data in response")
        }

        var cards: [UsageData] = []
        // Auto pool: quota used out of included + bonus. The API's percentage
        // is authoritative (counts against included first), so derive used
        // from it rather than from the raw used/limit numbers.
        let autoPercent = plan.autoPercentUsed.map { max(0, min(100, $0)) }
        // breakdown.total can be 0 right after a billing-cycle reset (included/
        // bonus not yet credited); fall back to the plan limit so the pool
        // still renders instead of reporting a parse error.
        let breakdownTotal = plan.breakdown?.total ?? 0
        let autoTotal = breakdownTotal > 0 ? breakdownTotal : (plan.limit ?? 0)
        if let percent = autoPercent, autoTotal > 0 {
            cards.append(UsageData(
                serviceId: "\(config.id)#auto",
                serviceType: config.serviceType,
                serviceName: "\(config.displayName)·Auto 池",
                usedAmount: autoTotal * percent / 100,
                totalAmount: autoTotal,
                unitLabel: "%",
                isUnlimited: false,
                resetTime: resetTime
            ))
        }
        // API pool: named-model API credits — hidden while unused
        if let apiPercent = plan.apiPercentUsed.map({ max(0, min(100, $0)) }), apiPercent > 0 {
            cards.append(UsageData(
                serviceId: "\(config.id)#api",
                serviceType: config.serviceType,
                serviceName: "\(config.displayName)·API 池",
                usedAmount: apiPercent,
                totalAmount: 100,
                unitLabel: "%",
                isUnlimited: false,
                resetTime: resetTime
            ))
        }

        // On-demand spending (auto-recharge), if the user turned it on
        let onDemand = decoded.individualUsage?.onDemand
        let onDemandUsed = onDemand?.used ?? onDemand?.usedCents.map { $0 / 100 }
        if onDemand?.enabled == true, let used = onDemandUsed {
            cards.append(UsageData(
                serviceId: "\(config.id)#ondemand",
                serviceType: config.serviceType,
                serviceName: "\(config.displayName)·按量支出",
                usedAmount: used,
                totalAmount: onDemand?.limit ?? 0,
                unitLabel: "$",
                isUnlimited: onDemand?.limit == nil,
                resetTime: resetTime
            ))
        }

        guard !cards.isEmpty else {
            throw ServiceError.parseError("No quota pools in response")
        }
        return cards
    }

    func validateConnection(apiKey: String) async throws -> Bool {
        _ = try await fetchUsage(apiKey: apiKey)
        return true
    }

    // MARK: - Parsing helpers

    /// Parses "2026-08-22T05:21:55.000Z" (with or without fractional seconds).
    private static func parseDate(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
