import AppKit

/// Plays simple coin-like sounds when AI spend is detected.
/// Uses NSSound (system beep) to avoid AVAudioEngine complexity.
enum CoinSound {
    /// Play a coin sound scaled to the spend amount.
    static func play(for spend: Double) {
        guard UserDefaults.standard.bool(forKey: "coin_sound_enabled") else { return }
        let count: Int
        if spend < 0.10 { count = 1 }
        else if spend < 1.00 { count = 2 }
        else { count = 3 }

        for i in 0..<count {
            let delay = Double(i) * 0.15
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSSound.beep()
            }
        }
    }
}
