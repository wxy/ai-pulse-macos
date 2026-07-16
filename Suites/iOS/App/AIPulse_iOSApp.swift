import SwiftUI

/// iOS + iPadOS app entry point.
/// Read-only: displays spending data synced from macOS via iCloud.
@main
struct AIPulse_iOSApp: App {
    @StateObject private var cloudData = CloudDataService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cloudData)
        }
    }
}

/// Content root: shows Dashboard if iCloud data exists,
/// otherwise shows Welcome guide to install macOS version.
struct ContentView: View {
    @EnvironmentObject var cloudData: CloudDataService
    @State private var hasData: Bool? = nil

    var body: some View {
        Group {
            if hasData == nil {
                ProgressView("Checking iCloud…")
            } else if hasData == true {
                DashboardView()
            } else {
                WelcomeView()
            }
        }
        .task {
            do {
                hasData = try await cloudData.hasData()
                if hasData == true { try? await cloudData.fetchAll(days: 30) }
            } catch {
                hasData = false
            }
        }
    }
}
