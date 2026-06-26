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
        // First poll after 10 s, then every hour
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

    /// Poll all balance-capable providers that have a stored API key.
    func pollAll() {
        for provider in ProviderRegistry.all where provider.canFetchBalance {
            guard let urlStr = provider.balanceURL,
                  let key = ApiKeyManager.shared.get(provider.id),
                  !key.isEmpty
            else { continue }
            fetchBalance(provider: provider, apiKey: key, url: urlStr)
        }
    }

    /// Fetch a specific provider on demand (e.g. when user adds a new key).
    func fetchNow(providerId: String) {
        guard let p = ProviderRegistry.byId(providerId),
              p.canFetchBalance,
              let urlStr = p.balanceURL,
              let key = ApiKeyManager.shared.get(providerId),
              !key.isEmpty
        else { return }
        fetchBalance(provider: p, apiKey: key, url: urlStr)
    }

    // MARK: - Balance fetching

    private func fetchBalance(provider: ProviderDef, apiKey: String, url: String) {
        let requestURL: String
        var headers: [(String, String)] = [("Authorization", "Bearer \(apiKey)")]

        switch provider.id {
        case "openai":
            // OpenAI: GET /v1/usage?date=YYYY-MM-DD for last 3 days
            fetchOpenAIUsage(apiKey: apiKey, baseURL: url)
            return
        case "anthropic":
            headers = [("x-api-key", apiKey), ("anthropic-version", "2023-06-01")]
            requestURL = url
        default:
            requestURL = url
        }

        var req = URLRequest(url: URL(string: requestURL)!)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        session.dataTask(with: req) { [provider] data, resp, error in
            if let error {
                print("ApiPoller[\(provider.id)]: request failed — \(error.localizedDescription)")
                self.cacheError(providerId: provider.id, msg: error.localizedDescription)
                return
            }
            guard let data, let httpResp = resp as? HTTPURLResponse else {
                self.cacheError(providerId: provider.id, msg: "No response")
                return
            }
            guard httpResp.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("ApiPoller[\(provider.id)]: HTTP \(httpResp.statusCode) — \(body.prefix(200))")
                self.cacheError(providerId: provider.id, msg: "HTTP \(httpResp.statusCode)")
                return
            }
            self.parseAndCache(provider: provider, data: data)
        }.resume()
    }

    // MARK: - OpenAI special handling

    private func fetchOpenAIUsage(apiKey: String, baseURL: String) {
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
                      let httpResp = resp as? HTTPURLResponse,
                      httpResp.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let usage = json["total_usage"] as? Double
                else { return }
                totalCost += usage / 100.0 // cents → dollars
            }.resume()
        }

        group.notify(queue: .global(qos: .utility)) {
            let entry = BalanceEntry(currency: "USD", totalBalance: totalCost, grantedBalance: 0, toppedUpBalance: 0)
            self.cacheBalance(providerId: "openai", balances: [entry])
            print("ApiPoller[openai]: 3-day usage = $\(String(format: "%.4f", totalCost))")
        }
    }

    // MARK: - Parsing

    private func parseAndCache(provider: ProviderDef, data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            cacheError(providerId: provider.id, msg: "Invalid JSON")
            return
        }

        let entries: [BalanceEntry]
        switch provider.id {
        case "deepseek":
            entries = (json["balance_infos"] as? [[String: Any]] ?? []).map { b in
                BalanceEntry(
                    currency: b["currency"] as? String ?? "CNY",
                    totalBalance: Double(b["total_balance"] as? String ?? "0") ?? 0,
                    grantedBalance: Double(b["granted_balance"] as? String ?? "0") ?? 0,
                    toppedUpBalance: Double(b["topped_up_balance"] as? String ?? "0") ?? 0
                )
            }
        case "moonshot":
            let data = json["data"] as? [String: Any] ?? json
            let bal = Double(data["balance"] as? String ?? data["total_balance"] as? String ?? "0") ?? 0
            entries = [BalanceEntry(currency: "CNY", totalBalance: bal, grantedBalance: 0, toppedUpBalance: 0)]
        case "zhipu":
            let limits = (json["data"] as? [String: Any])?["limits"] as? [[String: Any]] ?? []
            let tokenLimit = limits.first { ($0["type"] as? String) == "TOKENS_LIMIT" }
            let remaining = tokenLimit?["remaining"] as? Double ?? tokenLimit?["currentValue"] as? Double ?? 0
            entries = [BalanceEntry(currency: "tokens", totalBalance: remaining, grantedBalance: 0, toppedUpBalance: 0)]
        default:
            cacheError(providerId: provider.id, msg: "Unknown balance format")
            return
        }

        cacheBalance(providerId: provider.id, balances: entries)
        print("ApiPoller[\(provider.id)]: balance = \(entries.map { "\($0.currency) \($0.totalBalance)" }.joined(separator: ", "))")
    }

    // MARK: - Caching

    private func cacheBalance(providerId: String, balances: [BalanceEntry]) {
        var cache = balanceCache()
        cache[providerId] = CachedBalance(
            balances: balances, lastFetchTimestamp: Int(Date().timeIntervalSince1970 * 1000), error: nil
        )
        saveBalanceCache(cache)
    }

    private func cacheError(providerId: String, msg: String) {
        var cache = balanceCache()
        cache[providerId] = CachedBalance(
            balances: [], lastFetchTimestamp: Int(Date().timeIntervalSince1970 * 1000), error: msg
        )
        saveBalanceCache(cache)
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

    /// Public read access for the UI / calibration engine.
    func cachedBalance(for providerId: String) -> CachedBalance? {
        balanceCache()[providerId]
    }
}

// MARK: - Cached data model

struct CachedBalance: Codable {
    let balances: [BalanceEntry]
    let lastFetchTimestamp: Int
    let error: String?
}
