import Foundation

enum ServiceType: String, Codable, CaseIterable, Sendable {
    case kimi      // Kimi API (Moonshot) — 套餐用量
    case deepseek  // DeepSeek API — 余额
    case ark       // ARK API Key (via arkcli) — 余额

    var displayName: String {
        switch self {
        case .kimi:     return "Kimi"
        case .deepseek: return "DeepSeek"
        case .ark:      return "ARK"
        }
    }

    var sfSymbol: String {
        switch self {
        case .kimi:     return "sparkles"
        case .deepseek: return "brain.head.profile"
        case .ark:      return "flame.fill"
        }
    }

    var defaultUnitLabel: String {
        switch self {
        case .kimi:     return "tokens"
        case .deepseek: return "¥"
        case .ark:      return "tokens"
        }
    }
}
