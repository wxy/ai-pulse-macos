import SwiftUI

/// Text drawn along a caller-defined circular baseline. The component makes no
/// assumption about quadrants: angle, radius, radial alignment, font metrics,
/// and maximum sweep are all inputs. Short strings follow the arc one grapheme
/// at a time; strings that would become too small fall back to a tangent line.
public struct ArcText: View {
    public enum Direction: Sendable {
        case clockwise
        case counterClockwise

        fileprivate var sign: CGFloat {
            switch self {
            case .clockwise: 1
            case .counterClockwise: -1
            }
        }
    }

    public enum RadialAlignment: Sendable, Equatable {
        case innerEdge
        case center
        case outerEdge

        fileprivate func centerRadius(referenceRadius: CGFloat, renderedHeight: CGFloat) -> CGFloat {
            switch self {
            case .innerEdge: referenceRadius + renderedHeight / 2
            case .center: referenceRadius
            case .outerEdge: referenceRadius - renderedHeight / 2
            }
        }
    }

    private let text: String
    private let radius: CGFloat
    private let centerAngle: Angle
    private let direction: Direction
    private let radialAlignment: RadialAlignment
    private let maximumSweep: Angle
    private let fontSize: CGFloat
    private let fontWeight: Font.Weight
    private let fontDesign: Font.Design
    private let color: Color
    private let characterSpacing: CGFloat
    private let minimumScaleFactor: CGFloat

    public init(
        _ text: String,
        radius: CGFloat,
        centerAngle: Angle,
        direction: Direction,
        radialAlignment: RadialAlignment = .center,
        maximumSweep: Angle,
        fontSize: CGFloat,
        fontWeight: Font.Weight = .regular,
        fontDesign: Font.Design = .default,
        color: Color = .primary,
        characterSpacing: CGFloat = 0,
        minimumScaleFactor: CGFloat = 0.72
    ) {
        self.text = text
        self.radius = radius
        self.centerAngle = centerAngle
        self.direction = direction
        self.radialAlignment = radialAlignment
        self.maximumSweep = maximumSweep
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.fontDesign = fontDesign
        self.color = color
        self.characterSpacing = characterSpacing
        self.minimumScaleFactor = minimumScaleFactor
    }

    public var body: some View {
        Canvas { context, size in
            let style = ArcTextRenderStyle(
                fontSize: fontSize,
                fontWeight: fontWeight,
                fontDesign: fontDesign,
                color: color,
                characterSpacing: characterSpacing,
                minimumScaleFactor: minimumScaleFactor,
                maximumSweep: maximumSweep
            )
            guard var prepared = ArcTextRenderer.prepare(
                text,
                radius: radius,
                style: style,
                context: &context
            ) else { return }
            var drawingRadius = radialAlignment.centerRadius(
                referenceRadius: radius,
                renderedHeight: prepared.renderedHeight
            )
            if radialAlignment != .center,
               let measured = ArcTextRenderer.prepare(
                   text,
                   radius: drawingRadius,
                   style: style,
                   context: &context
               ) {
                prepared = measured
                drawingRadius = radialAlignment.centerRadius(
                    referenceRadius: radius,
                    renderedHeight: measured.renderedHeight
                )
            }
            ArcTextRenderer.draw(
                prepared,
                radius: drawingRadius,
                centerAngle: centerAngle,
                direction: direction,
                size: size,
                context: &context
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }
}

private struct ArcTextRenderStyle {
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let fontDesign: Font.Design
    let color: Color
    let characterSpacing: CGFloat
    let minimumScaleFactor: CGFloat
    let maximumSweep: Angle
}

private struct PreparedArcText {
    let glyphs: [GraphicsContext.ResolvedText]
    let widths: [CGFloat]
    let spacing: CGFloat
    let totalArcLength: CGFloat
    let fallback: GraphicsContext.ResolvedText?
    let renderedHeight: CGFloat
}

private enum ArcTextRenderer {
    static func prepare(
        _ text: String,
        radius: CGFloat,
        style: ArcTextRenderStyle,
        context: inout GraphicsContext
    ) -> PreparedArcText? {
        let characters = Array(text)
        guard !characters.isEmpty, radius > 0 else { return nil }

        let baseFont = Font.system(
            size: style.fontSize,
            weight: style.fontWeight,
            design: style.fontDesign
        )
        let baseGlyphs = characters.map {
            context.resolve(Text(String($0)).font(baseFont).foregroundColor(style.color))
        }
        let baseSizes = baseGlyphs.map(resolvedTextSize)
        let baseArcLength = baseSizes.map(\.width).reduce(0, +)
            + style.characterSpacing * CGFloat(max(0, characters.count - 1))
        let availableArcLength = radius * CGFloat(abs(style.maximumSweep.radians))
        guard baseArcLength > 0, availableArcLength > 0 else { return nil }

        let requiredScale = min(1, availableArcLength / baseArcLength)
        if requiredScale < style.minimumScaleFactor {
            let fallbackFont = Font.system(
                size: style.fontSize * style.minimumScaleFactor,
                weight: style.fontWeight,
                design: style.fontDesign
            )
            let fallback = context.resolve(
                Text(text).font(fallbackFont).foregroundColor(style.color)
            )
            return PreparedArcText(
                glyphs: [],
                widths: [],
                spacing: 0,
                totalArcLength: 0,
                fallback: fallback,
                renderedHeight: resolvedTextSize(fallback).height
            )
        }

        let scaledFont = Font.system(
            size: style.fontSize * requiredScale,
            weight: style.fontWeight,
            design: style.fontDesign
        )
        let glyphs = characters.map {
            context.resolve(Text(String($0)).font(scaledFont).foregroundColor(style.color))
        }
        let sizes = glyphs.map(resolvedTextSize)
        let widths = sizes.map(\.width)
        let spacing = style.characterSpacing * requiredScale
        return PreparedArcText(
            glyphs: glyphs,
            widths: widths,
            spacing: spacing,
            totalArcLength: widths.reduce(0, +)
                + spacing * CGFloat(max(0, characters.count - 1)),
            fallback: nil,
            renderedHeight: sizes.map(\.height).max() ?? 0
        )
    }

    static func draw(
        _ prepared: PreparedArcText,
        radius: CGFloat,
        centerAngle: Angle,
        direction: ArcText.Direction,
        size: CGSize,
        context: inout GraphicsContext
    ) {
        let directionSign = direction.sign
        let centerRadians = CGFloat(centerAngle.radians)
        if let fallback = prepared.fallback {
            draw(
                fallback,
                radius: radius,
                angle: centerRadians,
                rotation: centerRadians + directionSign * .pi / 2,
                size: size,
                context: &context
            )
            return
        }

        var travelled = -prepared.totalArcLength / 2
        for (index, glyph) in prepared.glyphs.enumerated() {
            let width = prepared.widths[index]
            travelled += width / 2
            let angle = centerRadians + directionSign * travelled / radius
            draw(
                glyph,
                radius: radius,
                angle: angle,
                rotation: angle + directionSign * .pi / 2,
                size: size,
                context: &context
            )
            travelled += width / 2 + prepared.spacing
        }
    }

    private static func draw(
        _ text: GraphicsContext.ResolvedText,
        radius: CGFloat,
        angle: CGFloat,
        rotation: CGFloat,
        size: CGSize,
        context: inout GraphicsContext
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let point = CGPoint(
            x: center.x + radius * cos(angle),
            y: center.y + radius * sin(angle)
        )
        var glyphContext = context
        glyphContext.translateBy(x: point.x, y: point.y)
        glyphContext.rotate(by: .radians(rotation))
        glyphContext.draw(text, at: .zero, anchor: .center)
    }

    private static func resolvedTextSize(_ text: GraphicsContext.ResolvedText) -> CGSize {
        text.measure(
            in: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
    }
}
