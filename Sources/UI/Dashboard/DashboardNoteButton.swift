import SwiftUI

/// Hover opens immediately; clicking pins the note until ordinary dismissal.
/// The short exit grace period lets the pointer cross into the popover.
struct DashboardNoteInteraction {
    private(set) var isPresented = false
    private(set) var iconHovered = false
    private(set) var contentHovered = false
    private(set) var pinned = false

    mutating func iconHover(_ inside: Bool) {
        iconHovered = inside
        if inside { isPresented = true }
    }

    mutating func contentHover(_ inside: Bool) { contentHovered = inside }

    mutating func click() {
        pinned = true
        isPresented = true
    }

    mutating func dismissIfUnattended() {
        if !iconHovered && !contentHovered && !pinned { isPresented = false }
    }

    mutating func reset() { self = Self() }
}

@MainActor
struct DashboardNoteButton: View {
    let text: String
    let enabled: Bool
    @State private var interaction = DashboardNoteInteraction()
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        Button {
            dismissTask?.cancel()
            interaction.click()
        } label: {
            Image(systemName: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pointingHandCursor(enabled)
        .accessibilityLabel(text)
        .onHover { inside in
            guard enabled else { return }
            interaction.iconHover(inside)
            updateDismissal()
        }
        .popover(isPresented: Binding(
            get: { interaction.isPresented && enabled },
            set: { if !$0 { reset() } }
        ), arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
                .onHover { inside in
                    interaction.contentHover(inside)
                    updateDismissal()
                }
        }
        .onChange(of: enabled) { _, active in if !active { reset() } }
        .onChange(of: text) { _, _ in reset() }
        .onDisappear { reset() }
    }

    private func updateDismissal() {
        dismissTask?.cancel()
        guard !interaction.iconHovered && !interaction.contentHovered && !interaction.pinned else { return }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            interaction.dismissIfUnattended()
        }
    }

    private func reset() {
        dismissTask?.cancel()
        dismissTask = nil
        interaction.reset()
    }
}
