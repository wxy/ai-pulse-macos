import AppKit
import AIPulseShared

/// Shared state and palette, not a budget-progress gauge. Menu uses a flame;
/// Dock keeps the robot and lights a fixed status lamp only for meaningful activity.
struct PulseAppearance {
    let tier: PulseTier?
    var cooling = false
    static let symbolName = "flame.fill"
    var hasActivity: Bool { tier != nil && tier != .resting }

    var color: NSColor {
        switch tier {
        case .active: return NSColor(calibratedRed: 0.74, green: 0.48, blue: 0.06, alpha: 1)
        case .elevated: return .systemOrange
        case .intense: return .systemRed
        case .resting, .none: return .systemGray
        }
    }

    var label: String {
        cooling && tier != nil && tier != .resting
            ? I18n.t("pulse.activity.cooling")
            : I18n.t("pulse.tier.\(tier?.rawValue ?? "unknown")")
    }
    // A new balance observation can flash without manufacturing a token tier.
    func feedbackColor(beat: Bool) -> NSColor {
        beat && !hasActivity ? PulseAppearance(tier: .active).color : color
    }

    func showsLamp(beat: Bool) -> Bool { hasActivity || beat }

    func image(size: CGFloat = 18, beat: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let symbol = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: self.label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size - 3, weight: .medium)) else { return false }
            // Preserve proportions and size on every state/beat; tint only the glyph.
            let factor = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
            let width = symbol.size.width * factor
            let height = symbol.size.height * factor
            let target = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
            symbol.draw(in: target)
            self.feedbackColor(beat: beat).withAlphaComponent(beat ? 1 : 0.8).setFill()
            target.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = label
        return image
    }
}
