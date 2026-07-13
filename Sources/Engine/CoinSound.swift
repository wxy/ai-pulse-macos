import AppKit

/// Plays coin sounds when AI spend is detected.
/// Prefers bundled MP3 files; falls back to synthesized WAV; beep as last resort.
enum CoinSound {

    /// Keep active sounds alive with strong references so they don't dealloc mid-playback.
    /// Overlapping sounds (e.g., multi-coin for large spend) each get their own slot;
    /// cleaned up after their duration elapses.
    @MainActor private static var activeSounds = Set<NSSound>()

    // MARK: - Public

    /// Play coin sound(s) scaled to the spend amount.
    /// Larger spend → multiple-coin sound.
    @MainActor static func play(for spend: Double) {
        guard UserDefaults.standard.bool(forKey: "coin_sound_enabled") else { return }

        if spend >= 1.00 {
            // Big spend: play the multi-coin sound
            playBundleSound(named: "coins", ext: "mp3")
        } else if spend >= 0.10 {
            // Medium: single coin, twice
            playBundleSound(named: "coin", ext: "mp3")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                playBundleSound(named: "coin", ext: "mp3")
            }
        } else {
            // Small: single coin
            playBundleSound(named: "coin", ext: "mp3")
        }
    }

    /// Play a single coin sound when new data arrives.
    /// Throttled to once per minute so rapid ingestion cycles (Phase 1 at 30s)
    /// don't produce a storm of audio cues.
    /// - Parameter bypassThrottle: if true, ignores the 60-second cooldown
    ///   (used for startup chime).
    @MainActor static func playForDataChange(bypassThrottle: Bool = false) {
        guard UserDefaults.standard.bool(forKey: "coin_sound_enabled") else {
            Logger.debug("CoinSound: playForDataChange skipped — sound disabled")
            return
        }
        let now = Date()
        if !bypassThrottle {
            guard now.timeIntervalSince(lastDataChangeSoundTime) >= 60 else {
                Logger.debug("CoinSound: playForDataChange throttled (last was \(String(format: "%.0f", now.timeIntervalSince(lastDataChangeSoundTime)))s ago)")
                return
            }
        }
        lastDataChangeSoundTime = now
        Logger.debug("CoinSound: playForDataChange → playing\(bypassThrottle ? " (startup)" : "")")
        playBundleSound(named: "coin", ext: "mp3")
    }

    @MainActor private static var lastDataChangeSoundTime: Date = .distantPast

    // MARK: - Playback

    @MainActor private static func playBundleSound(named name: String, ext: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            Logger.debug("CoinSound: '\(name).\(ext)' not in bundle, falling back to beep")
            NSSound.beep()
            return
        }
        guard let sound = NSSound(contentsOf: url, byReference: false) else {
            Logger.debug("CoinSound: NSSound(contentsOf:) failed for \(url.lastPathComponent), falling back to beep")
            NSSound.beep()
            return
        }
        Logger.debug("CoinSound: playing \(url.lastPathComponent) (duration: \(String(format: "%.2f", sound.duration))s)")
        activeSounds.insert(sound)
        sound.play()
        // NSSound retains itself during playback, but we keep a reference in
        // activeSounds to prevent premature deallocation. Clean up after the
        // sound's natural duration so the set doesn't grow unboundedly.
        let deadline = DispatchTime.now() + DispatchTimeInterval.milliseconds(Int(sound.duration * 1000) + 50)
        DispatchQueue.main.asyncAfter(deadline: deadline) {
            activeSounds.remove(sound)
        }
    }
}
