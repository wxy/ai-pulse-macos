import Foundation

// MARK: - Data types

struct BalanceEntry: Codable {
    let currency: String
    let totalBalance: Double
    let grantedBalance: Double
    let toppedUpBalance: Double
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
    let balanceAPI: BalanceAPI?             // how to fetch (nil if no API)
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
            canFetchBalance: true, balanceAPI: .simple(url: "https://api.deepseek.com/user/balance", authHeader: "Bearer")),
        ProviderDef(
            id: "openai", name: "OpenAI", company: "OpenAI",
            baseUrl: "https://platform.openai.com",
            balanceType: .usage,
            canFetchBalance: true, balanceAPI: .openAI(baseURL: "https://api.openai.com/v1/usage")),
        ProviderDef(
            id: "moonshot", name: "Kimi", company: "月之暗面 Moonshot",
            baseUrl: "https://platform.moonshot.cn",
            balanceType: .prepaid,
            canFetchBalance: true, balanceAPI: .simple(url: "https://api.moonshot.cn/v1/users/me/balance", authHeader: "Bearer")),
        ProviderDef(
            id: "zhipu", name: "ChatGLM", company: "智谱 Zhipu AI",
            baseUrl: "https://open.bigmodel.cn",
            balanceType: .quota,
            canFetchBalance: true, balanceAPI: .zhipu(url: "https://www.bigmodel.cn/api/biz/account/query-customer-account-report")),
        ProviderDef(
            id: "mistral", name: "Mistral", company: "Mistral AI",
            baseUrl: "https://console.mistral.ai",
            balanceType: .usage,
            canFetchBalance: false, balanceAPI: nil),

        // ---- Status-only (8) ----
        ProviderDef(
            id: "anthropic", name: "Anthropic", company: "Anthropic",
            baseUrl: "https://console.anthropic.com",
            balanceType: .prepaid,
            canFetchBalance: false, balanceAPI: nil),
        ProviderDef(
            id: "google", name: "Google AI", company: "Google",
            baseUrl: "https://aistudio.google.com",
            balanceType: .prepaid,
            canFetchBalance: false, balanceAPI: nil),
        ProviderDef(
            id: "xai", name: "xAI (Grok)", company: "xAI",
            baseUrl: "https://console.x.ai",
            balanceType: .prepaid,
            canFetchBalance: false, balanceAPI: nil),
        ProviderDef(
            id: "cohere", name: "Cohere", company: "Cohere",
            baseUrl: "https://dashboard.cohere.com",
            balanceType: .prepaid,
            canFetchBalance: false, balanceAPI: nil),
        ProviderDef(
            id: "perplexity", name: "Perplexity", company: "Perplexity AI",
            baseUrl: "https://www.perplexity.ai",
            balanceType: .prepaid,
            canFetchBalance: false, balanceAPI: nil),
        ProviderDef(
            id: "qwen", name: "Qwen", company: "阿里云通义千问",
            baseUrl: "https://dashscope.aliyun.com",
            balanceType: .prepaid,
            canFetchBalance: false, balanceAPI: nil),
        ProviderDef(
            id: "baichuan", name: "Baichuan", company: "百川智能",
            baseUrl: "https://platform.baichuan-ai.com",
            balanceType: .prepaid,
            canFetchBalance: false, balanceAPI: nil),
        ProviderDef(
            id: "ernie", name: "Ernie", company: "百度文心一言",
            baseUrl: "https://console.bce.baidu.com/qianfan",
            balanceType: .prepaid,
            canFetchBalance: false, balanceAPI: nil),
    ]

    static func byId(_ id: String) -> ProviderDef? {
        all.first { $0.id == id }
    }
}
