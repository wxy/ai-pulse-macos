import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try AppDatabase.shared.setup() }
        catch { print("DB setup failed: \(error)") }

        menuBarController = MenuBarController()
        menuBarController?.start()

        LogWatcher.shared.start()

        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        LogWatcher.shared.stop()
    }
}
