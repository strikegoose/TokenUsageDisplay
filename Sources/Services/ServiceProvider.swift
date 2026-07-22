import Foundation

enum ServiceError: LocalizedError, Sendable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(Int)
    case networkError(String)
    case parseError(String)
    case notConfigured
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "API Key 无效，请在设置中检查"
        case .rateLimited(let retry):
            if let sec = retry { return "请求太频繁，\(Int(sec))秒后重试" }
            return "请求太频繁，请稍后重试"
        case .serverError(let code):
            return "服务器错误 (HTTP \(code))"
        case .networkError(let msg):
            return "网络错误: \(msg)"
        case .parseError(let msg):
            return "数据解析失败: \(msg)"
        case .notConfigured:
            return "未配置 API Key"
        case .unknown(let msg):
            return msg
        }
    }
}

protocol ServiceProvider: Identifiable, Sendable {
    var id: String { get }
    var config: ServiceConfiguration { get }
    /// One logical service may expose several quota windows (e.g. Kimi's
    /// weekly / 5-hour / monthly limits) — each becomes its own card.
    func fetchUsage(apiKey: String) async throws -> [UsageData]
    func validateConnection(apiKey: String) async throws -> Bool
}

extension ServiceProvider {
    var id: String { config.id }
}
