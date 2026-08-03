import Foundation

enum ServiceType: String, Codable, CaseIterable, Sendable {
    case kimi      // Kimi API (Moonshot) — 套餐用量
    case deepseek  // DeepSeek API — 余额
    case ark       // ARK API Key (via arkcli) — 余额
    case zhipu     // 智谱 GLM Coding Plan — 配额用量
    case aliyun    // 阿里云 — 费用中心账户余额

    var displayName: String {
        switch self {
        case .kimi:     return "Kimi"
        case .deepseek: return "DeepSeek"
        case .ark:      return "ARK"
        case .zhipu:    return "智谱"
        case .aliyun:   return "阿里云"
        }
    }

    var sfSymbol: String {
        switch self {
        case .kimi:     return "sparkles"
        case .deepseek: return "brain.head.profile"
        case .ark:      return "flame.fill"
        case .zhipu:    return "bolt.fill"
        case .aliyun:   return "cloud.fill"
        }
    }

    var defaultUnitLabel: String {
        switch self {
        case .kimi:     return "tokens"
        case .deepseek: return "¥"
        case .ark:      return "tokens"
        case .zhipu:    return "积分"
        case .aliyun:   return "¥"
        }
    }

    /// Short label for the menu-bar carousel (kept narrow to save bar width).
    var shortLabel: String {
        switch self {
        case .kimi:     return "K"
        case .deepseek: return "DS"
        case .ark:      return "A"
        case .zhipu:    return "智"
        case .aliyun:   return "阿"
        }
    }

    /// Services that authenticate with an Access Key / Secret Key pair,
    /// stored as {"ak","sk"} JSON in the key file (火山 ARK, 阿里云).
    var usesAKSK: Bool {
        self == .ark || self == .aliyun
    }
}
