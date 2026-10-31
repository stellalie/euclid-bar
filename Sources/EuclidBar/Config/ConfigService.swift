import Foundation
import EuclidCore
import os

/// Loads `config.toml`, watches it, and reloads on save.
/// A broken file never breaks the app: the last good config stays active
/// and the error is surfaced in the panel footer.
@MainActor
final class ConfigService {
    let paths: EuclidPaths
    private(set) var current: LoadedConfig
    /// The most recent load error, if the file is currently broken.
    private(set) var loadError: ConfigError?

    /// Called after every reload attempt (success or failure).
    var onChange: (() -> Void)?

    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    /// Files pulled in by `include`, plugins and the theme, watched like config.toml itself.
    private var includeSources: [DispatchSourceFileSystemObject] = []
    private var pendingReload: DispatchWorkItem?
    private var lastText: String?
    private let log = Logger(subsystem: "dev.euclid", category: "config")

    init(paths: EuclidPaths = EuclidPaths()) {
        self.paths = paths
        current = LoadedConfig(config: EuclidConfig(), issues: [])
        reload()
    }

    /// One line for the footer when something needs attention, else nil.
    var problemSummary: String? {
        if let loadError { return "⚠︎ \(loadError) — using last good config" }
        guard let first = current.issues.first else { return nil }
        let more = current.issues.count > 1 ? " (+\(current.issues.count - 1) more: --check-config)" : ""
        return "⚠︎ config: \(first.message)\(more)"
    }

    func startWatching() {
        // Editors usually save by writing a temp file and renaming it over the
        // original, which only shows up as a change to the *directory*. Others
        // write in place, which only shows up on the *file*. Watch both.
        dirSource = watch(paths.configDirectory.path, mask: .write)
        rewatchFile()
    }

    func reload() {
        let file = paths.configFile
        let text = snapshot()
        if text != nil, text == lastText { return } // unchanged (e.g. touch, or our own event echo)
        do {
            let previousIncludes = watchedFiles
            current = try ConfigLoader.loadOrCreate(at: file)
            loadError = nil
            lastText = snapshot()
            if fileSource != nil, watchedFiles != previousIncludes { rewatchIncludes() }
            for issue in current.issues { log.warning("\(issue.description, privacy: .public)") }
            log.notice("config loaded: \(self.current.config.actions.count) actions, \(self.current.issues.count) issues")
        } catch {
            loadError = error
            lastText = text
            log.error("\(error.description, privacy: .public)")
        }
        onChange?()
    }

    /// Everything besides config.toml that a reload reads.
    private var watchedFiles: [String] { current.includedFiles + current.pluginFiles + current.themeFiles }

    /// config.toml plus every included, plugin and theme file, to tell a real change from an event echo.
    private func snapshot() -> String? {
        guard let main = try? String(contentsOf: paths.configFile, encoding: .utf8) else { return nil }
        let included = current.includedFiles.map { (try? String(contentsOfFile: $0, encoding: .utf8)) ?? "" }
        // Plugin folders by their listing, plugin files by size and date (scripts can be big).
        let fm = FileManager.default
        let plugins = (current.pluginFiles + current.themeFiles).map { path -> String in
            if let names = try? fm.contentsOfDirectory(atPath: path) { return names.sorted().joined(separator: "/") }
            let a = try? fm.attributesOfItem(atPath: path)
            return "\(a?[.size] ?? "-"):\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
        return ([main] + included + plugins).joined(separator: "\u{0}")
    }

    /// Change one setting in config.toml itself (layout and comments kept), then reload.
    /// Returns a reason when it can't, e.g. the file doesn't parse right now.
    func set(_ key: String, to value: Bool, in table: String) -> String? {
        let file = paths.configFile
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "can't read \(file.path)" }
        guard let edited = ConfigEditor.set(key, to: value, in: table, text: text) else {
            return "couldn't set \(table).\(key) in config.toml; edit it by hand"
        }
        // In place, not atomically: a symlinked config.toml (dotfiles) stays a symlink.
        do { try edited.write(to: file, atomically: false, encoding: .utf8) } catch {
            return "can't write \(file.path): \(error.localizedDescription)"
        }
        reload()
        return nil
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.rewatchFile() // the file may have been replaced
                self?.reload()
            }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work) // coalesce editor bursts
    }

    private func rewatchFile() {
        fileSource?.cancel()
        fileSource = watch(paths.configFile.path, mask: [.write, .delete, .rename, .extend])
        rewatchIncludes()
    }

    private func rewatchIncludes() {
        includeSources.forEach { $0.cancel() }
        includeSources = watchedFiles.compactMap { watch($0, mask: [.write, .delete, .rename, .extend]) }
    }

    private func watch(_ path: String, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
