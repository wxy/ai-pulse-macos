import SwiftUI
import CloudKit

@main
struct AIPulse_iOSApp: App {
    @StateObject private var cloudData = CloudDataService.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cloudData)
                .task { await NotificationService.shared.setup() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            NotificationService.shared.didReceiveRemoteNotification()
            completionHandler(.newData)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var cloudData: CloudDataService
    @State private var hasData: Bool?

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
