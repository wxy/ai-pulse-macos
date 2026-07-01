import SwiftUI

/// Integration row — used in Onboarding and Settings.
/// Grade-adaptive: A=toggle, B=key+save, C=plan picker.
struct IntegrationRow: View {
    let integration: any Detectable
    let detected: DetectionResult
    @State private var enabled: Bool
    @State private var keyInput: String
    @State private var tierInput: String
    @State private var saved: Bool
    @State private var showKey: Bool = false
    @State private var detecting: Bool = false

    init(integration: any Detectable, detected: DetectionResult) {
        self.integration = integration
        self.detected = detected
        let cfg = IntegrationRegistry.config(for: integration.id)
        let hasKey = !(ApiKeyManager.shared.get(integration.id) ?? "").isEmpty
        _enabled = State(initialValue: cfg.enabled)
        _keyInput = State(initialValue: "")
        _tierInput = State(initialValue: cfg.subscriptionTier)
        _saved = State(initialValue: cfg.enabled || hasKey)
        _showKey = State(initialValue: !hasKey)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            if detecting {
                ProgressView().scaleEffect(0.6).frame(width: 20)
            } else {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)
                    .font(.title3).frame(width: 20)
            }

            // Name + badge + summary
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(integration.displayName).font(.body).fontWeight(.medium)
                    gradeBadge
                }
                Text(summaryText)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }

            Spacer()

            // Controls on the right. B-grade always shows key input (not auto-detectable).
            if detected.found || integration.grade == .B {
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
        if integration.grade == .B { return I18n.t("integrations.needs_config_note") }
        return I18n.t("integrations.not_installed_note")
    }

    var iconName: String {
        if detecting { return "arrow.triangle.2.circlepath" }
        return detected.found ? "checkmark.circle.fill" : "questionmark.circle"
    }

    var iconColor: Color {
        detecting ? .blue : (detected.found ? .green : .orange)
    }

    var gradeBadge: some View {
        let (label, color): (String, Color) = {
            switch integration.grade {
            case .A: return ("CPL", .green)
            case .B: return ("Balance", .blue)
            case .C: return ("Sub", .orange)
            }
        }()
        return Text(label).font(.caption2).fontWeight(.medium)
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.12))
            .cornerRadius(4)
    }

    @ViewBuilder
    var controls: some View {
        switch integration.grade {
        case .A:
            Toggle("", isOn: $enabled)
                .toggleStyle(.switch).onChange(of: enabled) { _, v in saveConfig() }

        case .B:
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
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(minWidth: 40)
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

        case .C:
            let tiers = SubscriptionRegistry.tool(forName: integration.displayName)?.tiers ?? []
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
        }
    }

    private func saveConfig() {
        var cfg = IntegrationRegistry.config(for: integration.id)
        cfg.enabled = enabled
        IntegrationRegistry.setConfig(for: integration.id, cfg)
        if enabled, let c = integration as? Collectable { c.start() }
        else if !enabled, let c = integration as? Collectable { c.stop() }
    }

    private func saveSub(_ tier: String) {
        var cfg = IntegrationRegistry.config(for: integration.id)
        cfg.subscriptionTier = tier
        IntegrationRegistry.setConfig(for: integration.id, cfg)
    }
}
