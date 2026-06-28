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
                                switch integration.grade {
                                case .A:
                                    // A-grade: zero-config, just toggle
                                    Toggle("", isOn: Binding(
                                        get: { enabledIds.contains(integration.id) },
                                        set: { v in
                                            if v { enabledIds.insert(integration.id) }
                                            else { enabledIds.remove(integration.id) }
                                        }
                                    ))
                                    .toggleStyle(.switch).frame(width: 50)
                                case .B:
                                    Button("Set Key") { openSettings(tab: "API Keys") }
                                        .font(.caption2)
                                case .C:
                                    Button("Choose Plan") { openSettings(tab: "Subscriptions") }
                                        .font(.caption2)
                                }
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

    // MARK: - Step 2: Done

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
        // Auto-enable detected A-grade integrations (zero-config, just consent)
        for (i, r) in detectionResults where r.found && i.grade == .A {
            enabledIds.insert(i.id)
        }
    }

    func openSettings(tab: String) {
        // Open Settings to the right tab
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = I18n.t("settings.title")
        w.contentView = NSHostingView(rootView: SettingsView(initialTab: tab))
        w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
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
