import AIPulseShared
import Foundation
import WidgetKit

enum MacWidgetLocalPublisher {
    /// `nil` snapshots mean "this read pass was degraded" — the caller passes
    /// nil instead of distributing partially failed data. Degraded ranges
    /// keep the previous healthy payload, mirroring how the pulse preserves
    /// its last truthful observation below.
    static func publish(todaySnapshot: DashboardSnapshot?, historySnapshot: DashboardSnapshot?,
                        at now: Date = Date()) async -> Bool {
        async let pulse = PulseEngine.shared.snapshot(now: now)

        let previous = try? MacWidgetLocalStore.load()
        let resolvedToday = todaySnapshot ?? previous?.todaySnapshot
        let resolvedHistory = historySnapshot ?? previous?.historySnapshot
        guard let resolvedToday, let resolvedHistory else {
            Logger.info("MacWidget: no healthy snapshot pair available; keeping previous payload")
            return false
        }
        let resolvedPulse = await pulse
        let pulseEnvelope: CurrentPulseEnvelope?
        if let resolvedPulse {
            pulseEnvelope = CurrentPulseEnvelope.forCloudSync(
                pulse: resolvedPulse,
                writerAppVersion: CKSchema.writerAppVersion,
                generatedAt: now
            )
        } else {
            // Preserve the last truthful observation. Its own validity window
            // will expire naturally while the containing app is not producing
            // new observations.
            pulseEnvelope = previous?.pulseEnvelope
        }

        let payload = MacWidgetLocalPayload(
            writtenAt: now,
            todaySnapshot: resolvedToday,
            historySnapshot: resolvedHistory,
            pulseEnvelope: pulseEnvelope
        )
        do {
            try MacWidgetLocalStore.write(payload)
            WidgetCenter.shared.reloadTimelines(ofKind: "AIPulseMacWidget")
            Logger.debug("MacWidget: published local snapshot")
            return true
        } catch {
            Logger.error("MacWidget: local snapshot write failed: \(error.localizedDescription)")
            return false
        }
    }
}
