import AppKit
import EuclidCore
import ImageIO
import UniformTypeIdentifiers

/// `euclid-bar --render-screens <dir>`: screenshots of each panel state plus `flow.gif`,
/// an animation of the panel growing, shrinking and opening the preview.
///
/// Like `--render-demo`, every frame is the real LauncherViewController rendered
/// offscreen with sample data. Size changes are drawn as the real app animates them
/// (the panel's own preferred size, eased out over 80 ms); the GIF plays them at half speed.
@MainActor
enum ScreensRenderer {
    static let canvas = NSSize(width: 1240, height: 680)
    static let scale: CGFloat = 2
    /// Where the panel's top edge sits, like the app's fixed anchor.
    static let panelTop: CGFloat = 600

    struct Frame { let image: CGImage; let duration: Double }

    static func render(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let clips = DemoRenderer.sampleHistory()
        let vc = LauncherViewController(items: { clips.items })
        var size = LauncherViewController.size
        vc.onPreferredSizeChange = { size = $0 }
        wire(vc, clips: clips)
        let view = vc.view
        view.appearance = NSAppearance(named: .darkAqua)
        vc.demoSetQuery("")

        var frames: [Frame] = []
        var shown = size
        var shotNumber = 0

        /// Let async work (app icons) land, then draw the panel at `size`.
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        func panelImage(at s: NSSize) -> CGImage {
            view.frame = NSRect(origin: .zero, size: s)
            return DemoRenderer.snapshot(view)
        }
        /// Animate from the last drawn size to the current one, then hold.
        func step(_ caption: String, hold: Double, name: String? = nil) throws {
            settle()
            let target = size
            if target != shown {
                let steps = 5
                for i in 1...steps {
                    let t = easeOut(Double(i) / Double(steps))
                    let s = NSSize(width: lerp(shown.width, target.width, t), height: lerp(shown.height, target.height, t))
                    frames.append(Frame(image: compose(panelImage(at: s), size: s, caption: caption), duration: 0.16 / Double(steps)))
                }
                shown = target
            }
            let image = compose(panelImage(at: target), size: target, caption: caption)
            frames.append(Frame(image: image, duration: hold))
            if let name {
                shotNumber += 1
                try writePNG(image, to: dir.appendingPathComponent(String(format: "%02d-%@.png", shotNumber, name)))
            }
        }
        func type(_ text: String, caption: String, from prefix: String = "") throws {
            for i in 1...text.count {
                vc.demoSetQuery(prefix + String(text.prefix(i)))
                try step(caption, hold: 0.12)
            }
        }

        try step("Empty box: suggestions, PRs waiting on your review, clipboard", hold: 1.8, name: "empty")
        vc.demoSetQuery("")
        try type("rebase", caption: "Sections, matched letters highlighted, search speed in the footer")
        vc.setContentResults([
            ContentHit(kind: .note, ref: "/Users/me/Notes/Git tips.md", title: "Git tips", snippet: "…interactive rebase: squash, fixup, reword…"),
        ], for: "rebase")
        try step("Sections, matched letters highlighted, search speed in the footer", hold: 2.0, name: "search-sections")

        vc.demoSetQuery("")
        try type("1697040000", caption: "Developer answers: epoch → date")
        try step("Developer answers: epoch → date", hold: 1.6, name: "epoch")
        vc.demoSetQuery("#7c5cff")
        try step("Colours with a swatch", hold: 1.4, name: "colour")
        vc.demoSetQuery(#"{"name":"euclid","fast":true}"#)
        try step("JSON: pretty or minified", hold: 1.4, name: "json")

        vc.demoSetQuery("docker")
        vc.demoSelect(row: 0)
        try step("→ opens the preview", hold: 0.8)
        vc.demoTogglePreview()
        try step("→ opens the preview", hold: 2.0, name: "preview-clip")
        vc.demoTogglePreview()
        try step("esc closes it", hold: 0.8)

        vc.demoSetQuery("cache")
        try step("Bitbucket: PRs and repos", hold: 1.8, name: "bitbucket")
        vc.demoSetQuery("standup")
        try step("Snippets: the keyword pins it first", hold: 1.6, name: "snippet")

        vc.demoSetQuery("")
        try type("explain git reflog", caption: "No match? Your actions are right there")
        try step("No match? Your actions are right there", hold: 1.4, name: "no-match-actions")
        vc.demoToggleActions()
        try step("⌘K lists every action", hold: 1.6, name: "actions")
        vc.demoToggleActions()

        var compact = Appearance()
        compact.density = .compact
        compact.accent = "#ff8a3d"
        vc.theme = Theme(compact)
        vc.demoSetQuery("git")
        try step("[appearance] density = \"compact\", accent = \"#ff8a3d\"", hold: 2.0, name: "compact-accent")

        try writeGIF(frames, to: dir.appendingPathComponent("flow.gif"))
        let total = frames.reduce(0) { $0 + $1.duration }
        print("rendered \(shotNumber) screenshots and \(frames.count) frames (\(String(format: "%.1f", total))s) → \(dir.path)")
    }

    // MARK: - Sample data

    static func wire(_ vc: LauncherViewController, clips: ClipHistory) {
        let pages = DemoRenderer.samplePages()
        vc.historyProvider = { pages }
        vc.historyURL = { id in ["https://git-scm.com/docs/git-rebase",
                                 "https://stackoverflow.com/questions/5189560",
                                 "https://developer.apple.com/documentation/appkit/nspanel"][safe: id] }
        vc.clip = { clips.clip(id: $0) }
        let apps = [("Safari", "/Applications/Safari.app"), ("Terminal", "/System/Applications/Utilities/Terminal.app"),
                    ("Notes", "/System/Applications/Notes.app"), ("Calculator", "/System/Applications/Calculator.app")]
        let appItems = apps.enumerated().map { SearchItem(id: $0.offset, title: $0.element.0, subtitle: $0.element.1) }
        vc.appsProvider = { appItems }
        let projects = [ProjectEntry(name: "euclid-bar", path: "/Users/me/code/euclid-bar"),
                        ProjectEntry(name: "git-rebase-helper", path: "/Users/me/code/tools/git-rebase-helper")]
        let projectItems = projects.enumerated().map { $0.element.searchItem(id: $0.offset) }
        vc.projectsProvider = { projectItems }
        vc.project = { projects[safe: $0] }
        let now = Date()
        let bitbucket = [
            BitbucketItem(kind: .reviewPR, title: "Add response cache to search API", subtitle: "team/search · #412 · Sam Lee",
                          url: "https://bitbucket.org/team/search/pull-requests/412", updated: now.addingTimeInterval(-3600)),
            BitbucketItem(kind: .myPR, title: "Fix cache invalidation on deploy", subtitle: "team/platform · #88 · Stella",
                          url: "https://bitbucket.org/team/platform/pull-requests/88", updated: now.addingTimeInterval(-7200)),
            BitbucketItem(kind: .repo, title: "team/cache-service", subtitle: "Shared Redis cache client",
                          url: "https://bitbucket.org/team/cache-service", updated: nil),
        ]
        let bitbucketItems = bitbucket.enumerated().map { $0.element.searchItem(id: $0.offset) }
        vc.bitbucketProvider = { bitbucketItems }
        vc.bitbucketItem = { bitbucket[safe: $0] }
        vc.actions = [
            Action(name: "pi in Ghostty", run: #"ghostty-run tab pi "$1""#),
            Action(name: "Claude in herdr", run: #"herdr-run split claude "$1""#),
            Action(name: "Search web", run: #"open "https://www.google.com/search?q=$EUCLID_QUERY_URL""#),
            Action(name: "Search Bitbucket", run: #"open "https://bitbucket.org/search?q=$EUCLID_QUERY_URL""#),
        ]
        vc.snippets = [Snippet(name: "Standup template", keyword: "standup", text: "Yesterday:\nToday:\nBlockers: none ({date})")]
        vc.favorites = ["Terminal", "euclid-bar", "pi in Ghostty"]
    }

    // MARK: - Drawing

    static func compose(_ panel: CGImage, size: NSSize, caption: String) -> CGImage {
        let w = Int(canvas.width * scale), h = Int(canvas.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.11, blue: 0.24, alpha: 1),
                                NSColor(srgbRed: 0.33, green: 0.16, blue: 0.42, alpha: 1),
                                NSColor(srgbRed: 0.86, green: 0.40, blue: 0.36, alpha: 1)])!
                .draw(in: NSRect(origin: .zero, size: canvas), angle: 35)
            let rect = NSRect(x: ((canvas.width - size.width) / 2).rounded(), y: panelTop - size.height, width: size.width, height: size.height)
            DemoRenderer.card(rect, radius: 16, fill: NSColor(white: 0.13, alpha: 0.94))
            NSGraphicsContext.current!.cgContext.draw(panel, in: rect)
            let s = NSAttributedString(string: caption, attributes: [
                .font: NSFont.systemFont(ofSize: 19, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            let pill = NSRect(x: (canvas.width - s.size().width) / 2 - 16, y: 24, width: s.size().width + 32, height: s.size().height + 14)
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            s.draw(at: NSPoint(x: pill.minX + 16, y: pill.minY + 7))
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Half the 2× render, so the GIF stays a sensible size.
    static func writeGIF(_ frames: [Frame], to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for f in frames {
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: f.duration,
                                                         kCGImagePropertyGIFUnclampedDelayTime: f.duration]] as CFDictionary
            CGImageDestinationAddImage(dest, DemoRenderer.resize(f.image, width: Int(canvas.width), height: Int(canvas.height)), props)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
    static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
