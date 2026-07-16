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
    @State private var showKey: Bool = false
    @State private var detecting: Bool = false
    @State private var preferredKeyId: String
    @State private var balanceText: String? = nil

    init(integration: any Detectable, detected: DetectionResult, onGrant: (() -> Void)? = nil) {
        self.integration = integration
        self.detected = detected
        self.onGrant = onGrant
        let cfg = IntegrationRegistry.config(for: integration.id)
        let hasKey = !(ApiKeyManager.shared.get(integration.id) ?? "").isEmpty
        _enabled = State(initialValue: cfg.enabled)
        _keyInput = State(initialValue: "")
        _tierInput = State(initialValue: cfg.subscriptionTier)
        _saved = State(initialValue: cfg.enabled || hasKey)
        _showKey = State(initialValue: !hasKey)
        _preferredKeyId = State(initialValue: cfg.preferredAPIKeyCostSourceId ?? "")
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
    private static let logToolIds: Set<String> = ["aider"]

    /// Is this integration primarily an apiKey type?
    var isAPIKeyType: Bool { Self.apiKeyIds.contains(integration.id) }

    /// Is this integration primarily a subscription type?
    var isSubscriptionType: Bool { Self.subscriptionIds.contains(integration.id) }

    /// Log-based dev tool: can use API keys but has no subscription tiers.
    var isLogTool: Bool { Self.logToolIds.contains(integration.id) }


    /// Claude Code under sandbox needs an explicit ~/.claude directory grant
    var needsGrant: Bool {
        integration.id == "claude-code"
            && BookmarkManager.isSandboxed
            && !BookmarkManager.hasBookmark(covering: BookmarkManager.claudeDirPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                if detecting {
                    ProgressView().scaleEffect(0.6).frame(width: 20)
                } else {
                    Image(systemName: iconName)
                        .foregroundColor(iconColor)
                        .font(.title3).frame(width: 20)
                }

                Text(integration.displayName).font(.body).fontWeight(.medium)

                if !(detected.found || isAPIKeyType) {
                    Text(summaryText)
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }

                Spacer()

                if needsGrant {
                    Button(I18n.t("bookmark.grant")) { grantClaude() }
                        .buttonStyle(.bordered).controlSize(.small)
                } else if isAPIKeyType {
                    controls
                } else if detected.found {
                    Text(summaryText)
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }

            if !isAPIKeyType && detected.found {
                devToolControls
                    .padding(.leading, 32)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .opacity(detected.found ? 1 : 0.5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(detected.found ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .controlBackgroundColor).opacity(0.4))
                .shadow(color: .black.opacity(detected.found ? 0.04 : 0), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
        .onAppear { refreshBalance() }
    }

    var summaryText: String {
        if detected.found {
            if isAPIKeyType, let bal = balanceText { return bal }
            return detected.summary
        }
        if needsGrant { return I18n.t("onboarding.grant_claude_hint") }
        if isAPIKeyType { return I18n.t("integrations.needs_config_note") }
        return I18n.t("integrations.not_installed_note")
    }

    func refreshBalance() {
        guard isAPIKeyType else { return }
        if let cb = ApiPoller.shared.cachedBalance(for: integration.id) {
            if let err = cb.error {
                balanceText = I18n.t("apikeys.error") + ": \(err)"
            } else if let b = cb.balances.first {
                let usd = b.totalBalance * StatsService.toUSD(currency: b.currency)
                if b.currency == "USD" {
                    balanceText = "$\(String(format: "%.2f", usd))"
                } else {
                    balanceText = "$\(String(format: "%.2f", usd)) (\(b.currency) \(String(format: "%.2f", b.totalBalance)))"
                }
            }
        }
    }

    var iconName: String {
        if detecting { return "arrow.triangle.2circlepath" }
        if needsGrant { return "lock.circle" }
        return detected.found ? "checkmark.circle.fill" : "questionmark.circle"
    }

    var iconColor: Color {
        detecting ? .blue : (detected.found ? .green : .orange)
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

    @ViewBuilder
    var controls: some View {
        if isAPIKeyType {
            apiKeyControls
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
    var apiKeyControls: some View {
        if showKey {
            HStack(spacing: 6) {
                TextField(I18n.t("integrations.key_placeholder"), text: $keyInput)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                Button(I18n.t("integrations.key_save")) {
                    let k = keyInput.trimmingCharacters(in: .whitespaces)
                    guard !k.isEmpty else { return }
                    ApiKeyManager.shared.set(integration.id, key: k)
                    ApiPoller.shared.fetchNow(providerId: integration.id)
                    enabled = true; saved = true; showKey = false; saveConfig()
                }
                .buttonStyle(.bordered).controlSize(.small).frame(minWidth: 40)
                .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else {
            HStack(spacing: 6) {
                Text("••••••••").foregroundColor(.secondary)
                Button(I18n.t("integrations.key_change")) { keyInput = ""; showKey = true }
                    .font(.caption).buttonStyle(.borderless).frame(minWidth: 32)
                if saved { Image(systemName: "checkmark.circle.fill").foregroundColor(.green) }
            }
        }
    }

    private var toolDisplayName: String {
        switch integration.id {
        case "cursor":   return "Cursor"
        case "copilot":  return "GitHub Copilot"
        case "windsurf": return "Windsurf"
        default:         return integration.displayName
        }
    }

    private func saveConfig() {
        var cfg = IntegrationRegistry.config(for: integration.id)
        cfg.enabled = enabled
        IntegrationRegistry.setConfig(for: integration.id, cfg)
        if enabled, let c = integration as? Collectable { c.start() }
        else if !enabled, let c = integration as? Collectable { c.stop() }
    }

    private func grantClaude() {
        guard BookmarkManager.requestClaudeAccess(message: I18n.t("bookmark.claude_message")) != nil
        else { return }
        var cfg = IntegrationRegistry.config(for: integration.id)
        cfg.enabled = true
        IntegrationRegistry.setConfig(for: integration.id, cfg)
        (integration as? Collectable)?.start()
        onGrant?()
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
