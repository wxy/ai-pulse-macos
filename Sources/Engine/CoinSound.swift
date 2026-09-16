import AppKit
import AVFoundation
import AIPulseShared

/// Decision output of the pure sound policy (WI-3, unit-tested).
enum SoundDecision: Equatable {
    case none
    case coin        // small consumption
    case coinDouble  // medium
    case coinRain    // ≥ $1 or big burn
    case chime       // startup / closing bell (never from `decide`)
}

/// User-tunable sound settings (WI-4 key table). All keys have safe defaults.
struct SoundSettings: Equatable {
    var enabled: Bool
    var muted: Bool = false       // one-tap app-wide silence
    var volume: Double          // 0...1
    var quietEnabled: Bool
    var quietFromMinutes: Int   // minutes since midnight
    var quietToMinutes: Int
    var maxPerHour: Int
    var pack: String

    static func current(defaults: UserDefaults = .standard) -> SoundSettings {
        // "default" was the pre-P2 pack id; the synthesized default pack is
        // now the "coin" directory — normalize legacy values on read.
        let rawPack = defaults.string(forKey: "sound_pack") ?? "coin"
        let pack = rawPack == "default" ? "coin" : rawPack
        return SoundSettings(
            enabled: defaults.object(forKey: "coin_sound_enabled") as? Bool ?? false,
            muted: AppSoundControl.isMuted(defaults: defaults),
            volume: Double(defaults.object(forKey: "sound_volume") as? Int ?? 50) / 100.0,
            quietEnabled: defaults.object(forKey: "sound_quiet_enabled") as? Bool ?? true,
            quietFromMinutes: parseHM(defaults.string(forKey: "sound_quiet_from") ?? "22:00") ?? 22 * 60,
            quietToMinutes: parseHM(defaults.string(forKey: "sound_quiet_to") ?? "08:00") ?? 8 * 60,
            maxPerHour: defaults.object(forKey: "sound_max_per_hour") as? Int ?? 8,
            pack: pack)
    }

    /// "HH:mm" → minutes since midnight; nil when malformed.
    static func parseHM(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }
}

/// One switch for every sound emitted by AI Pulse. Notifications still arrive;
/// only their sound transport is removed. Individual sound preferences are
/// preserved so unmuting restores the user's previous setup.
enum AppSoundControl {
    static let mutedKey = "sound_muted"

    static func isMuted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: mutedKey)
    }

    static func setMuted(_ muted: Bool, defaults: UserDefaults = .standard) {
        defaults.set(muted, forKey: mutedKey)
        NotificationCenter.default.post(name: .soundMuteDidChange, object: nil)
    }

    @discardableResult
    static func toggle(defaults: UserDefaults = .standard) -> Bool {
        let next = !isMuted(defaults: defaults)
        setMuted(next, defaults: defaults)
        return next
    }
}

/// Plays coin sounds when AI consumption is detected — the product's heartbeat
/// (v2 §3.2 从"数据音效"到"金钱心跳").
///
/// 防烦三原则 (hard constraints):
/// 1. Absolute cap: ≤ `maxPerHour` plays per rolling hour (default 8).
/// 2. Quiet hours: default 22:00–08:00, cross-midnight aware; screen sleep is
///    already handled upstream (DataRefreshCoordinator suspends timers).
/// 3. Independent volume: AVAudioPlayer (NSSound has no volume), default 50%.
enum CoinSound {

    private enum DecisionReason: String {
        case played
        case disabled
        case noEvents = "no_events"
        case quietHours = "quiet_hours"
        case hourlyCap = "hourly_cap"
        case coalesced
    }

    private struct DecisionOutcome {
        let decision: SoundDecision
        let state: DecisionState
        let reason: DecisionReason
    }

    // MARK: - Pure decision core (CoinSoundDecisionTests)

    struct DecisionState: Equatable {
        var lastPlay: Date?
        var recentPlays: [Date] = []
        var lastTier: PulseTier = .resting
    }

    /// Merge window scales with burn tier — burning faster → denser heartbeat.
    static let coalesceNormal: TimeInterval = 90
    static let coalesceHot: TimeInterval = 45
    static let coalesceBlaze: TimeInterval = 30
    static let capWindow: TimeInterval = 3600

    /// Cross-midnight-aware quiet-hours check. `from == to` means "off".
    static func isQuietTime(_ date: Date, settings: SoundSettings,
                            calendar: Calendar = .current) -> Bool {
        guard settings.quietEnabled else { return false }
        let mins = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let from = settings.quietFromMinutes, to = settings.quietToMinutes
        if from == to { return false }
        if from < to { return mins >= from && mins < to }
        return mins >= from || mins < to
    }

    /// Pure policy: a newly observed activity occurrence plus the current pulse
    /// tier determines sound density. Money/token amounts never grade sound.
    /// Quiet, capped, and coalesced events are discarded instead of replayed.
    static func decide(events: [ConsumptionEvent], pulse: PulseSnapshot?,
                       settings: SoundSettings, state: DecisionState,
                       now: Date = Date(), calendar: Calendar = .current)
        -> (decision: SoundDecision, state: DecisionState) {
        let outcome = evaluate(
            events: events, pulse: pulse, settings: settings, state: state,
            now: now, calendar: calendar)
        return (outcome.decision, outcome.state)
    }

    private static func evaluate(events: [ConsumptionEvent], pulse: PulseSnapshot?,
                                 settings: SoundSettings, state: DecisionState,
                                 now: Date, calendar: Calendar) -> DecisionOutcome {
        var state = state
        guard settings.enabled, !settings.muted else {
            return DecisionOutcome(decision: .none, state: state, reason: .disabled)
        }
        guard !events.isEmpty else {
            return DecisionOutcome(decision: .none, state: state, reason: .noEvents)
        }

        let tier = pulse?.tier ?? .active
        let escalated = tier.rank > state.lastTier.rank
        state.lastTier = tier

        guard !isQuietTime(now, settings: settings, calendar: calendar) else {
            return DecisionOutcome(decision: .none, state: state, reason: .quietHours)
        }

        // Absolute hourly cap (原则 1).
        state.recentPlays = state.recentPlays.filter { now.timeIntervalSince($0) < capWindow }
        guard state.recentPlays.count < settings.maxPerHour else {
            return DecisionOutcome(decision: .none, state: state, reason: .hourlyCap)
        }

        // Merge window (原则 2 的密度面): burning faster → shorter window.
        let window: TimeInterval
        switch tier {
        case .intense: window = coalesceBlaze
        case .elevated: window = coalesceHot
        default: window = coalesceNormal
        }
        // A genuine tier escalation is itself meaningful feedback and may
        // break through the normal merge window. Downgrades never make sound.
        if !escalated, let last = state.lastPlay, now.timeIntervalSince(last) < window {
            return DecisionOutcome(decision: .none, state: state, reason: .coalesced)
        }

        state.lastPlay = now
        state.recentPlays.append(now)

        switch tier {
        case .resting, .active:
            return DecisionOutcome(decision: .coin, state: state, reason: .played)
        case .elevated:
            return DecisionOutcome(decision: .coinDouble, state: state, reason: .played)
        case .intense:
            return DecisionOutcome(decision: .coinRain, state: state, reason: .played)
        }
    }

    // MARK: - Runtime state + playback (MainActor)

    @MainActor private static var state = DecisionState()
    @MainActor private static var activePlayers: [AVAudioPlayer] = []

    /// Entry point from the consumption-event bus (DataRefreshCoordinator).
    @MainActor static func play(events: [ConsumptionEvent], pulse: PulseSnapshot?) {
        let settings = SoundSettings.current()
        let outcome = evaluate(
            events: events, pulse: pulse, settings: settings, state: state,
            now: Date(), calendar: .current)
        state = outcome.state
        Logger.debug(
            "CoinSound decision: events=\(events.count) tier=\(pulse?.tier.rawValue ?? "active") " +
            "decision=\(String(describing: outcome.decision)) reason=\(outcome.reason.rawValue) " +
            "plays_in_hour=\(state.recentPlays.count)/\(settings.maxPerHour)")
        guard outcome.decision != .none else { return }
        playDecision(outcome.decision, settings: settings)
    }

    static func permitsPlayback(_ decision: SoundDecision, settings: SoundSettings) -> Bool {
        !settings.muted && (settings.enabled || decision == .chime)
    }

    @MainActor static func playDecision(_ decision: SoundDecision, settings: SoundSettings) {
        guard permitsPlayback(decision, settings: settings) else {
            Logger.debug("CoinSound playback skipped: sound disabled")
            return
        }
        switch decision {
        case .none:
            break
        case .coin:
            playFile(named: "coin", volume: settings.volume, pack: settings.pack)
        case .coinDouble:
            playFile(named: "coin", volume: settings.volume, pack: settings.pack)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                playFile(named: "coin", volume: settings.volume, pack: settings.pack)
            }
        case .coinRain:
            playFile(named: "coins", volume: settings.volume, pack: settings.pack)
        case .chime:
            playFile(named: "chime", volume: settings.volume, pack: settings.pack)
        }
    }

    /// Startup feedback — default OFF (启动 ≠ 花钱; v2 removed the unconditional
    /// startup chime that bypassed every throttle).
    @MainActor static func playStartupChimeIfEnabled(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: "startup_chime_enabled") as? Bool == true else { return }
        let settings = SoundSettings.current(defaults: defaults)
        guard !isQuietTime(Date(), settings: settings) else { return }
        playDecision(.chime, settings: settings)
    }

    // MARK: - File resolution & playback

    @MainActor private static func playFile(named name: String, volume: Double, pack: String) {
        guard let url = soundURL(named: name, pack: pack) else {
            Logger.debug("CoinSound: '\(name)' missing in pack '\(pack)', falling back to beep")
            NSSound.beep()
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = Float(min(max(volume, 0), 1))
            player.prepareToPlay()
            guard player.play() else {
                Logger.debug("CoinSound: AVAudioPlayer declined playback for \(url.lastPathComponent)")
                NSSound.beep()
                return
            }
            activePlayers.append(player)
            Logger.debug("CoinSound playback started: \(url.lastPathComponent) volume=\(String(format: "%.2f", player.volume))")
            let duration = player.duration
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
                activePlayers.removeAll { $0 === player }
            }
        } catch {
            Logger.debug("CoinSound: AVAudioPlayer failed for \(url.lastPathComponent): \(error)")
            NSSound.beep()
        }
    }

    /// Resolution order per extension: selected pack subdirectory → coin pack
    /// fallback → the project owner's flat MP3 cues → caller beep. The coin
    /// pack intentionally has no coin/coins WAV so those two original MP3s win.
    @MainActor static func soundURL(named name: String, pack: String) -> URL? {
        let packDir = "Sounds/\(pack)"
        let dirs: [String?] = pack == "coin"
            ? ["Sounds/coin", nil]
            : [packDir, "Sounds/coin", nil]
        for dir in dirs {
            for ext in ["mp3", "wav"] {
                if let url = Bundle.main.url(forResource: name, withExtension: ext,
                                             subdirectory: dir) {
                    return url
                }
            }
        }
        return nil
    }
}

extension Notification.Name {
    static let soundMuteDidChange = Notification.Name("AIPulseSoundMuteDidChange")
}
