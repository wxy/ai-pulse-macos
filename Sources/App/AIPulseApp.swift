import AppKit

// Menu-bar-only app. main.swift sets .accessory BEFORE NSApp.run() and
// calls activate() after a short delay to prevent the race where the
// system ignores the status item.

final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try AppDatabase.shared.setup() }
        catch { print("DB setup failed: \(error)") }

        menuBarController = MenuBarController()
        menuBarController?.start()

        LogWatcher.shared.start()

        // Extra activation after menu bar setup (belt-and-suspenders with main.swift)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        LogWatcher.shared.stop()
    }
}
