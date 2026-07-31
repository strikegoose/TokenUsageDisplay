import Foundation

enum ServiceType: String, Codable, CaseIterable, Sendable {
    case kimi      // Kimi API (Moonshot) — 套餐用量
    case deepseek  // DeepSeek API — 余额
    case ark       // ARK API Key (via arkcli) — 余额
    case zhipu     // 智谱 GLM Coding Plan — 配额用量

    var displayName: String {
        switch self {
        case .kimi:     return "Kimi"
        case .deepseek: return "DeepSeek"
        case .ark:      return "ARK"
        case .zhipu:    return "智谱"
        }
    }

    var sfSymbol: String {
        switch self {
        case .kimi:     return "sparkles"
        case .deepseek: return "brain.head.profile"
        case .ark:      return "flame.fill"
        case .zhipu:    return "bolt.fill"
        }
    }

    var defaultUnitLabel: String {
        switch self {
        case .kimi:     return "tokens"
        case .deepseek: return "¥"
        case .ark:      return "tokens"
        case .zhipu:    return "积分"
        }
    }

    /// Short label for the menu-bar carousel (kept narrow to save bar width).
    var shortLabel: String {
        switch self {
        case .kimi:     return "K"
        case .deepseek: return "DS"
        case .ark:      return "A"
        case .zhipu:    return "智"
        }
    }
}
