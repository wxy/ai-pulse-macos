import AppKit

/// Shared helper to load AIPulse.png regardless of how the binary is run
/// (bare executable from .build/debug/ or proper .app bundle).
enum AppIconLoader {
    static func load() -> NSImage {
        // .app bundle
        if let bundleImg = NSImage(contentsOf: Bundle.main.resourceURL?
            .appendingPathComponent("AIPulse.png") ?? URL(fileURLWithPath: "")) {
            return bundleImg
        }
        // Bare binary: search upward from binary location
        let binaryDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for depth in 1...4 {
            let up = (0..<depth).map { _ in ".." }.joined(separator: "/")
            if let img = NSImage(contentsOf: binaryDir.appendingPathComponent("\(up)/Resources/AIPulse.png")) {
                return img
            }
        }
        return NSImage(systemSymbolName: "fuelpump.fill", accessibilityDescription: nil)!
    }
}
