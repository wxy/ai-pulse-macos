import SwiftUI

public struct PulseRobotRGB: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Int, green: Int, blue: Int) {
        self.red = Double(red) / 255
        self.green = Double(green) / 255
        self.blue = Double(blue) / 255
    }
}

public enum PulseRobotPalette {
    /// Unknown remains a platform semantic secondary color.
    public static func rgb(for tier: PulseTier?, dark: Bool) -> PulseRobotRGB? {
        switch (tier, dark) {
        case (.none, _): return nil
        case (.resting?, false): return PulseRobotRGB(red: 44, green: 91, blue: 72)
        case (.resting?, true): return PulseRobotRGB(red: 95, green: 157, blue: 125)
        case (.active?, false): return PulseRobotRGB(red: 58, green: 155, blue: 112)
        case (.active?, true): return PulseRobotRGB(red: 120, green: 205, blue: 165)
        case (.elevated?, false): return PulseRobotRGB(red: 173, green: 46, blue: 35)
        case (.elevated?, true): return PulseRobotRGB(red: 216, green: 90, blue: 80)
        case (.intense?, false): return PulseRobotRGB(red: 230, green: 83, blue: 73)
        case (.intense?, true): return PulseRobotRGB(red: 255, green: 120, blue: 109)
        }
    }
}

/// The 18-point menu-bar robot, expressed as a scalable even-odd SwiftUI shape.
public struct PulseRobotMark: Shape {
    public let tier: PulseTier?

    public init(tier: PulseTier?) {
        self.tier = tier
    }

    public func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / 18
        let scaleY = rect.height / 18
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: rect.minX + x * scaleX,
                y: rect.minY + (18 - y - height) * scaleY,
                width: width * scaleX,
                height: height * scaleY
            )
        }

        var path = Path()
        path.addRoundedRect(
            in: box(3, 2, 12, 12),
            cornerSize: CGSize(width: 3 * scaleX, height: 3 * scaleY)
        )
        path.addEllipse(in: box(5, 8, 2.5, 3))
        path.addEllipse(in: box(10.5, 8, 2.5, 3))
        addMouth(to: &path, box: box, scaleX: scaleX, scaleY: scaleY)
        path.addRoundedRect(
            in: box(0.5, 6, 2, 5),
            cornerSize: CGSize(width: 0.8 * scaleX, height: 0.8 * scaleY)
        )
        path.addRoundedRect(
            in: box(15.5, 6, 2, 5),
            cornerSize: CGSize(width: 0.8 * scaleX, height: 0.8 * scaleY)
        )
        path.addRect(box(8.25, 13.5, 1.5, 2))
        path.addEllipse(in: box(7.5, 15, 3, 3))
        return path
    }

    private func addMouth(
        to path: inout Path,
        box: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) {
        switch tier {
        case .resting, .none:
            path.addRoundedRect(
                in: box(6, 4.5, 6, 1.5),
                cornerSize: CGSize(width: 0.75 * scaleX, height: 0.75 * scaleY)
            )
        case .active:
            let start = point(5.5, 5.3, box: box)
            var smile = Path()
            smile.move(to: start)
            smile.addCurve(
                to: point(12.5, 5.3, box: box),
                control1: point(7.5, 3.9, box: box),
                control2: point(10.5, 3.9, box: box)
            )
            smile.addLine(to: point(12.1, 6.5, box: box))
            smile.addCurve(
                to: point(5.9, 6.5, box: box),
                control1: point(10.3, 5.3, box: box),
                control2: point(7.7, 5.3, box: box)
            )
            smile.closeSubpath()
            path.addPath(smile)
        case .elevated, .intense:
            var smile = Path()
            smile.move(to: point(5.5, 6.5, box: box))
            smile.addCurve(
                to: point(12.5, 6.5, box: box),
                control1: point(7.5, 3, box: box),
                control2: point(10.5, 3, box: box)
            )
            smile.addLine(to: point(11.3, 7.1, box: box))
            smile.addCurve(
                to: point(6.7, 7.1, box: box),
                control1: point(10.1, 4.7, box: box),
                control2: point(7.9, 4.7, box: box)
            )
            smile.closeSubpath()
            path.addPath(smile)
        }
    }

    private func point(
        _ x: CGFloat,
        _ y: CGFloat,
        box: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect
    ) -> CGPoint {
        let origin = box(x, y, 0, 0)
        return origin.origin
    }
}