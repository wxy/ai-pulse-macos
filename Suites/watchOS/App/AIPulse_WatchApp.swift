import SwiftUI

/// watchOS app entry point.
/// Shows today's spend on the watch face complication and in-app.
@main
struct AIPulse_WatchApp: App {
    @WKApplicationDelegateAdaptor var delegate: WatchAppDelegate

    var body: some Scene {
        WindowGroup {
            SpendView()
        }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        // TODO: register for APNs silent notifications
    }
}

/// Watch app content: today's spend + ring progress.
struct SpendView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("$0.00")
                .font(.system(size: 36, weight: .bold, design: .rounded))

            Circle()
                .stroke(.secondary.opacity(0.2), lineWidth: 6)
                .frame(width: 60, height: 60)
                .overlay {
                    Text("0%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
        }
    }
}
