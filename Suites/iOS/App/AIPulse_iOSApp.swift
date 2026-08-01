import SwiftUI
import CloudKit
import UserNotifications
import UIKit

@main
struct AIPulse_iOSApp: App {
    @StateObject private var cloudData = CloudDataService.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cloudData)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UserDefaults.standard.register(defaults: ["coin_sound_enabled": true])
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
            if splashVisible || (state == .loading && cloudData.snapshot == nil) {
                // Splash — shown for a brief branded moment even when cache
                // exists. The CloudKit check runs in parallel without blocking.
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
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else if case .ready = state {
                DashboardView()
            } else if case .noData = state {
                WelcomeView()
            } else if case .error = state {
                CloudErrorView { await checkCloud(isRetry: true) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await NotificationService.refreshSoundSetting() }
        }
        .task {
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
            await NotificationService.shared.setup()
            let hasCache = cloudData.snapshot != nil
            // Always show splash for at least 0.8s. CloudKit runs in parallel
            // — it never blocks the splash timeout when cache exists.
            async let ck: Void = checkCloud()
            async let minimum = try? Task.sleep(nanoseconds: 800_000_000)
            if hasCache {
                state = .ready
                _ = await minimum
            } else {
                _ = await ck
                _ = await minimum
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { splashVisible = false }
        }
    }

    private func checkCloud(isRetry: Bool = false) async {
        let hasCache = cloudData.snapshot != nil
        // Only show loading if there's genuinely nothing to display.
        if !isRetry && !hasCache { state = .loading }
        do {
            // Fetch only today's snapshot at launch. Week and 30d data are
            // loaded lazily when the user switches tabs (DashboardView's
            // .onChange(of: timeRange) → fetchSnapshot). This keeps launch
            // fast and avoids unnecessary CloudKit operations.
            _ = try await cloudData.hasData()
            state = .ready
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch CloudError.noData {
            state = .noData
        } catch {
            // If we have cached data from a previous session, show it even when offline.
            // Only show the error screen if there's nothing to display.
            if hasCache {
                state = .ready
            } else {
                state = .error
            }
        }
    }
}
