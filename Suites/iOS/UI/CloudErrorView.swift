import SwiftUI

/// Shown when iCloud is unavailable (network / not signed in / permission denied).
struct CloudErrorView: View {
    let onRetry: () async -> Void
    @State private var retrying = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image("Logo").resizable().frame(width: 80, height: 80).cornerRadius(18)

            Text(I18n.t("welcome.title"))
                .font(.largeTitle).fontWeight(.bold)

            Text(I18n.t("cloud.error.title"))
                .font(.title3).foregroundColor(.secondary)

            Text(I18n.t("cloud.error.body"))
                .multilineTextAlignment(.leading)
                .font(.body).foregroundColor(.secondary)
                .padding(.horizontal, 40)

            Button {
                retrying = true
                Task {
                    await onRetry()
                    retrying = false
                }
            } label: {
                HStack(spacing: 6) {
                    if retrying {
                        ProgressView()
                    }
                    Text(I18n.t("cloud.error.retry"))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(retrying)

            Spacer()
        }
        .padding()
    }
}

#Preview {
    CloudErrorView(onRetry: {})
}
