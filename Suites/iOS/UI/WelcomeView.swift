import SwiftUI

/// Shown when iCloud has no data — guides user to install the macOS app.
struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "chart.bar.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("AI Pulse")
                .font(.largeTitle).fontWeight(.bold)

            Text("AI 花费追踪仪表盘")
                .font(.title3).foregroundColor(.secondary)

            Text("数据由 macOS 版 AI Pulse 采集并同步到你的 iCloud。请先在 Mac 上安装 AI Pulse 以开始追踪。")
                .multilineTextAlignment(.center)
                .font(.body).foregroundColor(.secondary)
                .padding(.horizontal, 40)

            if let url = URL(string: "macappstore://apps.apple.com/app/id1234567890") {
                Link("在 App Store 获取 macOS 版", destination: url)
                    .font(.headline)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .padding()
    }
}

#Preview {
    WelcomeView()
}
