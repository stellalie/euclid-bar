import AppKit
import EuclidCore

/// What was copied: text, copied files (Finder), or an image (screenshots, browsers).
enum CopiedContent {
    case text(String)
    case files([String])
    /// PNG or TIFF bytes, as the pasteboard had them.
    case image(Data)
}

/// Polls the general pasteboard's changeCount. macOS has no clipboard-change
/// notification, so this is what every clipboard manager does (Maccy included).
/// Cost per tick when nothing changed: one integer read.
@MainActor
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private let onCopy: (CopiedContent, _ app: NSRunningApplication?) -> Void
    /// `NSWorkspace.frontmostApplication` goes stale in an accessory app, so track activations ourselves.
    private var frontApp = NSWorkspace.shared.frontmostApplication
    private var activationObserver: NSObjectProtocol?

    init(onCopy: @escaping (CopiedContent, _ app: NSRunningApplication?) -> Void) {
        self.onCopy = onCopy
        self.lastChangeCount = pasteboard.changeCount // don't import what was there before launch
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontApp = app }
        }
    }

    func start(interval: TimeInterval = 0.5) {
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        t.tolerance = interval * 0.2 // lets macOS coalesce wakeups → ~0% idle CPU
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        let types = pasteboard.types?.map(\.rawValue) ?? []
        guard PasteboardFilter.shouldRecord(types: types) else { return }
        // Files first (Finder also puts their names on as text), then text, then images.
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onCopy(.files(urls.map(\.path)), frontApp)
        } else if let text = pasteboard.string(forType: .string) {
            onCopy(.text(text), frontApp)
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            onCopy(.image(data), frontApp)
        }
    }
}
