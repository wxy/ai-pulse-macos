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
                if step < 2 {
                    Button("Next →") { step += 1 }
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
        let detected = detectionResults.filter(\.1.found)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Detected Tools").font(.title3).fontWeight(.semibold)
            Text("Enable what you want to track. More tools available in Settings → Integrations.")
                .font(.caption).foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(detected, id: \.0.id) { (integration, result) in
                        IntegrationRow(integration: integration, detected: result)
                    }
                    if detected.isEmpty {
                        Text("No AI tools detected. Open Settings → Integrations to see all supported tools.")
                            .foregroundColor(.secondary).padding()
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Step 2: Done

    var doneStep: some View {
        VStack(spacing: 16) {
            Text("🎉").font(.system(size: 48))
            Text("You're All Set").font(.title2).fontWeight(.bold)
            Text("\(enabledIds.count) tools enabled. Menu bar will show today's spend shortly.")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            if detectionResults.contains(where: { $0.1.found && $0.0.grade == .A }) {
                Text("Dashboard available with CPL stats (A-grade tool detected).")
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
        // Auto-enable detected A-grade integrations (zero-config, just consent)
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
        IntegrationRegistry.startAllEnabled()
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
