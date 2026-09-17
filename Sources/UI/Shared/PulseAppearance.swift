import AppKit
import AIPulseShared

/// One visual vocabulary for the menu bar, dashboard and Dock. Segments are
/// distributed around the entire perimeter: this is intensity, not progress.
struct PulseAppearance {
    let tier: PulseTier?
    var cooling = false
    static let segmentCount = 12

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
    var litSegments: Int { (tier?.rank ?? 0) * 4 }

    func isLit(_ index: Int) -> Bool {
        guard (0..<Self.segmentCount).contains(index) else { return false }
        return index % 3 < (tier?.rank ?? 0)
    }

    func opacity(at index: Int, beat: Bool = false) -> CGFloat {
        if beat { return 1 }
        if tier == nil { return index.isMultiple(of: 2) ? 0.35 : 0.10 }
        if tier == .resting { return 0.55 }
        return isLit(index) ? 0.80 : 0.18
    }

    func image(size: CGFloat = 18, beat: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let radius = rect.width * 0.38
            for index in 0..<Self.segmentCount {
                let path = NSBezierPath()
                let start = CGFloat(90 - index * 30 - 5)
                path.appendArc(withCenter: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                               startAngle: start, endAngle: start - 20, clockwise: true)
                self.color.withAlphaComponent(self.opacity(at: index, beat: beat)).setStroke()
                path.lineWidth = max(1.5, size * (beat ? 0.14 : 0.10))
                path.lineCapStyle = .round
                path.stroke()
            }
            if self.tier == nil {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size * 0.55, weight: .semibold),
                    .foregroundColor: NSColor.labelColor
                ]
                let text = "?" as NSString
                let bounds = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: rect.midX - bounds.width / 2,
                                      y: rect.midY - bounds.height / 2), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = label
        return image
    }
}
