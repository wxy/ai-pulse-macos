import SwiftUI

/// A single integration row — used identically in Onboarding and Settings.
/// Renders the correct control based on DataGrade:
///   A: toggle (enable/disable log watching)
///   B: API key input + save (balance/usage polling)
///   C: subscription tier picker (monthly plan selection)
struct IntegrationRow: View {
    let integration: any Detectable
    let detected: DetectionResult
    @State private var enabled: Bool
    @State private var keyInput: String
    @State private var tierInput: String
    @State private var saved: Bool

    init(integration: any Detectable, detected: DetectionResult) {
        self.integration = integration
        self.detected = detected
        let cfg = IntegrationRegistry.config(for: integration.id)
        _enabled = State(initialValue: cfg.enabled)
        _keyInput = State(initialValue: ApiKeyManager.shared.get(integration.id) ?? "")
        _tierInput = State(initialValue: cfg.subscriptionTier)
        _saved = State(initialValue: cfg.enabled || !(ApiKeyManager.shared.get(integration.id) ?? "").isEmpty)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            Image(systemName: detected.found ? "checkmark.circle.fill" : "circle")
                .foregroundColor(detected.found ? .green : .secondary)
                .frame(width: 16)

            // Name + detection summary
            VStack(alignment: .leading, spacing: 2) {
                Text(integration.displayName).font(.body)
                Text(detected.summary).font(.caption2).foregroundColor(.secondary)
            }
            .frame(width: 160, alignment: .leading)

            // Grade badge
            Text("[\(integration.grade.rawValue)]")
                .font(.caption2).foregroundColor(.secondary).frame(width: 28)

            // Controls
            if detected.found {
                switch integration.grade {
                case .A:
                    Toggle("", isOn: $enabled)
                        .toggleStyle(.switch)
                        .onChange(of: enabled) { _, v in saveConfig() }
                case .B:
                    HStack(spacing: 4) {
                        TextField("API Key", text: $keyInput)
                            .textFieldStyle(.roundedBorder).frame(width: 160)
                        Button("Save") {
                            ApiKeyManager.shared.set(integration.id, key: keyInput)
                            ApiPoller.shared.fetchNow(providerId: integration.id)
                            enabled = true; saved = true; saveConfig()
                        }.disabled(keyInput.isEmpty)
                        if saved { Image(systemName: "checkmark").foregroundColor(.green).font(.caption) }
                    }
                case .C:
                    HStack(spacing: 4) {
                        Picker("", selection: $tierInput) {
                            Text("None").tag("")
                            ForEach(SubscriptionRegistry.tool(forName: integration.displayName)?.tiers ?? [], id: \.label) { t in
                                Text("\(t.label) ($\(String(format: "%.0f", t.fee))/mo)").tag(t.label)
                            }
                        }.frame(width: 160)
                        .onChange(of: tierInput) { _, v in
                            if !v.isEmpty { enabled = true; saveConfig(); saveSub(v) }
                        }
                    }
                }
            } else {
                Text("Not installed").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(detected.found ? Color(nsColor: .quaternarySystemFill) : .clear)
        .cornerRadius(6)
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
