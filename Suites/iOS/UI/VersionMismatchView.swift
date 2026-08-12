import SwiftUI

/// Shown when the iCloud record's payload version does not match this
/// client's expected version — distinct from "no data" and from iCloud being
/// unavailable. Tells the user which side to upgrade.
struct VersionMismatchView: View {
    let macosTooOld: Bool
    let recordVersion: String?

    private var appStoreURL: URL {
        URL(string: "https://apps.apple.com/us/app/ai-pulse-coding-cost-tracker/id6786290416?mt=8")!
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image("Logo").resizable().frame(width: 80, height: 80).cornerRadius(18)

            Text(I18n.t("welcome.title"))
                .font(.title2).fontWeight(.bold)

            Text(I18n.t("version.mismatch.title"))
                .font(.title3).foregroundColor(.secondary)

            Text(macosTooOld
                 ? I18n.t("version.mismatch.body.macos")
                 : I18n.t("version.mismatch.body.ios"))
                .multilineTextAlignment(.center)
                .font(.body).foregroundColor(.secondary)
                .padding(.horizontal, 40)

            Text(String(format: I18n.t("version.mismatch.supported"), CKSchema.payloadVersion))
                .font(.caption).foregroundColor(.secondary)
            if let recordVersion, !recordVersion.isEmpty {
                Text(String(format: I18n.t("version.mismatch.payload"), recordVersion))
                    .font(.caption).foregroundColor(.secondary)
            }

            Link(destination: appStoreURL) {
                Text(I18n.t("version.mismatch.appstore"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
    }
}

#Preview {
    VersionMismatchView(macosTooOld: true, recordVersion: nil)
}
