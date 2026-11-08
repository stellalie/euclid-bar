import AppKit
import EuclidCore

/// The dialogs of Change Settings with AI, shared by the app and `--render-screens`.
@MainActor
enum SettingsDialogs {
    static func alert(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        for b in buttons { alert.addButton(withTitle: b) }
        return alert
    }

    static let change = (title: "Change Settings with AI", text: """
        Copy this prompt into ChatGPT, Copilot, Claude or any AI chat. It reads Euclid's docs, \
        asks what you'd like, and gives you a new config.toml. Paste that in Edit Config… and save.
        """)

    static let fix = (title: "Fix Settings with AI", text: """
        Copy this prompt into any AI chat. It gives you a fixed config.toml: paste that in Edit Config… and save.
        """)

    /// Buttons, in order: copy (first), open the file to paste the reply in (second), close.
    static let promptButtons = ["Copy Prompt", "Edit Config…", "Close"]

    /// The prompt in a read-only, selectable monospaced box, with Copy Prompt as the default button.
    static func promptAlert(_ dialog: (title: String, text: String), _ prompt: String) -> NSAlert {
        let alert = alert(dialog.title, dialog.text + "\n\nIt includes your config.toml: if you put anything private in it, look it over first.",
                          buttons: promptButtons)
        let size = NSSize(width: 520, height: 260)
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        // Sized to the area inside the border and scroller, so lines wrap instead of running under them.
        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        text.string = prompt
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        alert.accessoryView = scroll
        return alert
    }

    // MARK: --render-screens

    /// The dialog as the app shows it, plus the prompt as text.
    static func renderFlow(to dir: URL, snapshot: (NSView) -> CGImage, write: (CGImage, String, String) throws -> Void) throws {
        let prompt = SettingsGuide.prompt(current: DefaultConfig.text)
        try prompt.write(to: dir.appendingPathComponent("settings-ai-prompt.txt"), atomically: true, encoding: .utf8)
        let alert = promptAlert(change, prompt)
        let rep = IconRenderer.image(pixels: 256) // no app bundle when rendering, so no app icon
        let icon = NSImage(size: NSSize(width: 64, height: 64))
        icon.addRepresentation(rep)
        alert.icon = icon
        alert.layout()
        guard let view = alert.window.contentView else { return }
        try write(snapshot(view), "settings-1-prompt", "Change Settings with AI…: a prompt to copy into any AI chat")
    }
}
