import AppKit

/// `euclid-bar --render-icon <file.icns>`: renders the app icon (brain on the
/// promo gradient) at every macOS icon size and packs it with `iconutil`.
@MainActor
enum IconRenderer {
    static func render(to icns: URL) throws {
        let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.removeItem(at: iconset)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try png(image(pixels: points * scale)).write(to: iconset.appendingPathComponent(name))
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        print("icon → \(icns.path)")
    }

    static func image(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let s = CGFloat(pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // macOS icon grid: the shape sits ~10% inside the canvas, with a soft shadow.
        let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
        let shape = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = s * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.15, blue: 0.40, alpha: 1),
                            NSColor(srgbRed: 0.45, green: 0.20, blue: 0.55, alpha: 1),
                            NSColor(srgbRed: 0.95, green: 0.45, blue: 0.40, alpha: 1)])!
            .draw(in: body, angle: 60)
        // Subtle top highlight for depth.
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        if let brain = NSImage(systemSymbolName: "brain", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = brain.size
            let glow = NSShadow()
            glow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            glow.shadowBlurRadius = s * 0.02
            glow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
            NSGraphicsContext.saveGraphicsState()
            glow.set()
            brain.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2, width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func png(_ rep: NSBitmapImageRep) throws -> Data {
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
