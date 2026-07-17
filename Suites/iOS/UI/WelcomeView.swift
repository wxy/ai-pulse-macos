import SwiftUI

/// Shown when iCloud has no data — guides user to install the macOS app.
struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "chart.bar.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text(I18n.t("welcome.title"))
                .font(.largeTitle).fontWeight(.bold)

            Text(I18n.t("welcome.subtitle"))
                .font(.title3).foregroundColor(.secondary)

            Text(I18n.t("welcome.body"))
                .multilineTextAlignment(.center)
                .font(.body).foregroundColor(.secondary)
                .padding(.horizontal, 40)

            if let url = URL(string: "macappstore://apps.apple.com/app/id1234567890") {
                Link(I18n.t("welcome.appstore"), destination: url)
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
