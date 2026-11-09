import AppKit
import AVFoundation
import EuclidCore
import ImageIO
import UniformTypeIdentifiers

/// `euclid-bar --render-demo <dir>`: renders the website's hero demo (demo.mp4, plus demo.gif).
///
/// The panel in every frame is the app's real LauncherViewController, rendered
/// offscreen and driven step by step; it grows, shrinks and opens the preview the way
/// the real panel does. Clips, apps, files and plugin rows are curated samples, never the
/// user's own. Uses only system frameworks (ImageIO, AVFoundation).
@MainActor
enum DemoRenderer {
    static let canvas = NSSize(width: 1100, height: 660)  // points; wide enough for the panel with its preview
    static let scale: CGFloat = 2                         // render at 2x
    static let gifWidth = 1280                            // GIF pixels; MP4 stays 2x
    /// Where the panel's top edge sits, like the app's fixed anchor.
    static let panelTop: CGFloat = 600

    struct Frame { let image: CGImage; let duration: Double }

    struct ChatLine { let fromYou: Bool; let text: String }

    enum Scene {
        case panel(caption: String, key: String?)
        case terminal(caption: String, lines: [String])
        case chat(caption: String, lines: [ChatLine])
        case config(caption: String)
        case endCard
    }

    // MARK: - Storyboard

    static func render(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let history = sampleHistory()
        let vc = LauncherViewController(items: { history.items })
        var size = LauncherViewController.size
        vc.onPreferredSizeChange = { size = $0 }
        ScreensRenderer.wire(vc, clips: history)
        let apps = sampleApps()
        vc.appsProvider = { apps }
        let window = ScreensRenderer.offscreenWindow(for: vc) // the layout engine lives in a window, like the real panel
        let view = vc.view
        vc.defaultAppearance = NSAppearance(named: .darkAqua)
        vc.tip = Tips.all[0]
        vc.demoSetQuery("")

        var frames: [Frame] = []
        var shown = size

        /// Let async work (app icons) land, then draw the panel at `size`.
        func panelImage(at s: NSSize) -> CGImage {
            window.setContentSize(s)
            return snapshot(view)
        }
        /// The panel at its current size (animated from the last one, eased out over 80 ms like the app), then hold.
        func shot(_ caption: String, _ seconds: Double, key: String? = nil) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let target = size
            if target != shown {
                let steps = 4
                for i in 1...steps {
                    let t = ScreensRenderer.easeOut(Double(i) / Double(steps))
                    let s = NSSize(width: ScreensRenderer.lerp(shown.width, target.width, t),
                                   height: ScreensRenderer.lerp(shown.height, target.height, t))
                    frames.append(Frame(image: compose(.panel(caption: caption, key: key), panel: panelImage(at: s), size: s),
                                        duration: 0.12 / Double(steps)))
                }
                shown = target
            }
            frames.append(Frame(image: compose(.panel(caption: caption, key: key), panel: panelImage(at: target), size: target),
                                duration: seconds))
        }
        func scene(_ scene: Scene, _ seconds: Double) {
            frames.append(Frame(image: compose(scene, panel: nil, size: .zero), duration: seconds))
        }
        func type(_ text: String, caption: String, from prefix: String = "") {
            for i in 1...text.count {
                vc.demoSetQuery(prefix + String(text.prefix(i)))
                shot(caption, 0.08)
            }
        }

        // 1. Summon: the empty bar already has your sources, picks and clipboard.
        shot("⌥Space, over any app. Opens in 9 ms", 1.8, key: "⌥ Space")

        // 2. Apps by initials.
        type("am", caption: "Apps by their initials: am → Activity Monitor")
        shot("Apps by their initials: am → Activity Monitor", 1.4, key: "↵")

        // 3. One box for everything, timed on every keystroke.
        let everything = "Clipboard, browser history, projects, notes and files in one list"
        vc.demoSetQuery("")
        type("rebase", caption: everything)
        vc.setContentResults([
            ContentHit(ref: "/Users/me/Notes/Git tips.md", title: "Git tips", snippet: "…interactive rebase: squash, fixup, reword…"),
        ], for: "rebase")
        vc.setFileResults([
            FileHit(path: "/Users/me/Documents/rebase-cheatsheet.pdf", isFolder: false),
        ], for: "rebase")
        shot(everything, 2.0)
        let posterFrame = frames.count - 1
        vc.demoSelect(row: vc.demoRowCount - 1) // scroll down to the notes and files
        shot(everything, 1.4, key: "↓")
        vc.demoSelect(row: 0)
        shot("The footer times every search: 1.4 ms worst case over 10,000 items", 2.0)

        // 4. Preview as you arrow.
        vc.demoMove(by: 1)
        shot("↓ previews as you go", 1.8, key: "↓")
        vc.prepareForShow()

        // 5. ⇥ narrows to one source.
        type("clip", caption: "Type a source's name, then ⇥")
        vc.demoTab()
        shot("⇥: only the clipboard", 1.0, key: "⇥")
        type("kube", caption: "⇥: only the clipboard")
        shot("⇥: only the clipboard", 1.4)
        vc.prepareForShow()

        // 6. Developer answers inline.
        let answers = "Developer answers inline: epoch, colours, JSON"
        type("1697040000", caption: answers)
        shot(answers, 1.2)
        vc.demoSetQuery("#7c5cff")
        shot(answers, 1.0)
        vc.demoSetQuery(#"{"name":"euclid","fast":true}"#)
        shot(answers, 1.2)

        // 7. No match → your actions → an AI agent in a terminal.
        vc.demoSetQuery("")
        let question = "explain git reflog like I'm five"
        type(question, caption: "No match? Your actions run on what you typed")
        shot("No match? Your actions run on what you typed", 1.2)
        vc.demoToggleActions()
        shot("⌘K lists every action. 1–9 runs one", 1.4, key: "⌘ K")
        shot("⌘K lists every action. 1–9 runs one", 0.6, key: "1")
        scene(.terminal(caption: "…and your own AI answers in a new Ghostty tab", lines: [
            "❯ pi \"\(question)\"",
            "",
            "  The reflog is git's diary: every time HEAD moves",
            "  (commit, rebase, reset), it writes a line.",
            "",
            "    git reflog",
            "    git reset --hard HEAD@{2}",
            "",
            "  Lost a commit? It's almost always still in there.",
        ]), 2.8)
        vc.demoToggleActions()
        vc.prepareForShow()

        // 8. Plugins: a script becomes a source, a badge, a screen.
        vc.badges = [.init(pluginID: "tokens", text: "1.2M tok · $4.10", icon: "gauge.with.dots.needle.33percent", hasClick: true)]
        let pluginCaption = "Plugins in any language: GitHub as a source, Claude tokens on the bar"
        type("filters", caption: pluginCaption)
        shot(pluginCaption, 2.0)
        vc.badges = []
        vc.prepareForShow()

        vc.present(PluginView(layout: .grid, title: "Emoji", placeholder: "Search emoji…", columns: 8,
                              items: ScreensRenderer.sampleEmoji()), pluginID: "emoji", pluginName: "Emoji")
        let kitCaption = "Scripts draw screens: a grid…"
        shot(kitCaption, 0.8)
        type("party", caption: kitCaption)
        shot(kitCaption, 0.8)
        vc.prepareForShow()

        let weather = PluginItem(title: "Weather", subtitle: "Web", run: "./run.sh weather.sh", icon: "🌤", label: "Script", arguments: [
            PluginArgument(placeholder: "City"),
            PluginArgument(type: .dropdown, placeholder: "Units", optional: true,
                           data: [.init(title: "Metric", value: "m"), .init(title: "US", value: "u")]),
        ])
        vc.present(PluginView(layout: .list, title: "Raycast scripts", items: [weather]), pluginID: "raycast", pluginName: "Raycast scripts")
        vc.demoActivate()
        shot("…typed arguments: your Raycast scripts run as they are…", 1.8, key: "↵")
        vc.prepareForShow()

        let containers = [
            PluginItem(title: "web", subtitle: "nginx:1.27 · Up 3 minutes", run: "./container.sh a1", icon: "🟢", id: "docker:a1"),
            PluginItem(title: "api", subtitle: "acme/api:dev · Up 2 hours", run: "./container.sh b2", icon: "🟢", id: "docker:b2"),
            PluginItem(title: "db", subtitle: "postgres:16 · Exited (0) 2 hours ago", run: "./container.sh c3", icon: "⚪️", id: "docker:c3"),
        ]
        vc.present(PluginView(layout: .list, title: "Containers", placeholder: "Filter containers…", items: containers,
                              reload: "./containers.sh", refreshSeconds: 3), pluginID: "docker", pluginName: "Docker")
        shot("…and live lists, refreshed every few seconds", 1.8)
        vc.prepareForShow()

        // 9. Settings in plain words, with any AI chat.
        vc.commands = AppCommand.settingsWithAI(problems: false)
        let settingsCaption = "Change settings in plain words, with any AI chat"
        type("settings", caption: settingsCaption)
        vc.demoSelect(row: 1) // below the System Settings app
        shot(settingsCaption, 1.4, key: "↵")
        scene(.chat(caption: settingsCaption, lines: [
            ChatLine(fromYou: true, text: "Use Tokyo Night, make it compact, and put Slack on ⌃⌥S"),
            ChatLine(fromYou: false, text: "Done: three lines in ~/.config/euclid/config.toml"),
            ChatLine(fromYou: false, text: "[appearance] theme = \"tokyo-night\", density = \"compact\""),
            ChatLine(fromYou: false, text: "[hotkeys] Slack = \"ctrl+opt+s\""),
        ]), 3.0)
        vc.commands = []
        vc.prepareForShow()

        // 10. Themes.
        var look = Appearance()
        look.density = .compact
        for name in ["tokyo-night", "catppuccin-latte", "aurora", "sakura", "dracula"] {
            look.theme = name
            look.palette = Themes.builtIn[name]
            vc.theme = Theme(look)
            vc.demoSetQuery("git")
            shot("\(Themes.names.count) themes built in, or write your own", name == "tokyo-night" ? 1.4 : 0.8)
        }
        vc.theme = Theme(Appearance())

        // 11. One file.
        scene(.config(caption: "The whole setup is one file. Put it in git"), 3.2)

        // 12. End card.
        scene(.endCard, 3.6)

        if ProcessInfo.processInfo.environment["DEMO_FRAMES"] != nil { // inspect individual frames
            for (i, f) in frames.enumerated() {
                let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(String(format: "frame-%03d.png", i)) as CFURL,
                                                           UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, f.image, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        try writeGIF(frames, to: dir.appendingPathComponent("demo.gif"))
        try writeMP4(frames, to: dir.appendingPathComponent("demo.mp4"))
        // The site's poster: the busiest search frame.
        try ScreensRenderer.writePNG(frames[posterFrame].image, to: dir.appendingPathComponent("poster.png"))
        let total = frames.reduce(0) { $0 + $1.duration }
        withExtendedLifetime(window) {}
        print("rendered \(frames.count) frames, \(String(format: "%.1f", total))s → \(dir.path)")
    }

    /// Apps every Mac has, so the rows get real icons wherever this renders.
    static func sampleApps() -> [SearchItem] {
        [("Activity Monitor", "/System/Applications/Utilities/Activity Monitor.app"),
         ("App Store", "/System/Applications/App Store.app"),
         ("Safari", "/Applications/Safari.app"),
         ("Terminal", "/System/Applications/Utilities/Terminal.app"),
         ("Notes", "/System/Applications/Notes.app"),
         ("Calculator", "/System/Applications/Calculator.app"),
         ("System Settings", "/System/Applications/System Settings.app")]
            .enumerated().map { SearchItem(id: $0.offset, title: $0.element.0, subtitle: $0.element.1) }
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
        // Real bundle IDs, so a Mac with these apps shows their icons on the rows.
        let ids = ["Ghostty": "com.mitchellh.ghostty", "Zed": "dev.zed.Zed", "Notes": "com.apple.Notes",
                   "TablePlus": "com.tinyapp.TablePlus", "Dia": "company.thebrowser.dia"]
        for (text, app, ago) in samples {
            h.record(text, sourceBundleID: ids[app], sourceName: app, at: now.addingTimeInterval(-ago))
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

    static func compose(_ scene: Scene, panel: CGImage?, size: NSSize) -> CGImage {
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
                let rect = NSRect(x: ((canvas.width - size.width) / 2).rounded(), y: panelTop - size.height,
                                  width: size.width, height: size.height)
                if let panel { drawPanel(panel, in: rect) }
                drawCaption(caption)
                if let key { drawKeycap(key, above: rect) }
            case .terminal(let caption, let lines):
                drawTerminal(lines)
                drawCaption(caption)
            case .chat(let caption, let lines):
                drawChat(lines)
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

    /// Where the terminal, chat and config windows sit: the panel's spot, a little wider.
    static let windowRect = NSRect(x: (canvas.width - 760) / 2, y: panelTop - 400, width: 760, height: 400)

    static func drawWallpaper() {
        NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.11, blue: 0.24, alpha: 1),
                            NSColor(srgbRed: 0.33, green: 0.16, blue: 0.42, alpha: 1),
                            NSColor(srgbRed: 0.86, green: 0.40, blue: 0.36, alpha: 1)])!
            .draw(in: NSRect(origin: .zero, size: canvas), angle: 35)
    }

    /// The real panel, on a dark translucent card (vibrancy doesn't render offscreen).
    static func drawPanel(_ panel: CGImage, in rect: NSRect) {
        card(rect, radius: 16, fill: NSColor(white: 0.13, alpha: 0.94))
        NSGraphicsContext.current!.cgContext.draw(panel, in: rect)
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
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let pill = NSRect(x: (canvas.width - size.width) / 2 - 18, y: 30, width: size.width + 36, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.38).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        s.draw(at: NSPoint(x: pill.minX + 18, y: pill.minY + 8))
    }

    /// A keycap just above the panel's right edge.
    static func drawKeycap(_ key: String, above panel: NSRect) {
        let s = NSAttributedString(string: key, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 19, weight: .semibold),
            .foregroundColor: NSColor(white: 0.12, alpha: 1),
        ])
        let size = s.size()
        let rect = NSRect(x: panel.maxX - size.width - 28, y: min(panel.maxY + 12, canvas.height - 46), width: size.width + 28, height: 38)
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
        let rect = windowRect
        windowChrome(rect, title: "pi — Ghostty")
        let mono = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        var y = rect.maxY - 72
        for line in lines {
            let isPrompt = line.hasPrefix("❯")
            let isCode = line.hasPrefix("    ")
            let color: NSColor = isPrompt ? NSColor(srgbRed: 0.55, green: 0.85, blue: 0.55, alpha: 1)
                : isCode ? NSColor(srgbRed: 0.98, green: 0.80, blue: 0.45, alpha: 1) : NSColor(white: 0.88, alpha: 1)
            NSAttributedString(string: line, attributes: [.font: mono, .foregroundColor: color])
                .draw(at: NSPoint(x: rect.minX + 28, y: y))
            y -= 28
        }
    }

    /// Any AI chat: you ask in plain words, it edits config.toml.
    static func drawChat(_ lines: [ChatLine]) {
        let rect = windowRect
        windowChrome(rect, title: "Any AI chat")
        var y = rect.maxY - 60
        for (i, line) in lines.enumerated() {
            let isCode = !line.fromYou && i > 1
            let font = isCode ? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular) : NSFont.systemFont(ofSize: 17, weight: .medium)
            let s = NSAttributedString(string: line.text, attributes: [
                .font: font,
                .foregroundColor: isCode ? NSColor(srgbRed: 0.98, green: 0.80, blue: 0.45, alpha: 1) : NSColor.white,
            ])
            let size = s.size()
            let bubble = NSRect(x: line.fromYou ? rect.maxX - size.width - 56 : rect.minX + 28,
                                y: y - size.height - 14, width: size.width + 28, height: size.height + 16)
            let fill = line.fromYou ? NSColor(srgbRed: 0.42, green: 0.33, blue: 0.95, alpha: 1)
                : NSColor(white: isCode ? 0.06 : 0.20, alpha: 1)
            fill.setFill()
            NSBezierPath(roundedRect: bubble, xRadius: 12, yRadius: 12).fill()
            s.draw(at: NSPoint(x: bubble.minX + 14, y: bubble.minY + 8))
            y = bubble.minY - (i == 0 ? 22 : 10)
        }
    }

    static func drawConfig() {
        let rect = windowRect
        windowChrome(rect, title: "~/.config/euclid/config.toml")
        let mono = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let key = NSColor(srgbRed: 0.55, green: 0.75, blue: 1.0, alpha: 1)
        let str = NSColor(srgbRed: 0.98, green: 0.80, blue: 0.45, alpha: 1)
        let head = NSColor(srgbRed: 0.85, green: 0.55, blue: 0.95, alpha: 1)
        let dim = NSColor(white: 0.5, alpha: 1)
        let lines: [[(String, NSColor)]] = [
            [("[appearance]", head)],
            [("theme", key), ("   = ", dim), (#""tokyo-night""#, str)],
            [("density", key), (" = ", dim), (#""compact""#, str)],
            [],
            [("[hotkeys]", head)],
            [("Slack", key), (" = ", dim), (#""ctrl+opt+s""#, str)],
            [],
            [("[[action]]", head), ("                         # ⌘1", dim)],
            [("name", key), (" = ", dim), (#""pi in Ghostty""#, str)],
            [("run", key), ("  = ", dim), (#"'ghostty-run tab pi "$1"'"#, str)],
            [],
            [("[search]", head)],
            [("sources", key), (" = ", dim), (#"["clipboard", "apps", "github"]"#, str)],
        ]
        var y = rect.maxY - 66
        for parts in lines {
            let line = NSMutableAttributedString()
            for (text, color) in parts { line.append(NSAttributedString(string: text, attributes: [.font: mono, .foregroundColor: color])) }
            line.draw(at: NSPoint(x: rect.minX + 28, y: y))
            y -= 24
        }
    }

    static func drawEndCard() {
        func centered(_ text: String, _ font: NSFont, _ color: NSColor, y: CGFloat) {
            let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            s.draw(at: NSPoint(x: (canvas.width - s.size().width) / 2, y: y))
        }
        BrainMark.draw(in: NSRect(x: canvas.width / 2 - 40, y: 450, width: 80, height: 80), color: .white, style: .icon)
        centered("Meet Euclid", .systemFont(ofSize: 60, weight: .bold), .white, y: 355)
        centered("Search anything on your Mac. Fast, light, one config file.", .systemFont(ofSize: 25, weight: .medium),
                 NSColor.white.withAlphaComponent(0.92), y: 305)
        centered("⚡ 1.4 ms search   ·   🪶 54 MB at idle   ·   🧩 plugins in any language",
                 .systemFont(ofSize: 20, weight: .regular), NSColor.white.withAlphaComponent(0.88), y: 235)
        centered("Your Raycast scripts run as they are · bring your own AI · no account, no subscription",
                 .systemFont(ofSize: 17, weight: .regular), NSColor.white.withAlphaComponent(0.72), y: 195)
        centered("Free for personal use · lgtm.ninja/euclid", .monospacedSystemFont(ofSize: 21, weight: .semibold), .white, y: 110)
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
    static func writeMP4(_ frames: [Frame], size: NSSize = canvas, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let w = Int(size.width * scale), h = Int(size.height * scale)
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
