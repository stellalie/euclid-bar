import AppKit
import AVFoundation
import EuclidCore
import ImageIO
import UniformTypeIdentifiers

/// `euclid-bar --render-demo <dir>`: renders the README promo (demo.gif + demo.mp4).
///
/// The panel in every frame is the app's real LauncherViewController, rendered
/// offscreen and driven step by step. Clips are curated samples, never the
/// user's clipboard. Uses only system frameworks (ImageIO, AVFoundation).
@MainActor
enum DemoRenderer {
    static let canvas = NSSize(width: 960, height: 600)   // points
    static let scale: CGFloat = 2                         // render at 2x
    static let gifWidth = 1280                            // GIF pixels (README); MP4 stays 2x

    struct Frame { let image: CGImage; let duration: Double }

    enum Scene {
        case panel(caption: String, key: String?)
        case terminal(caption: String, lines: [String])
        case config(caption: String)
        case endCard
    }

    // MARK: - Storyboard

    static func render(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let history = sampleHistory()
        let vc = LauncherViewController(items: { history.items })
        let pages = samplePages()
        vc.historyProvider = { pages }
        vc.actions = [
            Action(name: "pi in Ghostty", run: #"ghostty-run tab pi "$1""#),
            Action(name: "pi in herdr", run: #"herdr-run tab pi "$1""#),
            Action(name: "Search web", run: "open …"),
            Action(name: "Search GitHub", run: "open …"),
        ]
        let view = vc.view
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: LauncherViewController.size)
        vc.demoSetQuery("")

        var frames: [Frame] = []
        func shot(_ scene: Scene, _ seconds: Double) {
            frames.append(Frame(image: compose(scene, panel: snapshot(view)), duration: seconds))
        }
        func type(_ text: String, caption: String, startingFrom prefix: String = "") {
            for i in 1...text.count {
                vc.demoSetQuery(prefix + String(text.prefix(i)))
                shot(.panel(caption: caption, key: nil), 0.085)
            }
        }

        // 1. Summon
        shot(.panel(caption: "⌥Space summons it, instantly, over any app", key: "⌥ Space"), 1.6)
        // 2. Fuzzy search: clipboard + browser history together
        let searchCaption = "Clipboard + browser history: 10,000 items searched in under 1 ms"
        type("rebase", caption: searchCaption)
        shot(.panel(caption: searchCaption, key: nil), 1.4)
        vc.demoSelect(row: 0)
        shot(.panel(caption: "↵ pastes a clip straight into the app you were in", key: "↵"), 1.8)
        vc.demoSelect(row: 2)
        shot(.panel(caption: "…or reopens that page you half-remember", key: "↵"), 1.8)

        // 3. No match → actions
        vc.demoSetQuery("")
        let question = "explain git reflog like I'm five"
        type(question, caption: "No match? Your actions are right there")
        precondition(vc.demoRowCount == vc.actions.count, "demo query matched clips; pick another")
        shot(.panel(caption: "No match? Your actions are right there", key: nil), 1.4)

        // 4. ⌘K action list
        vc.demoToggleActions()
        shot(.panel(caption: "⌘K lists every action. 1–9 runs one", key: "⌘ K"), 1.8)
        shot(.panel(caption: "⌘K lists every action. 1–9 runs one", key: "1"), 0.7)

        // 5. Result: pi in a Ghostty tab
        shot(.terminal(caption: "…and pi answers in a new Ghostty tab", lines: [
            "❯ pi \"\(question)\"",
            "",
            "  The reflog is git's diary: every time HEAD moves",
            "  (commit, rebase, reset), it writes a line.",
            "",
            "    git reflog",
            "    git reset --hard HEAD@{2}",
            "",
            "  Lost a commit? It's almost always still in there.",
        ]), 3.2)

        // 6. Config
        shot(.config(caption: "Every action is a shell command in config.toml. Bring any CLI"), 3.6)

        // 7. End card
        shot(.endCard, 3.2)

        if ProcessInfo.processInfo.environment["DEMO_FRAMES"] != nil { // inspect individual frames
            for (i, f) in frames.enumerated() {
                let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(String(format: "frame-%02d.png", i)) as CFURL,
                                                           UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, f.image, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        try writeGIF(frames, to: dir.appendingPathComponent("demo.gif"))
        try writeMP4(frames, to: dir.appendingPathComponent("demo.mp4"))
        let total = frames.reduce(0) { $0 + $1.duration }
        print("rendered \(frames.count) frames, \(String(format: "%.1f", total))s → \(dir.path)")
    }

    static func samplePages() -> [SearchItem] {
        let now = Date()
        return [
            HistoryEntry(url: "https://git-scm.com/docs/git-rebase", title: "Git - git-rebase Documentation",
                         browser: "Dia", lastVisit: now.addingTimeInterval(-40 * 60), visitCount: 4),
            HistoryEntry(url: "https://stackoverflow.com/questions/5189560/how-do-i-squash-my-last-n-commits-together",
                         title: "How do I squash my last N commits together? - Stack Overflow",
                         browser: "Dia", lastVisit: now.addingTimeInterval(-26 * 3600), visitCount: 2),
            HistoryEntry(url: "https://developer.apple.com/documentation/appkit/nspanel", title: "NSPanel | Apple Developer Documentation",
                         browser: "Safari", lastVisit: now.addingTimeInterval(-3 * 3600), visitCount: 1),
        ].enumerated().map { $0.element.searchItem(id: $0.offset) }
    }

    static func sampleHistory() -> ClipHistory {
        let h = ClipHistory()
        let now = Date()
        let samples: [(String, String, Double)] = [   // newest last
            ("brew install --cask ghostty", "Ghostty", 26 * 3600),
            (#"{"name": "euclid-bar", "version": "0.1.0"}"#, "Zed", 25 * 3600),
            ("git rebase --continue", "Ghostty", 3 * 3600),
            ("Meeting notes: ship v1 on Friday", "Notes", 2 * 3600),
            ("docker compose up -d --build", "Ghostty", 3600),
            ("kubectl rollout restart deploy/api -n prod", "Ghostty", 20 * 60),
            ("SELECT id, email FROM users WHERE created_at > now() - interval '7 days';", "TablePlus", 12 * 60),
            ("https://github.com/stellalie/euclid-bar", "Dia", 5 * 60),
            ("git rebase -i HEAD~3", "Ghostty", 2 * 60),
        ]
        for (text, app, ago) in samples {
            h.record(text, sourceBundleID: nil, sourceName: app, at: now.addingTimeInterval(-ago))
        }
        return h
    }

    // MARK: - Drawing

    static func snapshot(_ view: NSView) -> CGImage {
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        return rep.cgImage!
    }

    static func compose(_ scene: Scene, panel: CGImage) -> CGImage {
        let w = Int(canvas.width * scale), h = Int(canvas.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            drawWallpaper()
            switch scene {
            case .panel(let caption, let key):
                drawPanel(panel)
                drawCaption(caption)
                if let key { drawKeycap(key) }
            case .terminal(let caption, let lines):
                drawTerminal(lines)
                drawCaption(caption)
            case .config(let caption):
                drawConfig()
                drawCaption(caption)
            case .endCard:
                drawEndCard()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    static let panelRect = NSRect(x: (canvas.width - LauncherViewController.size.width) / 2, y: 104,
                                  width: LauncherViewController.size.width, height: LauncherViewController.size.height)

    static func drawWallpaper() {
        NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.11, blue: 0.24, alpha: 1),
                            NSColor(srgbRed: 0.33, green: 0.16, blue: 0.42, alpha: 1),
                            NSColor(srgbRed: 0.86, green: 0.40, blue: 0.36, alpha: 1)])!
            .draw(in: NSRect(origin: .zero, size: canvas), angle: 35)
    }

    /// The real panel, on a dark translucent card (vibrancy doesn't render offscreen).
    static func drawPanel(_ panel: CGImage) {
        card(panelRect, radius: 14, fill: NSColor(white: 0.13, alpha: 0.94))
        NSGraphicsContext.current!.cgContext.draw(panel, in: panelRect)
    }

    static func card(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        fill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    static func drawCaption(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let pill = NSRect(x: (canvas.width - size.width) / 2 - 18, y: 34, width: size.width + 36, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        s.draw(at: NSPoint(x: pill.minX + 18, y: pill.minY + 8))
    }

    static func drawKeycap(_ key: String) {
        let s = NSAttributedString(string: key, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor(white: 0.12, alpha: 1),
        ])
        let size = s.size()
        let rect = NSRect(x: panelRect.maxX - size.width - 30, y: panelRect.maxY + 14, width: size.width + 28, height: 40)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor(white: 0.97, alpha: 1).setFill()
        path.fill()
        NSColor(white: 0.70, alpha: 1).setStroke()
        path.lineWidth = 1.5
        path.stroke()
        s.draw(at: NSPoint(x: rect.minX + 14, y: rect.midY - size.height / 2))
    }

    static func windowChrome(_ rect: NSRect, title: String) {
        card(rect, radius: 12, fill: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 0.97))
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 16 + CGFloat(i) * 20, y: rect.maxY - 24, width: 12, height: 12)).fill()
        }
        let t = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(white: 0.6, alpha: 1),
        ])
        t.draw(at: NSPoint(x: rect.midX - t.size().width / 2, y: rect.maxY - 26))
    }

    static func drawTerminal(_ lines: [String]) {
        let rect = panelRect.insetBy(dx: -20, dy: 0)
        windowChrome(rect, title: "pi — Ghostty")
        let mono = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        var y = rect.maxY - 70
        for line in lines {
            let isPrompt = line.hasPrefix("❯")
            let isCode = line.hasPrefix("    ")
            let color: NSColor = isPrompt ? NSColor(srgbRed: 0.55, green: 0.85, blue: 0.55, alpha: 1)
                : isCode ? NSColor(srgbRed: 0.98, green: 0.80, blue: 0.45, alpha: 1) : NSColor(white: 0.88, alpha: 1)
            NSAttributedString(string: line, attributes: [.font: mono, .foregroundColor: color])
                .draw(at: NSPoint(x: rect.minX + 26, y: y))
            y -= 26
        }
    }

    static func drawConfig() {
        let rect = panelRect.insetBy(dx: -20, dy: 0)
        windowChrome(rect, title: "~/.config/euclid/config.toml")
        let mono = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let key = NSColor(srgbRed: 0.55, green: 0.75, blue: 1.0, alpha: 1)
        let str = NSColor(srgbRed: 0.98, green: 0.80, blue: 0.45, alpha: 1)
        let head = NSColor(srgbRed: 0.85, green: 0.55, blue: 0.95, alpha: 1)
        let dim = NSColor(white: 0.5, alpha: 1)
        let lines: [[(String, NSColor)]] = [
            [("[[action]]", head), ("                          # ⌘1", dim)],
            [("name", key), (" = ", dim), (#""pi in Ghostty""#, str)],
            [("run", key), ("  = ", dim), (#"'ghostty-run tab pi "$1"'"#, str)],
            [],
            [("[[action]]", head), ("                          # ⌘2", dim)],
            [("name", key), (" = ", dim), (#""pi in herdr""#, str)],
            [("run", key), ("  = ", dim), (#"'herdr-run tab pi "$1"'"#, str)],
            [],
            [("[[action]]", head), ("                          # ⌘3", dim)],
            [("name", key), (" = ", dim), (#""Search web""#, str)],
            [("run", key), ("  = ", dim), (#"'open "https://google.com/search?q=$EUCLID_QUERY_URL"'"#, str)],
        ]
        var y = rect.maxY - 70
        for parts in lines {
            let line = NSMutableAttributedString()
            for (text, color) in parts { line.append(NSAttributedString(string: text, attributes: [.font: mono, .foregroundColor: color])) }
            line.draw(at: NSPoint(x: rect.minX + 26, y: y))
            y -= 25
        }
    }

    static func drawEndCard() {
        func centered(_ text: String, _ font: NSFont, _ color: NSColor, y: CGFloat) {
            let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            s.draw(at: NSPoint(x: (canvas.width - s.size().width) / 2, y: y))
        }
        if let icon = NSImage(systemSymbolName: "brain", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 64, weight: .semibold).applying(.init(paletteColors: [.white]))) {
            icon.draw(in: NSRect(x: canvas.width / 2 - 40, y: 390, width: 80, height: 80))
        }
        centered("Meet Euclid", .systemFont(ofSize: 56, weight: .bold), .white, y: 300)
        centered("Your blazing fast, fully customisable search-anything companion", .systemFont(ofSize: 23, weight: .medium),
                 NSColor.white.withAlphaComponent(0.92), y: 255)
        centered("⚡ sub-millisecond search   ·   🧩 any CLI is an action   ·   🔒 stays on your Mac",
                 .systemFont(ofSize: 18, weight: .regular), NSColor.white.withAlphaComponent(0.85), y: 190)
        centered("Built for developers · native Swift · free & open source", .systemFont(ofSize: 16, weight: .regular),
                 NSColor.white.withAlphaComponent(0.7), y: 150)
        centered("github.com/stellalie/euclid-bar", .monospacedSystemFont(ofSize: 20, weight: .semibold), .white, y: 80)
    }

    // MARK: - Encoding

    static func writeGIF(_ frames: [Frame], to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let gifHeight = Int(Double(gifWidth) * canvas.height / canvas.width)
        for f in frames {
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: f.duration,
                                                         kCGImagePropertyGIFUnclampedDelayTime: f.duration]] as CFDictionary
            CGImageDestinationAddImage(dest, resize(f.image, width: gifWidth, height: gifHeight), props)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Variable frame durations: each frame is appended once at its start time.
    static func writeMP4(_ frames: [Frame], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let w = Int(canvas.width * scale), h = Int(canvas.height * scale)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var t = 0.0
        for f in frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            ctx.draw(f.image, in: CGRect(x: 0, y: 0, width: w, height: h))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
            t += f.duration
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: t, preferredTimescale: 600))
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let w2 = writer
        w2.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
