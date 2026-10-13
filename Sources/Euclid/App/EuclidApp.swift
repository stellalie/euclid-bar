import AppKit

@main
@MainActor
enum EuclidApp {
    // NSApplication.delegate is weak; keep a strong reference.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // no Dock icon, no menu bar takeover
        app.delegate = delegate
        app.run()
    }
}
