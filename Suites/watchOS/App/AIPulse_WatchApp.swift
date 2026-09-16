import SwiftUI
import WatchKit
import AIPulseShared

@main
struct AIPulse_WatchApp: App {
    @StateObject private var cloudData = CloudDataService.shared

    var body: some Scene {
        WindowGroup {
            SpendView()
                .environmentObject(cloudData)
                .task { await cloudData.refresh() }
                .onReceive(NotificationCenter.default.publisher(for: WKApplication.didBecomeActiveNotification)) { _ in
                    Task { await cloudData.refresh() }
                }
        }
    }
}

struct SpendView: View {
    @EnvironmentObject var cloudData: CloudDataService
    @State private var refreshTrigger = 0
    /// v2 P2: last seen today cost — a rise while the app is front fires the
    /// coin haptic (the watch-side heartbeat).
    @State private var lastSeenTodayCost: Double = 0

    private var snap: DashboardSnapshot { cloudData.snapshot ?? DashboardSnapshot() }
    private var dailyRate: Double { max(snap.prediction?.dailyRate ?? 20, 0.01) }
    private var weeklyAvg: Double { dailyRate * 7 }
    private var todayPct: Double { ChartMath.ratio(snap.todayCost, denominator: dailyRate, fallback: 0) }
    private var todayLaps: Int { ChartMath.safeInt(todayPct) }
    private var weekPct: Double { ChartMath.ratio(snap.weekCost, denominator: weeklyAvg, fallback: 0) }
    private var monthPct: Double {
        guard let p = snap.prediction, p.monthProjected > 0.001 else { return 0 }
        return ChartMath.unit(p.monthSoFar / p.monthProjected)
    }
    private var yesterdayDelta: Double {
        ChartMath.percentageDelta(current: snap.todayCost, previous: snap.yesterdaySpend, fallback: 0)
    }
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    private var payloadVersion: String { CKSchema.payloadVersion }

    var body: some View {
        NavigationStack {
            ZStack {
                // Center: rings + today cost + last-updated time.
                ZStack {
                    ActivityRing(progress: monthPct, thickness: 5, color: .marsGreenLight)
                        .frame(width: 160, height: 160)
                    ActivityRing(progress: weekPct.truncatingRemainder(dividingBy: 1), thickness: 5, color: .marsGreen)
                        .frame(width: 144, height: 144)
                    ActivityRing(progress: todayPct.truncatingRemainder(dividingBy: 1), thickness: 5, color: .deepRed)
                        .frame(width: 128, height: 128)
                    VStack(spacing: 1) {
                        Text("\(todayLaps)×")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                        Text(formatUSD(snap.todayCost))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.5).lineLimit(1)
                        burnLabel
                        if let updated = cloudData.lastUpdated {
                            Text(updated, format: .dateTime.hour().minute())
                                .font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: 12)
            }
            // Anchor labels to the real screen corners (the watch display is a
            // taller rectangle, not a square) and put the version line at the
            // very bottom, below the bottom-corner labels.
            .overlay(alignment: .topLeading) { todayLabel.padding(.leading, 10).padding(.top, 14) }
            .overlay(alignment: .topTrailing) { weekLabel.padding(.trailing, 10).padding(.top, 14) }
            .overlay(alignment: .bottomLeading) { deltaLabel.padding(.leading, 10).padding(.bottom, 14) }
            .overlay(alignment: .bottomTrailing) { monthLabel.padding(.trailing, 10).padding(.bottom, 14) }
            .overlay(alignment: .bottom) { versionLabel.padding(.bottom, 2) }
            .ignoresSafeArea(.all)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Spacer().frame(width: 0) }
                ToolbarItem(placement: .topBarTrailing) { Spacer().frame(width: 0) }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            WKInterfaceDevice.current().play(.click)
            refreshTrigger += 1
            Task {
                await cloudData.refresh()
                celebrateIfSpent()
            }
        }
        .task {
            await cloudData.refresh()
            celebrateIfSpent()
        }
        .onReceive(NotificationCenter.default.publisher(for: WKApplication.didBecomeActiveNotification)) { _ in
            Task {
                await cloudData.refresh()
                celebrateIfSpent()
            }
        }
    }

    /// v2 P2: coin haptic when today's spend rose since the last look — the
    /// watch feels the heartbeat without lifting the Mac lid.
    private func celebrateIfSpent() {
        let cost = cloudData.snapshot?.todayCost ?? 0
        if cost - lastSeenTodayCost > 0.005 {
            WKInterfaceDevice.current().play(.notification)
        }
        lastSeenTodayCost = cost
    }

    /// Denomination fallback mirrors the Mac (§3.1): money → tokens → lines.
    @ViewBuilder
    private var burnLabel: some View {
        let color: Color = {
            switch snap.pulse?.tier {
            case .intense: return Color.red
            case .elevated: return Color.orange
            case .active: return Color.yellow
            default: return Color.secondary
            }
        }()
        Group {
            if let pulse = snap.pulse,
               let kind = pulse.primarySignal,
               let signal = pulse.signals.first(where: { $0.kind == kind }),
               let value = signal.rawValue, value > 0 {
                switch kind {
                case .observedSpend:
                    Text(verbatim: "🔥 \(String(format: "%.2f", value)) \(signal.unit)")
                case .activity:
                    Text(verbatim: "🔥 \(ChartMath.compactCount(Int64(value))) \(I18n.t("dashboard.tokens"))/h")
                case .attributedOutput:
                    Text(verbatim: "🔥 \(ChartMath.compactCount(Int64(value))) lines/h")
                case .quota:
                    Text(verbatim: "🔥 \(Int(value.rounded()))%")
                }
            } else {
                EmptyView()
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundColor(color)
    }

    private var todayLabel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(I18n.t("time.today")).font(.system(size: 10)).foregroundColor(.secondary)
            Text(formatUSD(snap.todayCost)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.deepRed)
        }
    }

    private var weekLabel: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(I18n.t("time.week")).font(.system(size: 10)).foregroundColor(.secondary)
            Text(formatUSD(snap.weekCost)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.marsGreen)
        }
    }

    @ViewBuilder
    private var deltaLabel: some View {
        if snap.yesterdaySpend > 0.001 {
            let badge = yesterdayDelta > 0
                ? "↑" + ChartMath.safeInt(yesterdayDelta * 100).formatted(.percent)
                : "↓" + ChartMath.safeInt(-yesterdayDelta * 100).formatted(.percent)
            Text(verbatim: badge)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(yesterdayDelta > 0 ? .deepRed : .marsGreen)
        }
    }

    private var monthLabel: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(I18n.t("time.30d")).font(.system(size: 10)).foregroundColor(.secondary)
            Text(formatUSD(snap.monthCost)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.marsGreenLight)
        }
    }

    private var versionLabel: some View {
        Text(verbatim: "v\(appVersion) CloudKit \(payloadVersion)")
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundColor(.secondary.opacity(0.7))
            .lineLimit(1)
    }

    private static let usdFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US"); return f
    }()
    private func formatUSD(_ v: Double) -> String {
        if v >= 100 { Self.usdFormatter.maximumFractionDigits = 0 }
        else { Self.usdFormatter.maximumFractionDigits = 2 }
        return Self.usdFormatter.string(from: NSNumber(value: v)) ?? "$0"
    }
}

// ActivityRing + Color extensions now in Suites/Shared/Views/ActivityRing.swift
