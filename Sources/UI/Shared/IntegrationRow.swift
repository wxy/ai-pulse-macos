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
    private static let subscriptionIds: Set<String> = ["cursor", "copilot", "windsurf"]

    /// Is this integration primarily an apiKey type?
    var isAPIKeyType: Bool { Self.apiKeyIds.contains(integration.id) }

    /// Is this integration primarily a subscription type?
    var isSubscriptionType: Bool { Self.subscriptionIds.contains(integration.id) }

    /// Does this integration exclusively parse logs (no CostSource of its own)?
    var isLogOnly: Bool {
        !isAPIKeyType && !isSubscriptionType && integration is any Collectable
    }

    /// Claude Code under sandbox needs an explicit ~/.claude directory grant
    var needsGrant: Bool {
        integration.id == "claude-code"
            && BookmarkManager.isSandboxed
            && !BookmarkManager.hasBookmark(covering: BookmarkManager.claudeDirPath)
    }

    var body: some View {
        HStack(spacing: 12) {
            if detecting {
                ProgressView().scaleEffect(0.6).frame(width: 20)
            } else {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)
                    .font(.title3).frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(integration.displayName).font(.body).fontWeight(.medium)
                    costSourceBadge
                }
                Text(summaryText)
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
            }

            Spacer()

            if needsGrant {
                Button(I18n.t("bookmark.grant")) { grantClaude() }
                    .buttonStyle(.bordered).controlSize(.small)
            } else if detected.found || isAPIKeyType || isLogOnly {
                controls
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(detected.found ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .controlBackgroundColor).opacity(0.4))
                .shadow(color: .black.opacity(detected.found ? 0.04 : 0), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }

    var summaryText: String {
        if detected.found { return detected.summary }
        if needsGrant { return I18n.t("onboarding.grant_claude_hint") }
        if isAPIKeyType { return I18n.t("integrations.needs_config_note") }
        return I18n.t("integrations.not_installed_note")
    }

    var iconName: String {
        if detecting { return "arrow.triangle.2circlepath" }
        if needsGrant { return "lock.circle" }
        return detected.found ? "checkmark.circle.fill" : "questionmark.circle"
    }

    var iconColor: Color {
        detecting ? .blue : (detected.found ? .green : .orange)
    }

    var costSourceBadge: some View {
        if isAPIKeyType {
            return AnyView(
                Text("API Key").font(.caption2).fontWeight(.medium)
                    .foregroundColor(.blue)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.blue.opacity(0.12)).cornerRadius(4)
            )
        } else if isSubscriptionType {
            return AnyView(
                Text("Sub").font(.caption2).fontWeight(.medium)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.12)).cornerRadius(4)
            )
        } else {
            return AnyView(
                Text("Log").font(.caption2).fontWeight(.medium)
                    .foregroundColor(.green)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.green.opacity(0.12)).cornerRadius(4)
            )
        }
    }

    @ViewBuilder
    var controls: some View {
        if isLogOnly {
            Toggle("", isOn: $enabled)
                .toggleStyle(.switch).onChange(of: enabled) { _, v in saveConfig() }
        } else if isAPIKeyType {
            apiKeyControls
        } else if isSubscriptionType {
            subscriptionControls
        }
    }

    @ViewBuilder
    var apiKeyControls: some View {
        if showKey {
            HStack(spacing: 6) {
                TextField(I18n.t("integrations.key_placeholder"), text: $keyInput)
                    .textFieldStyle(.roundedBorder).frame(width: 160)
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

    @ViewBuilder
    var subscriptionControls: some View {
        VStack(alignment: .trailing, spacing: 6) {
            let tiers = SubscriptionRegistry.tool(forName: toolDisplayName)?.tiers ?? []
            Picker("", selection: $tierInput) {
                Text(I18n.t("integrations.select_plan")).tag("")
                ForEach(tiers, id: \.label) { t in
                    Text("\(t.label) ($\(Int(t.fee))/mo)").tag(t.label)
                }
            }
            .pickerStyle(.menu).frame(width: 180)
            .onChange(of: tierInput) { _, v in
                if !v.isEmpty { enabled = true; saveConfig(); saveSub(v) }
            }

            // Preferred API Key dropdown: use configured API keys instead of subscription
            if !availableAPIKeySources.isEmpty {
                HStack(spacing: 4) {
                    Text("或使用 API Key:").font(.caption2).foregroundColor(.secondary)
                    Picker("", selection: $preferredKeyId) {
                        Text("(使用套餐)").tag("")
                        ForEach(availableAPIKeySources, id: \.id) { src in
                            Text(src.label).tag(src.id)
                        }
                    }
                    .pickerStyle(.menu).frame(width: 160)
                    .onChange(of: preferredKeyId) { _, v in savePreferredKey(v) }
                }
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
