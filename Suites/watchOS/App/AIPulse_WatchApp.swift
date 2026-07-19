import SwiftUI

import WatchKit

/// watchOS app — three-ring spend rings with today's total in the center.
/// Reads DashboardCache_v1 from iCloud via CloudDataService (Shared module).
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

// MARK: - Spend View

struct SpendView: View {
    @EnvironmentObject var cloudData: CloudDataService

    private var snap: DashboardSnapshot { cloudData.snapshot ?? DashboardSnapshot() }
    private var dailyRate: Double { max(snap.prediction?.dailyRate ?? 20, 0.01) }

    private var todayPct: Double { min(snap.todayCost / dailyRate, 1.0) }
    private var weekPct: Double { min(snap.weekCost / (dailyRate * 7), 1.0) }
    private var monthPct: Double {
        guard let p = snap.prediction, p.monthProjected > 0.001 else { return 0 }
        return min(p.monthSoFar / p.monthProjected, 1.0)
    }

    var body: some View {
        ZStack {
            // Outer ring — 30 days
            Ring(progress: monthPct, thickness: 4, color: .marsGreenLight)

            // Middle ring — Week
            Ring(progress: weekPct, thickness: 5, color: .marsGreen)

            // Inner ring — Today
            Ring(progress: todayPct, thickness: 6, color: .deepRed)

            // Center: today's spend
            VStack(spacing: 2) {
                Text(formatUSD(snap.todayCost))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                if let updated = cloudData.lastUpdated {
                    Text(updated, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
        }
        .contentShape(Circle())
        .onTapGesture { Task { await cloudData.refresh() } }
    }

    private func formatUSD(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        if v >= 100 { f.maximumFractionDigits = 0 }
        return f.string(from: NSNumber(value: v)) ?? "$0"
    }
}

// MARK: - Ring

struct Ring: View {
    let progress: Double  // 0…1
    let thickness: CGFloat
    let color: Color

    var body: some View {
        Circle()
            .trim(from: 0, to: progress)
            .stroke(color, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .animation(.spring(response: 0.6, dampingFraction: 0.7), value: progress)
    }
}

// MARK: - Color extensions

extension Color {
    static let marsGreen = Color(red: 44/255, green: 91/255, blue: 72/255)
    static let marsGreenLight = Color(red: 140/255, green: 196/255, blue: 170/255)
    static let deepRed = Color(red: 173/255, green: 46/255, blue: 35/255)
}
