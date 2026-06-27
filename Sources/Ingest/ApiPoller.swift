import Foundation

/// Periodically polls provider balance/usage APIs (Tier B).
/// Runs every hour by default, same as the Chrome extension.
final class ApiPoller {
    static let shared = ApiPoller()
    private var timer: Timer?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Public

    func start() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.pollAll()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.pollAll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func pollAll() {
        for p in ProviderRegistry.all where p.canFetchBalance {
            guard let key = ApiKeyManager.shared.get(p.id), !key.isEmpty else { continue }
            fetchBalance(provider: p, apiKey: key)
        }
    }

    func fetchNow(providerId: String) {
        guard let p = ProviderRegistry.byId(providerId),
              p.canFetchBalance,
              let key = ApiKeyManager.shared.get(providerId), !key.isEmpty
        else { return }
        fetchBalance(provider: p, apiKey: key)
    }

    // MARK: - Fetch dispatcher

    private func fetchBalance(provider: ProviderDef, apiKey: String) {
        guard let api = provider.balanceAPI else { return }

        switch api {
        case .simple(let url, _):
            fetchSimple(provider: provider, url: url, apiKey: apiKey, parser: simpleParser(for: provider.id))
        case .openAI(let baseURL):
            fetchOpenAIUsage(provider: provider, baseURL: baseURL, apiKey: apiKey)
        case .zhipu(let url):
            fetchSimple(provider: provider, url: url, apiKey: apiKey, parser: zhipuParser)
        }
    }

    // MARK: - Generic simple fetcher

    private func fetchSimple(provider: ProviderDef, url: String, apiKey: String,
                              parser: @escaping ([String: Any]) -> [BalanceEntry]) {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: req) { [weak self] data, resp, error in
            if let error {
                self?.cacheError(pid: provider.id, msg: error.localizedDescription); return
            }
            guard let data, let httpResp = resp as? HTTPURLResponse else {
                self?.cacheError(pid: provider.id, msg: "No response"); return
            }
            guard httpResp.statusCode == 200 else {
                self?.cacheError(pid: provider.id, msg: "HTTP \(httpResp.statusCode)")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self?.cacheError(pid: provider.id, msg: "Invalid JSON"); return
            }
            let entries = parser(json)
            self?.cacheBalance(pid: provider.id, entries: entries)
        }.resume()
    }

    // MARK: - OpenAI (multi-day usage)

    private func fetchOpenAIUsage(provider: ProviderDef, baseURL: String, apiKey: String) {
        let cal = Calendar.current
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        var totalCost = 0.0
        let group = DispatchGroup()

        for dayOffset in 0..<3 {
            guard let date = cal.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let dateStr = fmt.string(from: date)
            guard let url = URL(string: "\(baseURL)?date=\(dateStr)") else { continue }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            group.enter()
            session.dataTask(with: req) { data, resp, _ in
                defer { group.leave() }
                guard let data,
                      let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let usage = json["total_usage"] as? Double
                else { return }
                totalCost += usage / 100.0
            }.resume()
        }

        group.notify(queue: .global(qos: .utility)) { [weak self] in
            let entry = BalanceEntry(currency: "USD", totalBalance: totalCost, grantedBalance: 0, toppedUpBalance: 0)
            self?.cacheBalance(pid: provider.id, entries: [entry])
        }
    }

    // MARK: - Zhipu parser

    private func zhipuParser(_ json: [String: Any]) -> [BalanceEntry] {
        let limits = (json["data"] as? [String: Any])?["limits"] as? [[String: Any]] ?? []
        let tokenLimit = limits.first { ($0["type"] as? String) == "TOKENS_LIMIT" }
        let remaining = tokenLimit?["remaining"] as? Double ?? tokenLimit?["currentValue"] as? Double ?? 0
        return [BalanceEntry(currency: "tokens", totalBalance: remaining, grantedBalance: 0, toppedUpBalance: 0)]
    }

    private func simpleParser(for providerId: String) -> ([String: Any]) -> [BalanceEntry] {
        switch providerId {
        case "deepseek":
            return { json in
                (json["balance_infos"] as? [[String: Any]] ?? []).map { b in
                    BalanceEntry(
                        currency: b["currency"] as? String ?? "CNY",
                        totalBalance: Double(b["total_balance"] as? String ?? "0") ?? 0,
                        grantedBalance: Double(b["granted_balance"] as? String ?? "0") ?? 0,
                        toppedUpBalance: Double(b["topped_up_balance"] as? String ?? "0") ?? 0
                    )
                }
            }
        case "moonshot":
            return { json in
                let data = json["data"] as? [String: Any] ?? json
                let bal = Double(data["balance"] as? String ?? data["total_balance"] as? String ?? "0") ?? 0
                return [BalanceEntry(currency: "CNY", totalBalance: bal, grantedBalance: 0, toppedUpBalance: 0)]
            }
        default:
            return { _ in [] }
        }
    }

    // MARK: - Caching

    private func cacheBalance(pid: String, entries: [BalanceEntry]) {
        var cache = balanceCache()
        cache[pid] = CachedBalance(balances: entries, lastFetchTimestamp: Int(Date().timeIntervalSince1970 * 1000), error: nil)
        saveBalanceCache(cache)
        print("ApiPoller[\(pid)]: ok — \(entries.map { "\($0.currency) \($0.totalBalance)" }.joined(separator: ", "))")
    }

    private func cacheError(pid: String, msg: String) {
        var cache = balanceCache()
        cache[pid] = CachedBalance(balances: [], lastFetchTimestamp: Int(Date().timeIntervalSince1970 * 1000), error: msg)
        saveBalanceCache(cache)
        print("ApiPoller[\(pid)]: \(msg)")
    }

    private func balanceCache() -> [String: CachedBalance] {
        guard let data = UserDefaults.standard.data(forKey: "tierb_balance_cache"),
              let cache = try? JSONDecoder().decode([String: CachedBalance].self, from: data)
        else { return [:] }
        return cache
    }

    private func saveBalanceCache(_ cache: [String: CachedBalance]) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: "tierb_balance_cache")
    }

    func cachedBalance(for providerId: String) -> CachedBalance? {
        balanceCache()[providerId]
    }
}

struct CachedBalance: Codable {
    let balances: [BalanceEntry]
    let lastFetchTimestamp: Int
    let error: String?
}
