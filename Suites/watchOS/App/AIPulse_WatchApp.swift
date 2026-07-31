import SwiftUI
import WatchKit

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

    private var snap: DashboardSnapshot { cloudData.snapshot ?? DashboardSnapshot() }
    private var dailyRate: Double { max(snap.prediction?.dailyRate ?? 20, 0.01) }
    private var weeklyAvg: Double { dailyRate * 7 }
    private var todayPct: Double { snap.todayCost / dailyRate }
    private var todayLaps: Int { Int(todayPct) }
    private var weekPct: Double { snap.weekCost / weeklyAvg }
    private var monthPct: Double {
        guard let p = snap.prediction, p.monthProjected > 0.001 else { return 0 }
        return min(p.monthSoFar / p.monthProjected, 1.0)
    }
    private var yesterdayDelta: Double {
        snap.yesterdaySpend > 0.001 ? (snap.todayCost - snap.yesterdaySpend) / snap.yesterdaySpend : 0
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
            ZStack {
                // Anchor frame with corner labels (overlays BEFORE position)
                Rectangle().fill(.clear).frame(width: 168, height: 168)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(I18n.t("time.today")).font(.system(size: 10)).foregroundColor(.secondary)
                            Text(formatUSD(snap.todayCost)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.deepRed)
                        }.offset(x: -8, y: -8)
                    }
                    .overlay(alignment: .topTrailing) {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(I18n.t("time.week")).font(.system(size: 10)).foregroundColor(.secondary)
                            Text(formatUSD(snap.weekCost)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.marsGreen)
                        }.offset(x: 8, y: -8)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if snap.yesterdaySpend > 0.001 {
                            let badge = yesterdayDelta > 0 ? "↑" + Int(yesterdayDelta * 100).formatted(.percent) : "↓" + Int(-yesterdayDelta * 100).formatted(.percent)
                            Text(verbatim: badge)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(yesterdayDelta > 0 ? .deepRed : .marsGreen).offset(x: -8, y: 8)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(I18n.t("time.30d")).font(.system(size: 10)).foregroundColor(.secondary)
                            Text(formatUSD(snap.monthCost)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.marsGreenLight)
                        }.offset(x: 8, y: 8)
                    }
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                // Rings + center, positioned at geometry center
                ZStack {
                    ActivityRing(progress: monthPct, thickness: 5, color: .marsGreenLight).frame(width: 160, height: 160)
                    ActivityRing(progress: weekPct.truncatingRemainder(dividingBy: 1), thickness: 5, color: .marsGreen).frame(width: 144, height: 144)
                    ActivityRing(progress: todayPct.truncatingRemainder(dividingBy: 1), thickness: 5, color: .deepRed).frame(width: 128, height: 128)
                    VStack(spacing: 1) {
                        Text("\(todayLaps)×")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                        Text(formatUSD(snap.todayCost)).font(.system(size: 32, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                        if let updated = cloudData.lastUpdated { Text(updated, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundColor(.secondary) }
                    }
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            }
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
            Task { await cloudData.refresh() }
        }
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
