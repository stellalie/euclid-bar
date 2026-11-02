import AppKit
import EuclidCore

/// `euclid-bar --pick [--grid] [--columns N] [--prompt TEXT]`: dmenu for the Mac.
/// Reads lines from stdin, opens Euclid's panel to pick one, prints that line exactly as it came in.
/// Exit 0 = picked, 1 = `esc` or clicked away, 64 = nothing piped in.
///
///     git branch --format='%(refname:short)' | euclid-bar --pick --prompt Branch | xargs git switch
///
/// A line that is a JSON item (`{"title":"…","icon":"🌤","subtitle":"…"}`) shows with its icon and subtitle.
@MainActor
enum PickCommand {
    static let usage = "usage: … | euclid-bar --pick [--grid] [--columns 3-10] [--prompt TEXT]"

    static func run(_ args: [String]) -> Int32 {
        var grid = false, prompt: String?, columns = PluginView.defaultColumns
        var rest = args[...]
        while let arg = rest.popFirst() {
            switch arg {
            case "--grid": grid = true
            case "--prompt": prompt = rest.popFirst()
            case "--columns": columns = rest.popFirst().flatMap { Int($0) } ?? columns
            default:
                FileHandle.standardError.write(Data("unknown option \(arg)\n\(usage)\n".utf8))
                return 64
            }
        }
        guard isatty(0) == 0 else {
            FileHandle.standardError.write(Data("pipe the lines to pick from into it\n\(usage)\n".utf8))
            return 64
        }
        let lines = PickInput.parse(String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self))
        guard !lines.isEmpty else { return 1 }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let view = PluginView(layout: grid ? .grid : .list, title: prompt ?? "Pick", placeholder: prompt.map { "\($0)…" },
                              columns: columns, items: lines.map(\.item))
        picker = PickController(view: view) { index in
            guard let index, lines.indices.contains(index) else { exit(1) }
            FileHandle.standardOutput.write(Data((lines[index].line + "\n").utf8))
            exit(0)
        }
        picker?.show()
        app.run()
        return 1
    }

    private static var picker: PickController?
}

/// The panel, showing only the list to pick from.
@MainActor
final class PickController: NSObject, NSWindowDelegate {
    private let panel: LauncherPanel
    private let content: LauncherViewController
    private let view: PluginView
    private let done: (Int?) -> Void
    private var top = NSPoint.zero

    init(view: PluginView, done: @escaping (Int?) -> Void) {
        self.view = view
        self.done = done
        panel = LauncherPanel(size: LauncherViewController.size)
        content = LauncherViewController(items: { [] })
        super.init()
        let config = (try? ConfigLoader.loadOrCreate(at: EuclidPaths().configFile))?.config ?? EuclidConfig()
        content.standalone = true
        content.theme = Theme(config.appearance)
        panel.contentViewController = content
        panel.setContentSize(LauncherViewController.size)
        panel.delegate = self
        content.onClose = { [weak self] in self?.done(nil) }
        content.onPluginItem = { [weak self] entry in self?.done(entry.index) }
        content.onCopyText = { _ in } // no detail view here
        content.onPreferredSizeChange = { [weak self] size in self?.resize(to: size) }
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? .zero
        let full = LauncherViewController.size
        top = NSPoint(x: frame.midX, y: frame.minY + frame.height * 0.66 + full.height / 2)
        content.prepareForShow()
        content.present(view, pluginID: "pick", pluginName: "Pick")
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func resize(to size: NSSize) {
        panel.setFrame(NSRect(x: (top.x - size.width / 2).rounded(), y: (top.y - size.height).rounded(),
                              width: size.width, height: size.height), display: true)
    }

    func windowDidResignKey(_ notification: Notification) { done(nil) }
}
