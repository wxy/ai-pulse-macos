import AVFoundation

/// Plays coin-like sounds when AI spend is detected.
/// Different sounds based on spend amount.
enum CoinSound {
    private static var engine: AVAudioEngine?
    private static var player: AVAudioPlayerNode?

    /// Play a coin sound scaled to the spend amount.
    /// - small (< $0.10): single light coin
    /// - medium ($0.10–$1.00): two coins
    /// - large (> $1.00): three coins (jackpot)
    static func play(for spend: Double) {
        guard UserDefaults.standard.bool(forKey: "coin_sound_enabled") else { return }
        let count: Int
        if spend < 0.10 { count = 1 }
        else if spend < 1.00 { count = 2 }
        else { count = 3 }
        playCoins(count: count)
    }

    private static func playCoins(count: Int) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        CoinSound.engine = engine
        CoinSound.player = player

        do {
            try engine.start()
        } catch { return }

        let sampleRate = 44100.0
        let duration = 0.08
        let frameCount = Int(duration * sampleRate)

        for i in 0..<count {
            let delay = Double(i) * 0.12
            let pitch: Float = [1200, 1600, 2000][min(i, 2)]  // ascending pitches

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                let buffer = generateTone(
                    frequency: pitch, sampleRate: sampleRate, frameCount: frameCount
                )
                guard let buf = buffer else { return }
                player.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
                if !player.isPlaying { player.play() }
            }
        }

        // Clean up after last coin
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Double(count) * 0.12 + 0.3) {
            player.stop()
            engine.stop()
            CoinSound.engine = nil
            CoinSound.player = nil
        }
    }

    private static func generateTone(frequency: Float, sampleRate: Double, frameCount: Int) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        guard let fmt = format, let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let data = buffer.floatChannelData else { return nil }

        for i in 0..<frameCount {
            let t = Float(i) / Float(sampleRate)
            // Exponential decay envelope
            let envelope = exp(-t * 30.0)
            // Sine wave with slight harmonic
            let sample = sin(2.0 * .pi * frequency * t) * 0.6
                       + sin(4.0 * .pi * frequency * t) * 0.2
            data[0][i] = sample * envelope * 0.5
        }
        return buffer
    }
}
