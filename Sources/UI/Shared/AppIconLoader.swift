import AppKit

enum AppIconLoader {
    // macOS 26 icon grid: an 824px rounded body centered on a 1024 canvas, with
    // a 100px transparent margin so it matches every stock Dock icon. The system
    // adds the drop shadow, so we bake none.
    private static let size: CGFloat = 1024
    private static let margin: CGFloat = 100
    private static let cornerRadius: CGFloat = 185.4  // continuous corner radius of the 824px body
    private static let coverage: CGFloat = 0.72       // artwork span as a fraction of the body

    private static var canvasRect: CGRect { CGRect(x: 0, y: 0, width: size, height: size) }
    private static var bodyRect: CGRect { canvasRect.insetBy(dx: margin, dy: margin) }

    /// The base tile (white rounded body + centered artwork, no progress),
    /// rendered once and reused. Identical to the static `.icns`.
    private static nonisolated(unsafe) let baseTile: NSImage = renderBase()

    /// Load the icon with a linear progress ring, optional lap counter and health dot.
    /// - Parameter progress: 0+ (1.0 = 1× daily average = full circle).
    /// - Parameter lap: number of completed laps (first lap = 0). Shown as a small
    ///   digit in the bottom-left corner when ≥ 1.
    /// - Parameter healthDot: nil → no dot; non-nil → coloured dot at bottom-right.
    static func load(progress: Double = 0, lap: Int = 0,
                     healthDot: AppHealthMonitor.Severity? = nil) -> NSImage {
        return renderProgress(fraction: CGFloat(max(progress, 0)),
                              lap: lap, healthDot: healthDot)
    }

    /// Render a pulse frame: artwork scaled up with a gold overlay.
    /// - Parameter scale: artwork scale multiplier (1.0 = normal, 1.3 = 30% larger)
    /// - Parameter tintAmount: 0 = no gold, 1 = full gold overlay
    static func pulseFrame(scale: CGFloat, tintAmount: CGFloat) -> NSImage {
        let px = Int(size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return baseTile }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let body = bodyRect
        NSBezierPath(roundedRect: body, xRadius: cornerRadius, yRadius: cornerRadius).addClip()

        // White background
        NSColor.white.setFill()
        body.fill()

        // Artwork with scale
        if let art = artwork {
            let maxDim = max(art.size.width, art.size.height)
            let baseScale = (coverage * body.width) / maxDim
            let s = baseScale * scale
            let w = art.size.width * s
            let h = art.size.height * s
            let target = CGRect(x: body.midX - w / 2, y: body.midY - h / 2, width: w, height: h)
            art.image.draw(in: target)
        }

        // Gold overlay on top (tintAmount controls opacity)
        if tintAmount > 0.01 {
            let gold = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.08, alpha: tintAmount * 0.55)
            gold.setFill()
            body.fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        return img
    }

    static func uiImage(size: CGFloat) -> NSImage {
        let img = baseTile
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            img.draw(in: rect)
            return true
        }
    }

    // MARK: - Tile rendering

    /// Render the white rounded body with the artwork centered inside it.
    /// We clip ourselves because a programmatic `applicationIconImage` bypasses
    /// the system's automatic mask (which only applies to the `.icns` file).
    private static func renderBase() -> NSImage {
        let px = Int(size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return NSImage(size: NSSize(width: size, height: size)) }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let body = bodyRect
        NSBezierPath(roundedRect: body, xRadius: cornerRadius, yRadius: cornerRadius).addClip()

        NSColor.white.setFill()
        body.fill()

        if let art = artwork {
            let maxDim = max(art.size.width, art.size.height)
            let scale = (coverage * body.width) / maxDim
            let w = art.size.width * scale
            let h = art.size.height * scale
            let target = CGRect(x: body.midX - w / 2, y: body.midY - h / 2, width: w, height: h)
            art.image.draw(in: target)
        }

        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        return img
    }

    /// Draw a single-colour linear progress ring (100% = full circle = 1× daily
    /// average), an optional lap-counter digit in the bottom-left corner (when
    /// lap ≥ 1), and an optional health dot at the bottom-right corner.
    private static func renderProgress(fraction: CGFloat,
                                       lap: Int,
                                       healthDot: AppHealthMonitor.Severity?,
                                       ringWidth: CGFloat = 22) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        baseTile.draw(in: canvasRect)

        // ── Progress ring ──
        let inset: CGFloat = 10 + ringWidth / 2
        let barRect = bodyRect.insetBy(dx: inset, dy: inset)
        let barCr = max(cornerRadius - inset, 0)
        // Use remainder so lap 2 starts fresh from 0% instead of staying at 100%
        let remainder = fraction.truncatingRemainder(dividingBy: 1.0)
        let ringFraction = (remainder == 0 && fraction >= 1.0) ? 1.0 : remainder

        if ringFraction > 0.001 {
            let path = progressPath(rect: barRect, cornerRadius: barCr,
                                    fraction: ringFraction)
            NSColor.systemGreen.setStroke()
            path.lineWidth = ringWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }

        // ── Lap counter (bottom-left corner) ──
        if lap >= 1 {
            let text = "\(min(lap, 9))"
            let fontSize: CGFloat = 80
            let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
            let attr: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
            ]
            let textSize = (text as NSString).size(withAttributes: attr)

            // Bottom-left, halfway between arc centre and corner
            let cx = bodyRect.minX + cornerRadius * 0.65
            let cy = bodyRect.minY + cornerRadius * 0.65
            let r: CGFloat = 52

            let circlePath = NSBezierPath(
                ovalIn: CGRect(x: cx - r, y: cy - r,
                               width: r * 2, height: r * 2))
            NSColor.systemGreen.setFill()
            circlePath.fill()

            let textRect = CGRect(x: cx - textSize.width / 2,
                                  y: cy - textSize.height / 2,
                                  width: textSize.width, height: textSize.height)
            (text as NSString).draw(in: textRect, withAttributes: attr)
        }

        // ── Health dot (bottom-right) ──
        if let sev = healthDot, sev >= .degraded {
            let dotColor: NSColor = switch sev {
            case .critical: .systemRed
            case .impaired: .systemOrange
            case .degraded: .systemYellow
            case .nominal:  .systemGreen
            }
            let dotR: CGFloat = 28
            let dotCenter = CGPoint(x: bodyRect.maxX - dotR - 4,
                                    y: bodyRect.minY + dotR + 4)
            let dotPath = NSBezierPath(
                ovalIn: CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR,
                               width: dotR * 2, height: dotR * 2))
            dotColor.setFill()
            dotPath.fill()
        }

        img.unlockFocus()
        return img
    }

    // MARK: - Progress bar along the rounded-rect perimeter

    /// Build a polyline that walks the rounded-rect border starting at the
    /// 3 o'clock position (right edge, vertically centered) and running clockwise,
    /// cut off at `fraction` of the total perimeter. Sampling the corners as short
    /// line segments avoids the winding-direction ambiguity of `appendArc`, which
    /// is where earlier attempts went wrong.
    private static func progressPath(rect: CGRect, cornerRadius cr: CGFloat, fraction: CGFloat) -> NSBezierPath {
        let pts = perimeterPoints(rect: rect, cornerRadius: cr)
        let path = NSBezierPath()
        guard pts.count > 1 else { return path }

        // Cumulative arc length along the sampled perimeter.
        var lengths: [CGFloat] = [0]
        var total: CGFloat = 0
        for i in 1..<pts.count {
            total += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
            lengths.append(total)
        }

        let target = min(max(fraction, 0), 1) * total
        guard target > 0 else { return path }

        path.move(to: pts[0])
        for i in 1..<pts.count {
            if lengths[i] <= target {
                path.line(to: pts[i])
            } else {
                let segLen = lengths[i] - lengths[i - 1]
                let t = segLen > 0 ? (target - lengths[i - 1]) / segLen : 0
                path.line(to: NSPoint(x: pts[i - 1].x + (pts[i].x - pts[i - 1].x) * t,
                                       y: pts[i - 1].y + (pts[i].y - pts[i - 1].y) * t))
                break
            }
        }
        return path
    }

    /// Ordered points tracing the rounded rectangle clockwise from the 3 o'clock
    /// position (right edge, vertically centered). In this non-flipped bitmap
    /// context y increases upward, so "clockwise" starts by heading down the
    /// right edge toward the bottom.
    private static func perimeterPoints(rect: CGRect, cornerRadius cr: CGFloat) -> [CGPoint] {
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let midY = rect.midY
        let steps = 24  // samples per corner
        var pts: [CGPoint] = []

        func arc(center: CGPoint, from startDeg: CGFloat, to endDeg: CGFloat) {
            for i in 0...steps {
                let a = (startDeg + (endDeg - startDeg) * CGFloat(i) / CGFloat(steps)) * .pi / 180
                pts.append(CGPoint(x: center.x + cr * cos(a), y: center.y + cr * sin(a)))
            }
        }

        pts.append(CGPoint(x: maxX, y: midY))                 // start: 3 o'clock (right-middle)
        pts.append(CGPoint(x: maxX, y: minY + cr))            // right edge ↓
        arc(center: CGPoint(x: maxX - cr, y: minY + cr), from: 0, to: -90)    // bottom-right
        pts.append(CGPoint(x: minX + cr, y: minY))            // bottom edge ←
        arc(center: CGPoint(x: minX + cr, y: minY + cr), from: -90, to: -180) // bottom-left
        pts.append(CGPoint(x: minX, y: maxY - cr))            // left edge ↑
        arc(center: CGPoint(x: minX + cr, y: maxY - cr), from: 180, to: 90)   // top-left
        pts.append(CGPoint(x: maxX - cr, y: maxY))            // top edge →
        arc(center: CGPoint(x: maxX - cr, y: maxY - cr), from: 90, to: 0)     // top-right
        pts.append(CGPoint(x: maxX, y: midY))                 // right edge ↓ back to start
        return pts
    }

    // MARK: - Artwork

    /// The artwork cropped to its visible (non-white) bounds, computed once.
    /// Cropping removes the source PNG's wide white margins so the robot fills
    /// the tile like a normal app-icon glyph instead of floating in white.
    private static nonisolated(unsafe) let artwork: (image: NSImage, size: CGSize)? = loadArtwork()

    private static func loadArtwork() -> (image: NSImage, size: CGSize)? {
        guard let src = findArtwork(),
              let tiff = src.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage,
              let data = rep.bitmapData else { return nil }

        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let bpp = rep.bitsPerPixel / 8
        let bpr = rep.bytesPerRow
        let hasAlpha = rep.hasAlpha

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = data + y * bpr
            for x in 0..<w {
                let p = row + x * bpp
                let a = hasAlpha ? Int(p[3]) : 255
                let lum = Int(p[0]) + Int(p[1]) + Int(p[2])
                if a > 10 && lum < 3 * 245 {  // opaque and not near-white
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return (src, CGSize(width: w, height: h))
        }

        let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = cg.cropping(to: crop) else {
            return (src, CGSize(width: w, height: h))
        }
        let img = NSImage(cgImage: cropped, size: NSSize(width: crop.width, height: crop.height))
        return (img, crop.size)
    }

    private static func findArtwork() -> NSImage? {
        if let bundleImg = NSImage(contentsOf: Bundle.main.resourceURL?
            .appendingPathComponent("AIPulse.png") ?? URL(fileURLWithPath: "")) {
            return bundleImg
        }
        let binaryDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for depth in 1...4 {
            let up = (0..<depth).map { _ in ".." }.joined(separator: "/")
            if let img = NSImage(contentsOf: binaryDir.appendingPathComponent("\(up)/Resources/AIPulse.png")) {
                return img
            }
        }
        return nil
    }
}
