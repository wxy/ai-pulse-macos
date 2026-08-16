import SwiftUI

/// Activity-style ring shared by watchOS, the iOS widget, and any future
/// macOS visual. Pure SwiftUI — cross-platform compatible.
public struct ActivityRing: View {
    public let progress: Double
    public let thickness: CGFloat
    public let color: Color

    public init(progress: Double, thickness: CGFloat, color: Color) {
        self.progress = progress
        self.thickness = thickness
        self.color = color
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.20), style: StrokeStyle(lineWidth: thickness, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: progress)
        }
    }
}

public extension Color {
    static let marsGreen = Color(red: 44/255, green: 91/255, blue: 72/255)
    static let marsGreen2 = Color(red: 61/255, green: 122/255, blue: 96/255)
    static let marsGreenLight = Color(red: 140/255, green: 196/255, blue: 170/255)
    static let deepRed = Color(red: 173/255, green: 46/255, blue: 35/255)
    static let deepRed2 = Color(red: 196/255, green: 74/255, blue: 63/255)
}
