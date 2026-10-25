import AppKit

/// The Euclid mark: a side-view brain filled with flowing "brainwave" lines.
/// Geometry lives in a 512×512 design space with y pointing down (like SVG);
/// `draw(in:)` maps the mark's 262×262 box (origin 130,128) onto any rect.
enum BrainMark {
    enum Style {
        /// White waves over a translucent brain: for the app icon and promo art.
        case icon
        /// Solid brain with the waves cut out: reads at menu bar size.
        case glyph
    }

    static func draw(in rect: NSRect, color: NSColor, style: Style) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let xf = NSAffineTransform()
        xf.translateX(by: rect.minX, yBy: rect.maxY)
        xf.scaleX(by: rect.width / 262, yBy: -rect.height / 262)
        xf.translateX(by: -130, yBy: -128)
        xf.concat()

        silhouette().addClip()
        let fill = NSBezierPath(rect: NSRect(x: 100, y: 100, width: 320, height: 300))
        switch style {
        case .icon:
            color.withAlphaComponent(0.2).setFill()
            fill.fill()
            let w = waves(count: 9, top: 150, gap: 26, amplitude: 10, amplitudeStep: 4)
            w.lineWidth = 11
            color.setStroke()
            w.stroke()
        case .glyph:
            color.setFill()
            fill.fill()
            let w = waves(count: 5, top: 166, gap: 40, amplitude: 12, amplitudeStep: 4)
            w.lineWidth = 16
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setStroke()
            w.stroke()
        }
    }

    /// The menu bar icon, as a template image so macOS tints it.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            draw(in: rect, color: .black, style: .glyph)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Euclid"
        return image
    }

    /// Cerebrum, cerebellum and stem, all wound the same way so the clip is their union.
    static func silhouette() -> NSBezierPath {
        let p = NSBezierPath()
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
        p.move(to: pt(150, 262))
        p.curve(to: pt(256, 140), controlPoint1: pt(134, 196), controlPoint2: pt(186, 140))
        p.curve(to: pt(380, 250), controlPoint1: pt(330, 138), controlPoint2: pt(386, 184))
        p.curve(to: pt(330, 310), controlPoint1: pt(376, 292), controlPoint2: pt(352, 306))
        p.curve(to: pt(248, 314), controlPoint1: pt(300, 314), controlPoint2: pt(270, 306))
        p.curve(to: pt(150, 262), controlPoint1: pt(216, 326), controlPoint2: pt(166, 314))
        p.close()
        // Cerebellum: an ellipse drawn right → bottom → left → top, matching the cerebrum's direction.
        let (cx, cy, rx, ry, k): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (322, 318, 52, 34, 0.5523)
        p.move(to: pt(cx + rx, cy))
        p.curve(to: pt(cx, cy + ry), controlPoint1: pt(cx + rx, cy + k * ry), controlPoint2: pt(cx + k * rx, cy + ry))
        p.curve(to: pt(cx - rx, cy), controlPoint1: pt(cx - k * rx, cy + ry), controlPoint2: pt(cx - rx, cy + k * ry))
        p.curve(to: pt(cx, cy - ry), controlPoint1: pt(cx - rx, cy - k * ry), controlPoint2: pt(cx - k * rx, cy - ry))
        p.curve(to: pt(cx + rx, cy), controlPoint1: pt(cx + k * rx, cy - ry), controlPoint2: pt(cx + rx, cy - k * ry))
        p.close()
        p.move(to: pt(268, 300))
        p.line(to: pt(300, 300))
        p.line(to: pt(292, 372))
        p.curve(to: pt(276, 372), controlPoint1: pt(291, 380), controlPoint2: pt(278, 380))
        p.close()
        p.windingRule = .nonZero
        return p
    }

    static func waves(count: Int, top: CGFloat, gap: CGFloat, amplitude: CGFloat, amplitudeStep: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        for i in 0..<count {
            let y = top + CGFloat(i) * gap
            let a = amplitude + CGFloat(i % 3) * amplitudeStep
            let phase = CGFloat(i) * 0.9
            for (n, x) in stride(from: CGFloat(120), through: 400, by: 8).enumerated() {
                let point = NSPoint(x: x, y: y + a * sin(x / 26 + phase))
                if n == 0 { p.move(to: point) } else { p.line(to: point) }
            }
        }
        return p
    }
}
