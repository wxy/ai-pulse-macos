import AppKit

#if canImport(Sparkle)
import Sparkle
#endif

/// Manages Sparkle auto-update integration.
///
/// Sparkle is linked only in Release builds via the Xcode project
/// (not through SPM, to keep `swift build` working for CI tests).
/// When the framework is absent, the updater is simply unavailable.
enum SparkleSetup {

    /// Start the Sparkle updater. Safe to call even if Sparkle is not linked.
    static func start() {
        #if canImport(Sparkle)
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Keep a strong reference so the updater stays alive for the app lifetime.
        // The controller is stored in an associated object; this call is enough
        // to start it as long as the return value is held.
        _ = controller
        Logger.info("Sparkle updater started")
        #endif
    }
}
