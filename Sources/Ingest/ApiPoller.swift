import Foundation
import GRDB

/// Periodically polls provider balance/usage APIs (Tier B).
/// Runs every hour by default, same as the Chrome extension.
nonisolated final class ApiPoller: @unchecked Sendable {
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
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                                self?.pollAll()
                }
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

        Task {
            var total = 0.0
            for dayOffset in 0..<3 {
                guard let date = cal.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
                let dateStr = fmt.string(from: date)
                guard let url = URL(string: "\(baseURL)?date=\(dateStr)") else { continue }
                var req = URLRequest(url: url)
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                guard let (data, resp) = try? await session.data(for: req),
                      let httpResp = resp as? HTTPURLResponse,
                      httpResp.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let usage = json["total_usage"] as? Double
                else { continue }
                total += usage / 100.0
            }
            guard total > 0 else { return }
            let entry = BalanceEntry(currency: "USD", totalBalance: total, grantedBalance: 0, toppedUpBalance: 0)
            cacheBalance(pid: provider.id, entries: [entry])
        }
    }

    // MARK: - Zhipu parser

    /// Parses account balance from query-customer-account-report.
    /// Uses availableBalance (CNY) as the usable total.
    private nonisolated func zhipuParser(_ json: [String: Any]) -> [BalanceEntry] {
        let balance = json["balance"] as? [String: Any] ?? json["data"] as? [String: Any] ?? [:]
        let available = Self.parseDouble(balance["availableBalance"]) ?? Self.parseDouble(balance["balance"]) ?? 0
        return [BalanceEntry(currency: "CNY", totalBalance: available, grantedBalance: 0, toppedUpBalance: 0)]
    }

    private nonisolated func simpleParser(for providerId: String) -> @Sendable ([String: Any]) -> [BalanceEntry] {
        switch providerId {
        case "deepseek":
            return { json in
                (json["balance_infos"] as? [[String: Any]] ?? []).map { b in
                    BalanceEntry(
                        currency: b["currency"] as? String ?? "CNY",
                        totalBalance: Self.parseDouble(b["total_balance"]) ?? 0,
                        grantedBalance: Self.parseDouble(b["granted_balance"]) ?? 0,
                        toppedUpBalance: Self.parseDouble(b["topped_up_balance"]) ?? 0
                    )
                }
            }
        case "moonshot":
            return { json in
                let data = json["data"] as? [String: Any] ?? json
                // Moonshot API returns { "available_balance": 14.7286 } — numeric, not string.
                let bal = Self.parseDouble(data["available_balance"]) ?? Self.parseDouble(data["balance"]) ?? 0
                return [BalanceEntry(currency: "CNY", totalBalance: bal, grantedBalance: 0, toppedUpBalance: 0)]
            }
        default:
            return { _ in [] }
        }
    }

    /// Parse a Double from either String or Number JSON values.
    static nonisolated func parseDouble(_ value: Any?) -> Double? {
        guard let value else { return nil }
        let parsed: Double?
        if let s = value as? String { parsed = Double(s) }
        else if let n = value as? Double { parsed = n }
        else if let n = value as? NSNumber { parsed = n.doubleValue }
        else { parsed = nil }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    // MARK: - Caching

    private func cacheBalance(pid: String, entries: [BalanceEntry]) {
        // Reject non-finite or negative balances at the ingestion boundary.
        // SQLite stores NaN as NULL, which later reads as 0 and fabricates a
        // bogus "balance wiped" spend delta. A negative balance is also not a
        // valid snapshot for either billing mode.
        let safeEntries = entries.filter { $0.totalBalance.isFinite && $0.totalBalance >= 0 }
        if !entries.isEmpty && safeEntries.isEmpty {
            DiagnosticJournal.log("api_balance_rejected", [
                "provider_id": .string(pid),
                "entry_count": .int(entries.count),
            ])
            return
        }
        var cache = balanceCache()
        let now = Int(Date().timeIntervalSince1970 * 1000)

        // Detect spend: compare new balance with previous cached balance
        let prevBalance = cache[pid]?.balances.first?.totalBalance
        let provider = ProviderRegistry.byId(pid)
        let isUsageType = provider?.balanceType == .usage

        cache[pid] = CachedBalance(balances: safeEntries, lastFetchTimestamp: now, error: nil)
        saveBalanceCache(cache)
        DiagnosticJournal.log("api_balance", [
            "provider_id": .string(pid),
            "entry_count": .int(safeEntries.count),
            "balances": .array(safeEntries.map { .double($0.totalBalance) }),
            "previous_balance": prevBalance.map { .double($0) } ?? .string("missing"),
            "usage_type": .bool(isUsageType),
        ])

        // Play coin sound for detected spend
        for entry in safeEntries {
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
        for entry in safeEntries {
            Task {
                do {
                    try await AppDatabase.shared.write { db in
                        let csId = "api-key:\(pid)"
                        let storedBalance = isUsageType ? -entry.totalBalance : entry.totalBalance
                        guard storedBalance.isFinite else { return }
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
        Logger.info("ApiPoller[\(pid)]: ok — \(safeEntries.map { "\($0.currency) \($0.totalBalance)" }.joined(separator: ", "))")
        AppHealthMonitor.shared.clearAPIError(providerId: pid)
        notifyBalanceUpdated(pid: pid)
    }

    private func cacheError(pid: String, msg: String) {
        var cache = balanceCache()
        cache[pid] = CachedBalance(balances: [], lastFetchTimestamp: Int(Date().timeIntervalSince1970 * 1000), error: msg)
        saveBalanceCache(cache)
        Logger.warning("ApiPoller[\(pid)]: \(msg)")
        DiagnosticJournal.log("api_error", [
            "provider_id": .string(pid),
            "outcome": .string(Self.diagnosticOutcome(for: msg)),
        ])
        AppHealthMonitor.shared.reportAPIError(providerId: pid, message: "\(pid): \(msg)")
        notifyBalanceUpdated(pid: pid)
    }

    /// Lets UI (e.g. IntegrationRow) react immediately instead of only on next `.onAppear`.
    private func notifyBalanceUpdated(pid: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .apiBalanceDidUpdate, object: nil, userInfo: ["providerId": pid])
        }
    }

    private static func diagnosticOutcome(for message: String) -> String {
        let stableMessages: Set<String> = [
            "No response", "Invalid JSON", "API error",
        ]
        if message.hasPrefix("HTTP ") || stableMessages.contains(message) {
            return message
        }
        return "provider_error"
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
