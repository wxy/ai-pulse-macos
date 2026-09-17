import Foundation

/// Opt-in UI verification only in a dedicated, separately built Debug bundle.
/// Never redirects or disables collection for the user's normal app.
enum RuntimeQA {
    /// One-shot, explicit local Git runtime probe in the isolated QA profile.
    /// Never enables source timers, account polling, cloud writes or permissions.
    static let pollLocalGitOnceKey = "qa_poll_local_git_once"

    static func consumeLocalGitProbe() -> Bool {
        guard isEnabled, UserDefaults.standard.bool(forKey: pollLocalGitOnceKey) else { return false }
        UserDefaults.standard.removeObject(forKey: pollLocalGitOnceKey)
        return true
    }

    static var isEnabled: Bool {
        #if DEBUG
        Bundle.main.bundleIdentifier == "xingyu.wang.aipulse.runtimeqa"
        #else
        false
        #endif
    }
}
