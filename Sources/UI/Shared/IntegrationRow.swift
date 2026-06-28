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
        HStack(alignment: .top, spacing: 0) {
            // Icon
            Image(systemName: detected.found ? "checkmark.circle.fill" : "circle")
                .foregroundColor(detected.found ? .green : .secondary)
                .font(.title3)
                .frame(width: 28, alignment: .top)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(integration.displayName).font(.body).fontWeight(.medium)
                    gradeBadge
                }
                Text(detected.found ? detected.summary : "Not installed")
                    .font(.caption).foregroundColor(.secondary)
                    .lineLimit(2)

                if detected.found {
                    controls
                        .padding(.top, 6)
                }
            }
            .padding(.leading, 8)

            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(detected.found ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                .shadow(color: .black.opacity(detected.found ? 0.04 : 0), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(detected.found ? 0.5 : 0), lineWidth: 0.5)
        )
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
            HStack {
                Toggle(enabled ? "Enabled" : "Disabled", isOn: $enabled)
                    .toggleStyle(.switch)
                    .onChange(of: enabled) { _, v in saveConfig() }
                Spacer()
            }

        case .B:
            if showKey {
                HStack(spacing: 8) {
                    TextField("Paste API Key", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Button("Save") {
                        let k = keyInput.trimmingCharacters(in: .whitespaces)
                        if k.isEmpty { return }
                        ApiKeyManager.shared.set(integration.id, key: k)
                        ApiPoller.shared.fetchNow(providerId: integration.id)
                        enabled = true; saved = true; showKey = false
                        saveConfig()
                    }.disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { showKey = false }
                        .disabled(false)
                }
            } else {
                HStack {
                    Text("••••••••").foregroundColor(.secondary)
                    Button("Change Key") { keyInput = ""; showKey = true }
                    if saved { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption) }
                    Spacer()
                }
            }

        case .C:
            let tiers = SubscriptionRegistry.tool(forName: integration.displayName)?.tiers ?? []
            HStack {
                Picker("Plan", selection: $tierInput) {
                    Text("None").tag("")
                    ForEach(tiers, id: \.label) { t in
                        Text("\(t.label) ($\(String(format: "%.0f", t.fee))/mo)").tag(t.label)
                    }
                }
                .pickerStyle(.menu).frame(maxWidth: 240)
                .onChange(of: tierInput) { _, v in
                    if !v.isEmpty { enabled = true; saveConfig(); saveSub(v) }
                }
                Spacer()
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
