import Foundation
import GRDB

/// Periodically polls provider balance/usage APIs (Tier B).
/// Runs every hour by default, same as the Chrome extension.
final class ApiPoller: @unchecked Sendable {
    static let shared = ApiPoller()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Public

    func start() {
        // Initial poll at +10s (coordinator Phase 3 handles periodic polling).
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { [weak self] in
            Task { @MainActor in
                self?.pollAll()
            }
        }
    }

    func stop() {
        // Timer removed — DataRefreshCoordinator owns the periodic schedule.
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
                              parser: @escaping @Sendable ([String: Any]) -> [BalanceEntry]) {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: req) { [weak self] data, resp, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
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
                    // Detect error responses that come back as HTTP 200
                    // (common in Chinese APIs — they embed error codes in the body).
                    //
                    // Pattern 1: {"error": {"message": "..."}}
                    if let errorObj = json["error"] as? [String: Any] {
                        let msg = errorObj["message"] as? String
                            ?? errorObj["code"] as? String
                            ?? "API error"
                        self?.cacheError(pid: provider.id, msg: msg); return
                    }
                    // Pattern 2: {"success": false, "msg"/"message": "..."}
                    //   Zhipu: {"code":401,"msg":"...","success":false}
                    //   Some APIs return code:0 for success — only treat
                    //   as error when `success` is explicitly false.
                    if json["success"] as? Bool == false {
                        let msg = json["msg"] as? String
                            ?? json["message"] as? String
                            ?? "API error"
                        self?.cacheError(pid: provider.id, msg: msg); return
                    }
                    // Pattern 3: provider-specific overrides
                    if let code = json["code"] as? Int {
                        switch provider.id {
                        case "zhipu":
                            // Zhipu uses code 200 for success, 401/403/etc for errors.
                            if code != 200 {
                                let msg = json["msg"] as? String ?? "API error \(code)"
                                self?.cacheError(pid: provider.id, msg: msg); return
                            }
                        case "moonshot":
                            // Kimi uses code 0 for success.
                            if code != 0 {
                                let msg = json["msg"] as? String
                                    ?? json["message"] as? String
                                    ?? "API error \(code)"
                                self?.cacheError(pid: provider.id, msg: msg); return
                            }
                        default:
                            break
                        }
                    }
                    let entries = parser(json)
                    self?.cacheBalance(pid: provider.id, entries: entries)
                }
            }
        }.resume()
    }

    // MARK: - OpenAI (multi-day usage)

    private func fetchOpenAIUsage(provider: ProviderDef, baseURL: String, apiKey: String) {
        let cal = Calendar.current
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let group = DispatchGroup()

        final class CostAccumulator: @unchecked Sendable {
            nonisolated(unsafe) var value: Double = 0.0
        }
        let totalCost = CostAccumulator()

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
                totalCost.value += usage / 100.0
            }.resume()
        }

        group.notify(queue: .global(qos: .utility)) { [weak self] in
            let entry = BalanceEntry(currency: "USD", totalBalance: totalCost.value, grantedBalance: 0, toppedUpBalance: 0)
            self?.cacheBalance(pid: provider.id, entries: [entry])
        }
    }

    // MARK: - Zhipu parser

    /// Parses account balance from query-customer-account-report.
    /// Uses availableBalance (CNY) as the usable total.
    private nonisolated func zhipuParser(_ json: [String: Any]) -> [BalanceEntry] {
        let balance = json["balance"] as? [String: Any] ?? json["data"] as? [String: Any] ?? [:]
        let available = parseDouble(balance["availableBalance"]) ?? parseDouble(balance["balance"]) ?? 0
        return [BalanceEntry(currency: "CNY", totalBalance: available, grantedBalance: 0, toppedUpBalance: 0)]
    }

    private nonisolated func simpleParser(for providerId: String) -> @Sendable ([String: Any]) -> [BalanceEntry] {
        switch providerId {
        case "deepseek":
            return { [parseDouble] json in
                (json["balance_infos"] as? [[String: Any]] ?? []).map { b in
                    BalanceEntry(
                        currency: b["currency"] as? String ?? "CNY",
                        totalBalance: parseDouble(b["total_balance"]) ?? 0,
                        grantedBalance: parseDouble(b["granted_balance"]) ?? 0,
                        toppedUpBalance: parseDouble(b["topped_up_balance"]) ?? 0
                    )
                }
            }
        case "moonshot":
            return { json in
                let data = json["data"] as? [String: Any] ?? json
                // Moonshot API returns { "available_balance": 14.7286 } — numeric, not string.
                let bal = self.parseDouble(data["available_balance"]) ?? self.parseDouble(data["balance"]) ?? 0
                return [BalanceEntry(currency: "CNY", totalBalance: bal, grantedBalance: 0, toppedUpBalance: 0)]
            }
        default:
            return { _ in [] }
        }
    }

    /// Parse a Double from either String or Number JSON values.
    private nonisolated func parseDouble(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let s = value as? String { return Double(s) }
        if let n = value as? Double { return n }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: - Caching

    private func cacheBalance(pid: String, entries: [BalanceEntry]) {
        var cache = balanceCache()
        let now = Int(Date().timeIntervalSince1970 * 1000)

        // Detect spend: compare new balance with previous cached balance
        let prevBalance = cache[pid]?.balances.first?.totalBalance
        let provider = ProviderRegistry.byId(pid)
        let isUsageType = provider?.balanceType == .usage

        cache[pid] = CachedBalance(balances: entries, lastFetchTimestamp: now, error: nil)
        saveBalanceCache(cache)

        // Play coin sound for detected spend
        for entry in entries {
            let detected: Bool = if isUsageType {
                (prevBalance.map { entry.totalBalance > $0 } ?? false)
            } else {
                (prevBalance.map { entry.totalBalance < $0 } ?? false)
            }
            if detected, let prev = prevBalance {
                let spend = isUsageType ? (entry.totalBalance - prev) : (prev - entry.totalBalance)
                DispatchQueue.main.async { CoinSound.play(for: spend) }
            }
        }

        // Record balance snapshot for daily spend calculation.
        // For usage-type providers (OpenAI), cumulative spend grows over time —
        // store as negative so that "balance decreases" correctly represents spend.
        for entry in entries {
            Task {
                do {
                    try await AppDatabase.shared.write { db in
                        let csId = "api-key:\(pid)"
                        let storedBalance = isUsageType ? -entry.totalBalance : entry.totalBalance
                        try db.execute(sql: """
                            INSERT INTO balance_snapshot (ts, provider_id, balance, currency, cost_source_id)
                            VALUES (?, ?, ?, ?, ?)
                            """, arguments: [now, pid, storedBalance, entry.currency, csId])
                    }
                    DataRefreshCoordinator.shared.notifyPhaseBalance()
                } catch {
                    Logger.error("ApiPoller[\(pid)]: snapshot insert failed: \(error)")
                }
            }
        }
        Logger.info("ApiPoller[\(pid)]: ok — \(entries.map { "\($0.currency) \($0.totalBalance)" }.joined(separator: ", "))")
        AppHealthMonitor.shared.clearAPIError(providerId: pid)
    }

    private func cacheError(pid: String, msg: String) {
        var cache = balanceCache()
        cache[pid] = CachedBalance(balances: [], lastFetchTimestamp: Int(Date().timeIntervalSince1970 * 1000), error: msg)
        saveBalanceCache(cache)
        Logger.warning("ApiPoller[\(pid)]: \(msg)")
        AppHealthMonitor.shared.reportAPIError(providerId: pid, message: "\(pid): \(msg)")
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

    func clearCache(for providerId: String) {
        var cache = balanceCache()
        cache.removeValue(forKey: providerId)
        saveBalanceCache(cache)
    }
}

struct CachedBalance: Codable {
    let balances: [BalanceEntry]
    let lastFetchTimestamp: Int
    let error: String?
}
