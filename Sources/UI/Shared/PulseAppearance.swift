import AppKit
import AIPulseShared

/// Shared state and palette, not a budget-progress gauge. Menu uses a monochrome robot;
/// Dock keeps the robot and lights a fixed status lamp only for meaningful activity.
struct PulseAppearance {
    let tier: PulseTier?
    var cooling = false
    var hasActivity: Bool { tier != nil && tier != .resting }

    var color: NSColor {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch tier {
        case .active: rgb = (0.26, 0.52, 0.40)
        case .elevated, .intense: rgb = (0.72, 0.32, 0.27)
        case .resting, .none: return .secondaryLabelColor
        }
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
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
            // Draw in an 18-point grid; facial cutouts remain transparent at menu-bar scale.
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.scaleX(by: rect.width / 18, yBy: rect.height / 18)
            transform.concat()
            self.feedbackColor(beat: beat).setFill()
            let shell = NSBezierPath(roundedRect: NSRect(x: 3, y: 2, width: 12, height: 12), xRadius: 3, yRadius: 3)
            shell.windingRule = .evenOdd
            shell.appendOval(in: NSRect(x: 5, y: 8, width: 2.5, height: 3))
            shell.appendOval(in: NSRect(x: 10.5, y: 8, width: 2.5, height: 3))
            let smile = NSBezierPath()
            smile.move(to: NSPoint(x: 5.5, y: 6.5))
            smile.curve(to: NSPoint(x: 12.5, y: 6.5), controlPoint1: NSPoint(x: 7.5, y: 3), controlPoint2: NSPoint(x: 10.5, y: 3))
            smile.line(to: NSPoint(x: 11.3, y: 7.1))
            smile.curve(to: NSPoint(x: 6.7, y: 7.1), controlPoint1: NSPoint(x: 10.1, y: 4.7), controlPoint2: NSPoint(x: 7.9, y: 4.7))
            smile.close()
            shell.append(smile)
            shell.fill()
            NSBezierPath(roundedRect: NSRect(x: 0.5, y: 6, width: 2, height: 5), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 15.5, y: 6, width: 2, height: 5), xRadius: 0.8, yRadius: 0.8).fill()
            NSRect(x: 8.25, y: 13.5, width: 1.5, height: 2).fill()
            NSBezierPath(ovalIn: NSRect(x: 7.5, y: 15, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = label
        return image
    }
}
