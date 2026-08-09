import SwiftUI

/// Full-window overlay exploring one tool's sessions. Covers the whole
/// dashboard window, so its internal scrolling never conflicts with the
/// dashboard's scroll area. Session list + inline context charts are added
/// in a later task; this shell establishes the header/close contract.
struct ToolDetailOverlayView: View {
    let toolId: String
    let sinceMs: Int64
    let onClose: () -> Void

    var body: some View {
        ZStack {
            // Absorbs clicks so the covered dashboard is not interactive.
            Color.black.opacity(0.001)
            VStack(spacing: 0) {
                HStack {
                    Text(toolId == "codex" ? "ChatGPT" : "Claude Code")
                        .font(.headline)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                .padding(12)
                Divider()
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .onExitCommand(perform: onClose)
    }
}
