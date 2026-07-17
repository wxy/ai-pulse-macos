import SwiftUI

/// Shown when iCloud has no data — guides user to install the macOS app.
struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.white)
                RoundedRectangle(cornerRadius: 18).stroke(Color.marsGreen.opacity(0.3), lineWidth: 2)
                Text("AI").font(.system(size: 28, weight: .bold)).foregroundStyle(Color.marsGreen)
            }.frame(width: 80, height: 80)

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
