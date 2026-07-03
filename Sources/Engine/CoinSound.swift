import AppKit

/// Plays coin sounds when AI spend is detected.
/// Prefers bundled MP3 files; falls back to synthesized WAV; beep as last resort.
enum CoinSound {

    /// Keep active sounds alive with strong references so they don't dealloc mid-playback.
    /// Overlapping sounds (e.g., multi-coin for large spend) each get their own slot;
    /// cleaned up after their duration elapses.
    private static var activeSounds = Set<NSSound>()

    // MARK: - Public

    /// Play coin sound(s) scaled to the spend amount.
    /// Larger spend → multiple-coin sound.
    static func play(for spend: Double) {
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
    static func playForDataChange() {
        guard UserDefaults.standard.bool(forKey: "coin_sound_enabled") else { return }
        playBundleSound(named: "coin", ext: "mp3")
    }

    // MARK: - Playback

    private static func playBundleSound(named name: String, ext: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let sound = NSSound(contentsOf: url, byReference: false) {
            activeSounds.insert(sound)
            sound.play()
            // NSSound retains itself during playback, but we keep a reference in
            // activeSounds to prevent premature deallocation. Clean up after the
            // sound's natural duration so the set doesn't grow unboundedly.
            let deadline = DispatchTime.now() + DispatchTimeInterval.milliseconds(Int(sound.duration * 1000) + 50)
            DispatchQueue.main.asyncAfter(deadline: deadline) {
                activeSounds.remove(sound)
            }
            return
        }
        NSSound.beep()
    }
}
