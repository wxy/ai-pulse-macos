import SwiftUI

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

struct ContentView: View {
    @EnvironmentObject var cloudData: CloudDataService
    @State private var hasData: Bool? = nil

    var body: some View {
        Group {
            if hasData == nil {
                ProgressView(I18n.t("loading"))
            } else if hasData == true {
                DashboardView()
            } else {
                WelcomeView()
            }
        }
        .task {
            do {
                hasData = try await cloudData.hasData()
                if hasData == true { try? await cloudData.fetchSnapshot() }
            } catch {
                hasData = false
            }
        }
    }
}
