import AppKit

enum AppIconLoader {
    // macOS 26 icon grid: an 824px rounded body centered on a 1024 canvas, with
    // a 100px transparent margin so it matches every stock Dock icon. The system
    // adds the drop shadow, so we bake none.
    private static let size: CGFloat = 1024
    private static let margin: CGFloat = 100
    private static let cornerRadius: CGFloat = 185.4  // continuous corner radius of the 824px body
    private static let coverage: CGFloat = 0.72       // artwork span as a fraction of the body

    // Debug-build marker: an orange diagonal cut across the top-left corner,
    // mirroring scripts/generate-icons.py --debug so the live Dock icon (which
    // this code redraws on every update) stays visually distinguishable from
    // the release build, matching the static AppIcon / .icns.
    private static let debugNotchFraction: CGFloat = 0.32

    private static var canvasRect: CGRect { CGRect(x: 0, y: 0, width: size, height: size) }
    private static var bodyRect: CGRect { canvasRect.insetBy(dx: margin, dy: margin) }

    /// The base tile (white rounded body + centered artwork, no progress),
    /// rendered once and reused. Identical to the static `.icns`.
    private static let baseTile: NSImage = renderBase()

    /// Original robot artwork with an independent collection-health badge.
    static func load(healthDot: AppHealthMonitor.Severity? = nil) -> NSImage {
        renderHealthImage(healthDot: healthDot)
    }

    static func uiImage(size: CGFloat) -> NSImage {
        let img = baseTile
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            img.draw(in: rect)
            return true
        }
    }

    /// A fixed lamp in the robot tile's lower whitespace, away from the health
    /// badge. Resting/unavailable retain the original artwork without a ring.
    @MainActor
    static func pulseIcon(appearance: PulseAppearance, beat: Bool,
                          healthDot: AppHealthMonitor.Severity) -> NSImage {
        let image = load(healthDot: healthDot)
        if appearance.showsLamp(beat: beat) {
            image.lockFocus()
            let center = CGPoint(x: bodyRect.midX, y: bodyRect.minY + 64)
            let color = appearance.feedbackColor(beat: beat)
            if beat {
                color.withAlphaComponent(0.22).setFill()
                NSBezierPath(ovalIn: CGRect(x: center.x - 56, y: center.y - 56, width: 112, height: 112)).fill()
            }
            color.withAlphaComponent(beat ? 1 : 0.8).setFill()
            NSBezierPath(ovalIn: CGRect(x: center.x - 40, y: center.y - 40, width: 80, height: 80)).fill()
            image.unlockFocus()
        }
        image.accessibilityDescription = appearance.label
        return image
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

        #if DEBUG
        drawDebugNotch(in: body)
        #endif

        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        return img
    }

    /// Debug-build marker: fill an orange diagonal triangle across the body's
    /// top-left corner. Drawn after the artwork but within the rounded-rect
    /// clip, matching scripts/generate-icons.py --debug geometry.
    private static func drawDebugNotch(in body: CGRect) {
        let cut = debugNotchFraction * body.width
        let path = NSBezierPath()
        path.move(to: NSPoint(x: body.minX, y: body.maxY))        // top-left corner
        path.line(to: NSPoint(x: body.minX + cut, y: body.maxY))  // along the top edge
        path.line(to: NSPoint(x: body.minX, y: body.maxY - cut))  // along the left edge
        path.close()
        NSColor(calibratedRed: 1.0, green: 149.0 / 255.0, blue: 0.0, alpha: 1.0).setFill()
        path.fill()
    }

    private static func renderHealthImage(healthDot: AppHealthMonitor.Severity?) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        baseTile.draw(in: canvasRect)

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



    // MARK: - Artwork

    /// The artwork cropped to its visible (non-white) bounds, computed once.
    /// Cropping removes the source PNG's wide white margins so the robot fills
    /// the tile like a normal app-icon glyph instead of floating in white.
    private static let artwork: (image: NSImage, size: CGSize)? = loadArtwork()

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
