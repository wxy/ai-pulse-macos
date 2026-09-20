import AIPulseShared
import Foundation
import WidgetKit

enum MacWidgetLocalPublisher {
    static func publish(at now: Date = Date()) async -> Bool {
        async let today = snapshot(for: .today, cacheMaxAge: 10 * 60)
        async let history = snapshot(for: .days30, cacheMaxAge: 12 * 60 * 60)
        async let pulse = PulseEngine.shared.snapshot(now: now)

        let previous = try? MacWidgetLocalStore.load()
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
            todaySnapshot: await today,
            historySnapshot: await history,
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

    private static func snapshot(
        for period: DashboardPeriodKind,
        cacheMaxAge: TimeInterval
    ) async -> DashboardSnapshot {
        if let cached = await DashboardCache.read(
            timeRange: period.rawValue,
            maxAge: cacheMaxAge
        ) {
            return cached
        }
        return await StatsService.dashboardSnapshot(period: period)
    }
}
