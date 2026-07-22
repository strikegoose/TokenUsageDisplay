import Foundation

// DeepSeek balance response: {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"59.26","granted_balance":"0.00","topped_up_balance":"59.26"}]}

struct DeepSeekBalanceResponse: Codable, Sendable {
    let isAvailable: Bool?
    let balanceInfos: [BalanceInfo]?

    struct BalanceInfo: Codable, Sendable {
        let currency: String?
        let totalBalance: String?
        let grantedBalance: String?
        let toppedUpBalance: String?

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }

    func extractBalance() -> (balance: Double, currency: String)? {
        guard let infos = balanceInfos, let info = infos.first else { return nil }
        let balance = Double(info.totalBalance ?? "0") ?? 0
        return (balance, info.currency ?? "CNY")
    }
}

struct DeepSeekProvider: ServiceProvider, Sendable {
    let config: ServiceConfiguration

    func fetchUsage(apiKey: String) async throws -> [UsageData] {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
            throw ServiceError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401: throw ServiceError.unauthorized
        case 429:
            let retry = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ServiceError.rateLimited(retryAfter: retry)
        case 500...599: throw ServiceError.serverError(httpResponse.statusCode)
        default: throw ServiceError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let balance: DeepSeekBalanceResponse
        do {
            balance = try decoder.decode(DeepSeekBalanceResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.parseError("Parse error: \(error). Raw: \(raw.prefix(200))")
        }

        guard let result = balance.extractBalance() else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.parseError("No balance info. Raw: \(raw.prefix(200))")
        }

        // DeepSeek balance: total_balance IS the remaining balance
        // There's no known "total cap", so show as balance without a progress bar
        return [UsageData(
            serviceId: config.id,
            serviceType: config.serviceType,
            serviceName: config.displayName,
            usedAmount: 0,
            totalAmount: result.balance > 0 ? result.balance : 1,
            unitLabel: result.currency == "CNY" ? "¥" : result.currency,
            isUnlimited: false
        )]
    }

    func validateConnection(apiKey: String) async throws -> Bool {
        _ = try await fetchUsage(apiKey: apiKey)
        return true
    }
}
