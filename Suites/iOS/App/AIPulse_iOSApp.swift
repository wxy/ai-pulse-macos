import SwiftUI
import CloudKit
import UserNotifications

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
    @State private var splashVisible = true

    var body: some View {
        Group {
            if splashVisible || hasData == nil {
                // Splash screen — shown for at least 1.5s while checking iCloud
                VStack(spacing: 16) {
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 18).fill(.white)
                        RoundedRectangle(cornerRadius: 18).stroke(Color.marsGreen.opacity(0.3), lineWidth: 2)
                        Text("AI").font(.system(size: 28, weight: .bold)).foregroundStyle(Color.marsGreen)
                    }.frame(width: 80, height: 80)
                    Text("AI Pulse")
                        .font(.title2).fontWeight(.bold)
                    ProgressView(I18n.t("loading"))
                        .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
            } else if hasData == true {
                DashboardView()
            } else {
                WelcomeView()
            }
        }
        .task {
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
            do {
                hasData = try await cloudData.hasData()
                if hasData == true { try? await cloudData.fetchSnapshot() }
            } catch {
                hasData = false
            }
            // Keep splash visible at least 1.5s for smooth transition
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { splashVisible = false }
        }
    }
}
