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

enum AppState: Equatable {
    case loading
    case ready
    case noData
    case error
}

struct ContentView: View {
    @EnvironmentObject var cloudData: CloudDataService
    @State private var state: AppState = .loading
    @State private var splashVisible = true

    var body: some View {
        Group {
            if splashVisible || state == .loading {
                // Splash screen — shown for at least 1.5s while checking iCloud
                VStack(spacing: 16) {
                    Spacer()
                    Image("Logo").resizable().frame(width: 80, height: 80).cornerRadius(18)
                    Text(I18n.t("welcome.title"))
                        .font(.title2).fontWeight(.bold)
                    ProgressView(I18n.t("loading"))
                        .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
            } else if case .ready = state {
                DashboardView()
            } else if case .noData = state {
                WelcomeView()
            } else if case .error = state {
                CloudErrorView { await checkCloud(isRetry: true) }
            }
        }
        .task {
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
            await checkCloud()
            // Keep splash visible at least 1.5s for smooth transition
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { splashVisible = false }
        }
    }

    private func checkCloud(isRetry: Bool = false) async {
        if !isRetry { state = .loading }
        do {
            _ = try await cloudData.hasData()
            state = .ready
        } catch CloudError.noData {
            state = .noData
        } catch {
            state = .error
        }
    }
}
