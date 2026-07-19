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
            Color.clear
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Spacer().frame(width: 0) }
                    ToolbarItem(placement: .topBarTrailing) { Spacer().frame(width: 0) }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        .ignoresSafeArea(.all)
        .overlay {
            GeometryReader { geo in
            let cx = geo.size.width / 2
            let cy = geo.size.height / 2
            ZStack {
                // Anchor frame + corner labels
                Rectangle().fill(.clear).frame(width: 170, height: 170)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(I18n.t("time.today")).font(.system(size: 10)).foregroundColor(.secondary)
                            if todayLaps > 0 { Text("\(todayLaps)×").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.deepRed) }
                        }.offset(x: -5, y: -5)
                    }
                    .overlay(alignment: .topTrailing) {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(I18n.t("time.week")).font(.system(size: 10)).foregroundColor(.secondary)
                            Text(formatUSD(snap.weekCost)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.marsGreen)
                        }.offset(x: 5, y: -5)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if snap.yesterdaySpend > 0.001 {
                            Text(yesterdayDelta > 0 ? "↑\(Int(yesterdayDelta * 100))%" : "↓\(Int(-yesterdayDelta * 100))%")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(yesterdayDelta > 0 ? .deepRed : .marsGreen).offset(x: -5, y: 5)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(I18n.t("time.30d")).font(.system(size: 10)).foregroundColor(.secondary)
                            Text(formatUSD(snap.monthCost)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.marsGreenLight)
                        }.offset(x: 5, y: 5)
                    }

                // Rings
                ActivityRing(progress: monthPct, thickness: 5, color: .marsGreenLight).frame(width: 160, height: 160)
                ActivityRing(progress: weekPct.truncatingRemainder(dividingBy: 1), thickness: 5, color: .marsGreen).frame(width: 144, height: 144)
                ActivityRing(progress: todayPct.truncatingRemainder(dividingBy: 1), thickness: 5, color: .deepRed).frame(width: 128, height: 128)

                // Center text
                VStack(spacing: 1) {
                    Text(formatUSD(snap.todayCost)).font(.system(size: 32, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                    if let updated = cloudData.lastUpdated {
                        Text(updated, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
            }
            .position(x: cx, y: cy)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await cloudData.refresh() } }
    }

    private func formatUSD(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        if v >= 100 { f.maximumFractionDigits = 0 }
        return f.string(from: NSNumber(value: v)) ?? "$0"
    }
}

struct ActivityRing: View {
    let progress: Double; let thickness: CGFloat; let color: Color
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.20), style: StrokeStyle(lineWidth: thickness, lineCap: .round))
            Circle().trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
                .rotationEffect(.degrees(-90)).animation(.easeInOut(duration: 0.6), value: progress)
        }
    }
}

extension Color {
    static let marsGreen = Color(red: 44/255, green: 91/255, blue: 72/255)
    static let marsGreenLight = Color(red: 140/255, green: 196/255, blue: 170/255)
    static let deepRed = Color(red: 173/255, green: 46/255, blue: 35/255)
}
