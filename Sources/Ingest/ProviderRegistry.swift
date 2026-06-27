import Foundation

// MARK: - Data types

struct BalanceEntry: Codable {
    let currency: String
    let totalBalance: Double
    let grantedBalance: Double
    let toppedUpBalance: Double
}

struct BalanceResult {
    let success: Bool
    let balances: [BalanceEntry]
    let rawTimestamp: Int
    let error: String?
}

struct StatusResult {
    let success: Bool
    let isAvailable: Bool
    let statusMessage: String
    let rawTimestamp: Int
    let error: String?
}

enum BillingMode: String, Codable {
    case prepaid  // balance decreases with usage
    case usage    // accumulated cost (OpenAI-style)
    case quota    // fixed token limit (Zhipu-style)
}

enum BalanceAPI: Equatable {
    case simple(url: String, authHeader: String)           // GET + Bearer token
    case openAI(baseURL: String)                            // multi-day usage fetch
    case zhipu(url: String)                                 // quota/limits endpoint
}

struct ProviderDef {
    let id: String
    let name: String
    let company: String
    let baseUrl: String
    let balanceType: BillingMode
    let canFetchBalance: Bool
    let canFetchStatus: Bool
    let balanceAPI: BalanceAPI?             // how to fetch (nil if no API)
    let statusURL: String?                  // health check endpoint
    let statusAuthHeader: String?           // e.g. "Bearer noop"
    let noBalanceNoteKey: String?           // I18n key shown when canFetchBalance==false
}

// MARK: - Provider Registry

/// Registry of all 13 AI providers ported from the Chrome extension.
/// 5 providers support balance/usage APIs; the other 8 are status-only.
enum ProviderRegistry {
    static let all: [ProviderDef] = [
        // ---- Balance-capable (5) ----
        ProviderDef(
            id: "deepseek", name: "DeepSeek", company: "深度求索",
            baseUrl: "https://platform.deepseek.com",
            balanceType: .prepaid,
            canFetchBalance: true, canFetchStatus: true,
            balanceAPI: .simple(url: "https://api.deepseek.com/user/balance", authHeader: "Bearer"),
            statusURL: "https://api.deepseek.com/models", statusAuthHeader: nil,
            noBalanceNoteKey: nil
        ),
        ProviderDef(
            id: "openai", name: "OpenAI", company: "OpenAI",
            baseUrl: "https://platform.openai.com",
            balanceType: .usage,
            canFetchBalance: true, canFetchStatus: true,
            balanceAPI: .openAI(baseURL: "https://api.openai.com/v1/usage"),
            statusURL: "https://api.openai.com/v1/models", statusAuthHeader: "Bearer noop",
            noBalanceNoteKey: nil
        ),
        ProviderDef(
            id: "moonshot", name: "Kimi", company: "月之暗面 Moonshot",
            baseUrl: "https://platform.moonshot.cn",
            balanceType: .prepaid,
            canFetchBalance: true, canFetchStatus: true,
            balanceAPI: .simple(url: "https://api.moonshot.cn/v1/users/me/balance", authHeader: "Bearer"),
            statusURL: "https://api.moonshot.cn/v1/models", statusAuthHeader: "Bearer noop",
            noBalanceNoteKey: nil
        ),
        ProviderDef(
            id: "zhipu", name: "ChatGLM", company: "智谱 Zhipu AI",
            baseUrl: "https://open.bigmodel.cn",
            balanceType: .quota,
            canFetchBalance: true, canFetchStatus: true,
            balanceAPI: .zhipu(url: "https://bigmodel.cn/api/monitor/usage/quota/limit"),
            statusURL: "https://open.bigmodel.cn/api/paas/v4/models", statusAuthHeader: nil,
            noBalanceNoteKey: nil
        ),
        ProviderDef(
            id: "mistral", name: "Mistral", company: "Mistral AI",
            baseUrl: "https://console.mistral.ai",
            balanceType: .usage,
            canFetchBalance: false, canFetchStatus: true,
            balanceAPI: nil,
            statusURL: "https://api.mistral.ai/v1/models", statusAuthHeader: nil,
            noBalanceNoteKey: "apikeys.note_mistral"
        ),

        // ---- Status-only (8) ----
        ProviderDef(
            id: "anthropic", name: "Anthropic", company: "Anthropic",
            baseUrl: "https://console.anthropic.com",
            balanceType: .prepaid,
            canFetchBalance: false, canFetchStatus: true,
            balanceAPI: nil,
            statusURL: "https://api.anthropic.com/v1/models",
            statusAuthHeader: "x-api-key: noop|anthropic-version: 2023-06-01",
            noBalanceNoteKey: "apikeys.note_anthropic"
        ),
        ProviderDef(
            id: "google", name: "Google AI", company: "Google",
            baseUrl: "https://aistudio.google.com",
            balanceType: .prepaid,
            canFetchBalance: false, canFetchStatus: true,
            balanceAPI: nil,
            statusURL: "https://generativelanguage.googleapis.com/v1beta/models?key=noop",
            statusAuthHeader: nil,
            noBalanceNoteKey: "apikeys.note_google"
        ),
        ProviderDef(
            id: "xai", name: "xAI (Grok)", company: "xAI",
            baseUrl: "https://console.x.ai",
            balanceType: .prepaid,
            canFetchBalance: false, canFetchStatus: true,
            balanceAPI: nil,
            statusURL: "https://api.x.ai/v1/models",
            statusAuthHeader: nil,
            noBalanceNoteKey: "apikeys.note_xai"
        ),
        ProviderDef(
            id: "cohere", name: "Cohere", company: "Cohere",
            baseUrl: "https://dashboard.cohere.com",
            balanceType: .prepaid,
            canFetchBalance: false, canFetchStatus: true,
            balanceAPI: nil,
            statusURL: "https://api.cohere.ai/v1/models",
            statusAuthHeader: nil,
            noBalanceNoteKey: "apikeys.note_cohere"
        ),
        ProviderDef(
            id: "perplexity", name: "Perplexity", company: "Perplexity AI",
            baseUrl: "https://www.perplexity.ai",
            balanceType: .prepaid,
            canFetchBalance: false, canFetchStatus: true,
            balanceAPI: nil,
            statusURL: "https://api.perplexity.ai/chat/completions",
            statusAuthHeader: nil,
            noBalanceNoteKey: "apikeys.note_perplexity"
        ),
        ProviderDef(
            id: "qwen", name: "Qwen", company: "阿里云通义千问",
            baseUrl: "https://dashscope.aliyun.com",
            balanceType: .prepaid,
            canFetchBalance: false, canFetchStatus: true,
            balanceAPI: nil,
            statusURL: "https://dashscope.aliyuncs.com/compatible-mode/v1/models",
            statusAuthHeader: nil,
            noBalanceNoteKey: "apikeys.note_qwen"
        ),
        ProviderDef(
            id: "baichuan", name: "Baichuan", company: "百川智能",
            baseUrl: "https://platform.baichuan-ai.com",
            balanceType: .prepaid,
            canFetchBalance: false, canFetchStatus: true,
            balanceAPI: nil,
            statusURL: "https://api.baichuan-ai.com/v1/models",
            statusAuthHeader: nil,
            noBalanceNoteKey: "apikeys.note_baichuan"
        ),
        ProviderDef(
            id: "ernie", name: "Ernie", company: "百度文心一言",
            baseUrl: "https://console.bce.baidu.com/qianfan",
            balanceType: .prepaid,
            canFetchBalance: false, canFetchStatus: true,
            balanceAPI: nil,
            statusURL: "https://qianfan.baidubce.com/v2/models",
            statusAuthHeader: nil,
            noBalanceNoteKey: "apikeys.note_ernie"
        ),
    ]

    static func byId(_ id: String) -> ProviderDef? {
        all.first { $0.id == id }
    }
}
