import SwiftUI
import AppKit

extension View {
    /// Shows a pointing-hand cursor while the pointer is over the view.
    /// No-op when `enabled` false (keeps the modifier chain simple).
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        onContinuousHover { phase in
            guard enabled else { return }
            switch phase {
            case .active:
                // set() is idempotent — .active fires on every mouse move and
                // push() would leak the cursor stack.
                NSCursor.pointingHand.set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
        .onDisappear {
            // If the view is removed while hovered, .ended never fires and
            // the cursor would stay a pointing hand over whatever appears
            // next; restore the arrow, but only when this modifier actually
            // owned a cursor so it cannot stomp another element's.
            if enabled { NSCursor.arrow.set() }
        }
    }
}
