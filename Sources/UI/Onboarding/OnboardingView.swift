import SwiftUI

struct OnboardingView: View {
    @State private var step = 0
    @State private var detectionResults: [(any Detectable, DetectionResult)] = []
    @State private var enabledIds: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }.padding(.top, 20).padding(.bottom, 8)

            Group {
                switch step {
                case 0: welcomeStep
                case 1: detectionStep
                case 2: configureStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Navigation
            HStack {
                if step > 0 {
                    Button("← Back") { step -= 1 }
                }
                Spacer()
                if step < 3 {
                    Button(step == 2 ? "Finish" : "Next →") {
                        if step == 2 { finish() }
                        step += 1
                    }
                    .disabled(step == 2 && enabledIds.isEmpty)
                } else {
                    Button("Close") { close() }
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
        .frame(width: 520, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { runDetection() }
    }

    // MARK: - Step 0: Welcome

    var welcomeStep: some View {
        VStack(spacing: 16) {
            Text("🤖").font(.system(size: 56))
            Text("AI Pulse").font(.title).fontWeight(.bold)
            Text("Your AI Fuel Gauge")
                .font(.title2).foregroundColor(.secondary)
            Text("Know what AI coding really costs you — across all your tools, subscriptions, and API keys.")
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Text("All data stays on your machine.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: - Step 1: Detection results

    var detectionStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Detected Tools").font(.title3).fontWeight(.semibold)
            Text("We scan your machine for AI tools and API keys. Enable what you want to track.")
                .font(.caption).foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(detectionResults, id: \.0.id) { (integration, result) in
                        HStack {
                            Image(systemName: result.found ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(result.found ? .green : .secondary)
                            Text(integration.displayName).font(.body)
                            Spacer()
                            gradeBadge(integration.grade)
                            Text(result.summary).font(.caption2).foregroundColor(.secondary)
                                .frame(width: 140, alignment: .leading).lineLimit(1)
                            if result.found {
                                Toggle("", isOn: Binding(
                                    get: { enabledIds.contains(integration.id) },
                                    set: { v in
                                        if v { enabledIds.insert(integration.id) }
                                        else { enabledIds.remove(integration.id) }
                                    }
                                ))
                                .toggleStyle(.switch)
                                .frame(width: 50)
                            } else {
                                Text("—").foregroundColor(.secondary).frame(width: 50)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(result.found ? Color(nsColor: .quaternarySystemFill) : .clear)
                        .cornerRadius(6)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Step 2: Configure

    var configureStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configure Enabled Tools").font(.title3).fontWeight(.semibold)
            Text("Some tools need a little setup to start tracking.")
                .font(.caption).foregroundColor(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(enabledIds), id: \.self) { id in
                        if let i = detectionResults.first(where: { $0.0.id == id })?.0 {
                            configCard(for: i)
                        }
                    }
                    if enabledIds.isEmpty {
                        Text("No tools enabled. Go back and enable at least one.")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    func configCard(for i: any Detectable) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(i.displayName).font(.body).fontWeight(.semibold)
                Spacer()
                gradeBadge(i.grade)
            }
            switch i.grade {
            case .A:
                Text("Reads AI session logs locally. No data leaves your machine. No API key needed.")
                    .font(.caption2).foregroundColor(.secondary)
            case .B:
                Text("Polls the official API for usage/balance data. Requires an API key — configure in Settings → API Keys after onboarding.")
                    .font(.caption2).foregroundColor(.secondary)
            case .C:
                Text("Fixed monthly subscription. Select your plan in Settings → Subscriptions after onboarding.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .quaternarySystemFill))
        .cornerRadius(8)
    }

    // MARK: - Step 3: Done

    var doneStep: some View {
        VStack(spacing: 16) {
            Text("🎉").font(.system(size: 48))
            Text("You're All Set").font(.title2).fontWeight(.bold)
            Text("\(enabledIds.count) tools enabled. Menu bar will show today's spend shortly.")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            if enabledIds.contains(where: { id in
                detectionResults.first(where: { $0.0.id == id })?.0.grade == .A
            }) {
                Text("Dashboard is available with CPL stats since you enabled an A-grade tool.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    func gradeBadge(_ g: DataGrade) -> some View {
        Text("[\(g.rawValue)] \(gradeLabel(g))")
            .font(.caption2).foregroundColor(.secondary)
    }

    func gradeLabel(_ g: DataGrade) -> String {
        switch g {
        case .A: return "CPL"
        case .B: return "Balance"
        case .C: return "Sub"
        }
    }

    func runDetection() {
        detectionResults = IntegrationRegistry.all.map { ($0, $0.detect()) }
        // Auto-enable detected A-grade integrations
        for (i, r) in detectionResults where r.found && i.grade == .A {
            enabledIds.insert(i.id)
        }
    }

    func finish() {
        for id in enabledIds {
            var cfg = IntegrationRegistry.config(for: id)
            cfg.enabled = true
            IntegrationRegistry.setConfig(for: id, cfg)
        }
        // Start any newly enabled Collectable integrations
        IntegrationRegistry.startAllEnabled()
        // Mark onboarding complete
        UserDefaults.standard.set(true, forKey: "onboarding_completed")
    }

    func close() {
        finish()
        OnboardingWindowManager.shared.window?.close()
    }
}

// MARK: - Window Manager

final class OnboardingWindowManager {
    static let shared = OnboardingWindowManager()
    var window: NSWindow?
}
