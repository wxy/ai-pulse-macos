import SwiftUI
import AppKit

extension View {
    /// Shows a pointing-hand cursor while the pointer is over the view.
    /// No-op when `enabled` is false (keeps the modifier chain simple).
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        onHover { inside in
            guard enabled else { return }
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
