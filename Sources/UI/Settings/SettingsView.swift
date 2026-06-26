import SwiftUI

struct SettingsView: View {
    @State private var claudeCodeEnabled = true
    @State private var aiderEnabled = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            MonitoredToolsView(
                claudeCodeEnabled: $claudeCodeEnabled,
                aiderEnabled: $aiderEnabled
            )
            .tabItem { Label("Tools", systemImage: " hammer ") }
            .tag(0)

            PricingView()
                .tabItem { Label("Pricing", systemImage: "dollarsign.circle") }
                .tag(1)

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(2)
        }
        .frame(width: 480, height: 360)
    }
}

struct MonitoredToolsView: View {
    @Binding var claudeCodeEnabled: Bool
    @Binding var aiderEnabled: Bool

    var body: some View {
        Form {
            Section(header: Text("Monitored AI Tools").font(.headline)) {
                Toggle(isOn: $claudeCodeEnabled) {
                    HStack {
                        Text("Claude Code")
                        Text("~/.claude/projects/")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Toggle(isOn: $aiderEnabled) {
                    HStack {
                        Text("aider (coming soon)")
                            .foregroundColor(.secondary)
                        Text("repo/.aider.chat.history.md")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(true)
            }

            Section(header: Text("Configuration").font(.headline)) {
                HStack {
                    Text("Pricing catalog")
                    Spacer()
                    Text("12 models loaded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Database")
                    Spacer()
                    Text("~/Library/Application Support/AIPulse/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding()
    }
}

struct PricingRow: Identifiable {
    let id = UUID()
    let name: String
    let provider: String
    let input: Double
    let output: Double
}

struct PricingView: View {
    let models: [PricingRow] = [
        PricingRow(name: "DeepSeek V4 Pro", provider: "deepseek", input: 0.5, output: 2.2),
        PricingRow(name: "DeepSeek V4 Flash", provider: "deepseek", input: 0.25, output: 1.1),
        PricingRow(name: "DeepSeek Chat (V3)", provider: "deepseek", input: 0.27, output: 1.1),
        PricingRow(name: "DeepSeek Reasoner (R1)", provider: "deepseek", input: 0.55, output: 2.19),
        PricingRow(name: "Claude Sonnet 4", provider: "anthropic", input: 3.0, output: 15.0),
        PricingRow(name: "Claude Opus 4", provider: "anthropic", input: 15.0, output: 75.0),
        PricingRow(name: "GPT-4o", provider: "openai", input: 2.5, output: 10.0),
        PricingRow(name: "GPT-4o Mini", provider: "openai", input: 0.15, output: 0.6),
        PricingRow(name: "Gemini 2.5 Pro", provider: "google", input: 1.25, output: 10.0),
        PricingRow(name: "Gemini 2.5 Flash", provider: "google", input: 0.15, output: 0.6),
    ]

    var body: some View {
        List(models) { m in
            HStack {
                Text(m.name).frame(width: 160, alignment: .leading)
                Text(m.provider).frame(width: 80, alignment: .leading)
                    .foregroundColor(.secondary)
                Text("in: $\(String(format: "%.2f", m.input))").frame(width: 80, alignment: .trailing)
                Text("out: $\(String(format: "%.2f", m.output))").frame(width: 80, alignment: .trailing)
            }
            .font(.caption)
        }
        .padding()
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("🤖")
                .font(.system(size: 48))
            Text("AI Pulse")
                .font(.title)
                .fontWeight(.bold)
            Text("Version 0.1.0 (M1)")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Know what AI coding really costs you — per line, per project, per tool.")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Text("All data processed locally. Nothing leaves your machine.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}
