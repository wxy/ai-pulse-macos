import SwiftUI

/// Integration row — used in Onboarding and Settings.
/// Adaptive: apiKey integrations show key input, subscription show plan picker,
/// log-based (no apiKey) show toggle.
struct IntegrationRow: View {
    let integration: any Detectable
    let detected: DetectionResult
    let onGrant: (() -> Void)?
    @State private var enabled: Bool
    @State private var keyInput: String
    @State private var tierInput: String
    @State private var saved: Bool
    @State private var detecting: Bool = false
    @State private var preferredKeyId: String
    @State private var balanceText: String? = nil
    @State private var keyStatus: KeyStatus = .none
    /// Bumped every time a new "checking" cycle starts, so a stale timeout
    /// from an earlier cycle can't clobber a newer one's result.
    @State private var checkGeneration: Int = 0

    enum KeyStatus { case none, checking, valid, invalid }

    init(integration: any Detectable, detected: DetectionResult, onGrant: (() -> Void)? = nil) {
        self.integration = integration
        self.detected = detected
        self.onGrant = onGrant
        let cfg = IntegrationRegistry.config(for: integration.id)
        let hasKey = !(ApiKeyManager.shared.get(integration.id) ?? "").isEmpty
        _enabled = State(initialValue: cfg.enabled)
        _keyInput = State(initialValue: ApiKeyManager.shared.get(integration.id) ?? "")
        _tierInput = State(initialValue: cfg.subscriptionTier)
        _saved = State(initialValue: cfg.enabled || hasKey)
        _preferredKeyId = State(initialValue: cfg.preferredAPIKeyCostSourceId ?? "")
        if hasKey {
            let cached = ApiPoller.shared.cachedBalance(for: integration.id)
            if let cb = cached {
                _keyStatus = State(initialValue: (cb.error != nil) ? .invalid : .valid)
            }
        }
    }

    /// Returns the available API Key CostSource ids for the "preferred key" dropdown.
    var availableAPIKeySources: [(id: String, label: String)] {
        IntegrationRegistry.activeCostSources()
            .filter { if case .apiKey = $0.kind { return true }; return false }
            .map { ($0.id, $0.label) }
    }

    /// Known apiKey-only integration IDs (always show key input).
    private static let apiKeyIds: Set<String> = ["deepseek", "openai", "moonshot", "zhipu", "anthropic"]

    /// Known subscription integration IDs (always show tier picker).
    private static let subscriptionIds: Set<String> = ["claude-code", "cursor", "copilot", "windsurf"]

    /// Log-based dev tools: no subscription, no apiKey, but can use configured API keys.
    private static let logToolIds: Set<String> = ["aider", "codex", "qwen-code"]

    /// Is this integration primarily an apiKey type?
    var isAPIKeyType: Bool { Self.apiKeyIds.contains(integration.id) }

    /// Is this integration primarily a subscription type?
    var isSubscriptionType: Bool { Self.subscriptionIds.contains(integration.id) }

    /// Log-based dev tool: can use API keys but has no subscription tiers.
    var isLogTool: Bool { Self.logToolIds.contains(integration.id) }


    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isAPIKeyType {
                // ---- API Key layout (two rows) ----
                // Row 1: icon + name ……… balance
                HStack(spacing: 12) {
                    if detecting {
                        ProgressView().scaleEffect(0.6).frame(width: 20)
                    } else {
                        Image(systemName: iconName)
                            .foregroundColor(iconColor)
                            .font(.title3).frame(width: 20)
                    }
                    Text(integration.displayName).font(.body).fontWeight(.medium)
                    Spacer()
                    if let bal = balanceText {
                        Text(bal)
                            .font(.caption).foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                // Row 2: key input + save + status (indented under name)
                HStack(spacing: 6) {
                    Spacer().frame(width: 32)  // indent to align with name
                    apiKeyControls
                }
            } else {
                // ---- Non-API layout (original single row) ----
                HStack(spacing: 12) {
                    if detecting {
                        ProgressView().scaleEffect(0.6).frame(width: 20)
                    } else {
                        Image(systemName: iconName)
                            .foregroundColor(iconColor)
                            .font(.title3).frame(width: 20)
                    }

                    Text(integration.displayName).font(.body).fontWeight(.medium)

                    if !detected.found {
                        Text(summaryText)
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }

                    Spacer()

                    if detected.found {
                        Text(summaryText)
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }

                if detected.found {
                    devToolControls
                        .padding(.leading, 32)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .opacity((detected.found || isAPIKeyType) ? 1 : 0.5)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((detected.found || isAPIKeyType) ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .controlBackgroundColor).opacity(0.4))
                .shadow(color: .black.opacity((detected.found || isAPIKeyType) ? 0.06 : 0), radius: 3, y: 1.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .onAppear { refreshBalance() }
        .onReceive(NotificationCenter.default.publisher(for: .apiBalanceDidUpdate)) { note in
            guard isAPIKeyType, (note.userInfo?["providerId"] as? String) == integration.id else { return }
            refreshBalance()
        }
    }

    /// Log-based tools that read a ~/.xxx directory (need the home grant to
    /// be detected at all under sandbox).
    private var needsHomeGrant: Bool {
        integration.id == "claude-code" || integration.id == "codex" || integration.id == "qwen-code"
    }

    var summaryText: String {
        if detected.found {
            if isAPIKeyType, let bal = balanceText { return bal }
            return detected.summary
        }
        // Under sandbox without the home grant, we cannot yet tell whether a
        // log-based tool is installed — report "needs grant" rather than
        // a definitive "not installed".
        if needsHomeGrant && BookmarkManager.isSandboxed && !BookmarkManager.hasHomeAccess {
            return I18n.t("onboarding.grant_home_hint")
        }
        if isAPIKeyType { return I18n.t("integrations.needs_config_note") }
        return I18n.t("integrations.not_installed_note")
    }

    func refreshBalance() {
        guard isAPIKeyType else { return }
        // If no key is saved, ignore any stale cached balance
        // (e.g. from a previous session before the key was deleted).
        guard ApiKeyManager.shared.get(integration.id) != nil else {
            keyStatus = .none
            balanceText = nil
            return
        }
        if let cb = ApiPoller.shared.cachedBalance(for: integration.id) {
            if let err = cb.error {
                balanceText = I18n.t("apikeys.error") + ": \(err)"
                keyStatus = .invalid
            } else if let b = cb.balances.first {
                let usd = b.totalBalance * StatsService.toUSD(currency: b.currency)
                if b.currency == "USD" {
                    balanceText = "$\(String(format: "%.2f", usd))"
                } else {
                    balanceText = "$\(String(format: "%.2f", usd)) (\(b.currency) \(String(format: "%.2f", b.totalBalance)))"
                }
                keyStatus = .valid
            }
        }
    }

    /// Safety net for a "checking" cycle that never resolves (e.g. the network
    /// request never completes). Normally `keyStatus` is updated as soon as
    /// ApiPoller posts `.apiBalanceDidUpdate`, well before this fires.
    func scheduleCheckTimeout(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) {
            guard generation == checkGeneration, keyStatus == .checking else { return }
            keyStatus = .invalid
            balanceText = I18n.t("apikeys.error") + ": timeout"
        }
    }

    /// Whether the integration is effectively "active" — either detected at scan
    /// time or the user has manually saved a key / enabled it in this session.
    /// For API key types the key's validated status takes precedence.
    var isActive: Bool {
        if isAPIKeyType { return keyStatus == .valid }
        return detected.found || saved
    }

    var iconName: String {
        if detecting { return "arrow.triangle.2circlepath" }
        if isAPIKeyType {
            switch keyStatus {
            case .none:     return "questionmark.circle"
            case .checking: return "arrow.triangle.2circlepath"
            case .valid:    return "checkmark.circle.fill"
            case .invalid:  return "xmark.circle.fill"
            }
        }
        return isActive ? "checkmark.circle.fill" : "questionmark.circle"
    }

    var iconColor: Color {
        if detecting { return .blue }
        if isAPIKeyType {
            switch keyStatus {
            case .none:     return .orange
            case .checking: return .blue
            case .valid:    return .green
            case .invalid:  return .red
            }
        }
        return isActive ? .green : .orange
    }

    @ViewBuilder
    var devToolControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isSubscriptionType {
                labeledPicker(label: I18n.t("integrations.subscription_plan"), selection: $tierInput) {
                    Text(I18n.t("integrations.select_plan")).tag("")
                    ForEach(SubscriptionRegistry.tool(forName: toolDisplayName)?.tiers ?? [], id: \.label) { t in
                        Text("\(t.label) ($\(Int(t.fee))/mo)").tag(t.label)
                    }
                }
                .onChange(of: tierInput) { _, v in
                    if !v.isEmpty { enabled = true; saveConfig(); saveSub(v) }
                }
            }
            labeledPicker(label: I18n.t("integrations.preferred_api_key"), selection: $preferredKeyId) {
                Text(I18n.t("integrations.not_used")).tag("")
                ForEach(availableAPIKeySources, id: \.id) { src in
                    Text(src.label).tag(src.id)
                }
            }
            .onChange(of: preferredKeyId) { _, v in
                savePreferredKey(v)
            }
        }
    }

    func labeledPicker<C: View, V: Hashable>(label: String, selection: Binding<V>,
                                               @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
                .frame(width: 152, alignment: .leading)
            Picker("", selection: selection) { content() }
                .pickerStyle(.menu)
                .frame(width: 184, alignment: .leading)
        }
    }

    @ViewBuilder
    var statusIcon: some View {
        switch keyStatus {
        case .none:
            Image(systemName: "questionmark.circle")
                .foregroundColor(.orange).font(.caption)
        case .checking:
            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
        case .valid:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green).font(.caption)
        case .invalid:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red).font(.caption)
        }
    }

    @ViewBuilder
    var apiKeyControls: some View {
        HStack(spacing: 6) {
            PasteableTextField(text: $keyInput,
                               placeholder: I18n.t("integrations.key_placeholder"))
                .frame(width: 200, height: 22)
            Button(I18n.t("integrations.key_save")) {
                commitKey()
            }
            .buttonStyle(.bordered).controlSize(.small).frame(minWidth: 40)
            statusIcon.frame(width: 16)
        }
    }

    private func commitKey() {
        let k = keyInput.trimmingCharacters(in: .whitespaces)
        if k.isEmpty {
            saved = false; enabled = false
            keyInput = ""
            balanceText = nil
            keyStatus = .none
            checkGeneration += 1
            ApiKeyManager.shared.delete(integration.id)
            ApiPoller.shared.clearCache(for: integration.id)
            saveConfig()
            // No onGrant — this row manages its own state.
            // The parent does NOT need to re-detect all integrations
            // just because one key was deleted.
        } else {
            ApiPoller.shared.clearCache(for: integration.id)
            ApiKeyManager.shared.set(integration.id, key: k)
            saved = true; enabled = true
            saveConfig()
            if let provider = ProviderRegistry.byId(integration.id),
               provider.canFetchBalance {
                keyStatus = .checking
                checkGeneration += 1
                ApiPoller.shared.fetchNow(providerId: integration.id)
                scheduleCheckTimeout(generation: checkGeneration)
            } else {
                keyStatus = .valid
            }
        }
    }

    private var toolDisplayName: String {
        IntegrationRegistry.toolDisplayName(for: integration.id)
    }

    private func saveConfig() {
        var cfg = IntegrationRegistry.config(for: integration.id)
        cfg.enabled = enabled
        if !enabled { cfg.apiKey = "" }
        IntegrationRegistry.setConfig(for: integration.id, cfg)
        if enabled, let c = integration as? Collectable { c.start() }
        else if !enabled, let c = integration as? Collectable { c.stop() }
    }

    private func saveSub(_ tier: String) {
        var cfg = IntegrationRegistry.config(for: integration.id)
        cfg.subscriptionTier = tier
        IntegrationRegistry.setConfig(for: integration.id, cfg)
    }

    private func savePreferredKey(_ keyId: String) {
        var cfg = IntegrationRegistry.config(for: integration.id)
        cfg.preferredAPIKeyCostSourceId = keyId.isEmpty ? nil : keyId
        IntegrationRegistry.setConfig(for: integration.id, cfg)
    }
}
