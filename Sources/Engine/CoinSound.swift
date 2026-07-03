import AppKit

/// Plays coin sounds when AI spend is detected.
/// Prefers bundled MP3 files; falls back to synthesized WAV; beep as last resort.
enum CoinSound {

    /// Keep a strong reference so NSSound doesn't dealloc mid-playback.
    private static var currentSound: NSSound?

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
            currentSound = sound
            sound.play()
            return
        }
        NSSound.beep()
    }
}
