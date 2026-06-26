import SwiftUI
import AppKit

@main
struct AIPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            Text("AI Pulse Settings — coming in M1")
                .frame(width: 400, height: 300)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize database
        do {
            try AppDatabase.shared.setup()
        } catch {
            print("Database setup failed: \(error)")
        }

        // Start menu bar
        menuBarController = MenuBarController()
        menuBarController?.start()

        // Start log watcher
        LogWatcher.shared.start()

        // Hide from Dock — menu bar only
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        LogWatcher.shared.stop()
    }
}
