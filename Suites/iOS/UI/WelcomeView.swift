import SwiftUI

/// Shown when iCloud has no data — guides user to install the macOS app.
struct WelcomeView: View {
    var retry: (() async -> Void)? = nil
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image("Logo").resizable().frame(width: 80, height: 80).cornerRadius(18)

            Text(I18n.t("welcome.title"))
                .font(.title2).fontWeight(.bold)

            Text(PhoneText.t("你的 AI 活动，随时可见", "Your AI activity, at a glance"))
                .font(.title3).foregroundColor(.secondary)

            Text(PhoneText.t("请先在 Mac 2.0 上授权日志目录并开启 iCloud 同步。iPhone 使用同一 Apple 账户，即可查看同步摘要；开发目录、套餐和 API Key 在 Mac 上配置。", "Authorize log access and enable iCloud sync on Mac 2.0 first. Use the same Apple account on iPhone to view summaries. Configure directories, plans and API keys on your Mac."))
                .multilineTextAlignment(.center)
                .font(.body).foregroundColor(.secondary)
                .padding(.horizontal, 40)

            Button(PhoneText.t("检查同步", "Check sync")) { Task { await retry?() } }.buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }
}

#Preview {
    WelcomeView()
}
