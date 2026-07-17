import SwiftUI

/// Shown when iCloud has no data — guides user to install the macOS app.
struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image("AIPulse")
                .resizable()
                .frame(width: 80, height: 80)
                .cornerRadius(18)

            Text(I18n.t("welcome.title"))
                .font(.largeTitle).fontWeight(.bold)

            Text(I18n.t("welcome.subtitle"))
                .font(.title3).foregroundColor(.secondary)

            Text(I18n.t("welcome.body"))
                .multilineTextAlignment(.center)
                .font(.body).foregroundColor(.secondary)
                .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
    }
}

#Preview {
    WelcomeView()
}
