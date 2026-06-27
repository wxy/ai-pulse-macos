import AppKit

// Menu-bar-only app.
// .accessory must be set BEFORE NSApp.run() to avoid a race where the
// system classifies the process as a regular app and ignores the status item.
// An extra activate() after a short delay ensures the menu bar item responds.
autoreleasepool {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate

    // Delayed activation: gives the window server time to register the
    // .accessory policy before we force-activate, preventing Dock-dance.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        NSApp.activate(ignoringOtherApps: true)
    }

    // SIGHUP ("hug") → restart the app. Used by `kill -HUP <pid>` or `make hup`.
    signal(SIGHUP, SIG_IGN)
    let sigSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
    sigSource.setEventHandler {
        // Resolve the real binary path. CommandLine.arguments[0] is reliable
        // when the binary is invoked directly (not through a symlink chain).
        let execPath = CommandLine.arguments[0]
        print("AIPulse: SIGHUP received, restarting via \(execPath)")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [execPath]
        // Inherit the same environment so DB / log paths resolve correctly
        task.environment = ProcessInfo.processInfo.environment
        do { try task.run() } catch { print("AIPulse: SIGHUP restart failed: \(error)") }
        exit(0)
    }
    sigSource.resume()

    app.run()
}
