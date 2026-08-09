import SwiftUI
import AppKit

extension View {
    /// Shows a pointing-hand cursor while the pointer is over the view.
    /// No-op when `enabled` is false (keeps the modifier chain simple).
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        onContinuousHover { phase in
            guard enabled else { return }
            switch phase {
            case .active:
                NSCursor.pointingHand.push()
            case .ended:
                NSCursor.pop()
            }
        }
    }
}
