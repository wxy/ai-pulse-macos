import SwiftUI

/// One accepted code contributor, shown in the in-app Acknowledgments.
struct Contributor: Identifiable {
    let id = UUID()
    let name: String
    /// GitHub username, if the contributor has one.
    let github: String?
}

/// Accepted code contributors, oldest first.
///
/// Add a new entry here whenever a contributor's PR is merged — see
/// CONTRIBUTING.md. Names stay in this list permanently as a thank-you.
enum Acknowledgments {
    static let contributors: [Contributor] = []
}

/// In-app page crediting everyone who contributed code to AI Pulse.
struct AcknowledgmentsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text(I18n.t("about.acknowledgments"))
                .font(.title2).fontWeight(.bold)

            if Acknowledgments.contributors.isEmpty {
                Text(I18n.t("about.acknowledgments_empty"))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            } else {
                List(Acknowledgments.contributors) { c in
                    HStack {
                        Text(c.name)
                        if let g = c.github {
                            Text("@\(g)").foregroundColor(.secondary)
                        }
                    }
                }
                .frame(minHeight: 120)
            }

            Spacer()

            Text(I18n.t("about.acknowledgments_note"))
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(width: 340, height: 280)
    }
}
