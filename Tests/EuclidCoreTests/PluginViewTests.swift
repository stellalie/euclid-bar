import Foundation
import Testing
@testable import EuclidCore

/// Views, typed arguments, `--pick` input, and the raycast / emoji / volume example plugins,
/// run for real in a shell.
@Suite struct PluginViewTests {
    // MARK: - What `run` prints

    @Test func effectsOnly() {
        let r = PluginResult.parse(Data("log line\n{\"notice\":\"Volume 40%\"}\n".utf8))
        #expect(r.view == nil)
        #expect(r.effects == [PluginEffect(notice: "Volume 40%")])
    }

    @Test func gridViewWithItems() throws {
        let out = """
            {"notice":"loaded"}
            {"view":"grid","title":"Emoji","placeholder":"Search emoji…","columns":8}
            {"title":"grinning face","icon":"😀","paste":"😀","copy":"😀"}
            not json
            {"title":"red heart","icon":"❤️","paste":"❤️"}
            """
        let r = PluginResult.parse(Data(out.utf8))
        let view = try #require(r.view)
        #expect(view.layout == .grid)
        #expect(view.title == "Emoji")
        #expect(view.placeholder == "Search emoji…")
        #expect(view.columns == 8)
        #expect(view.items.map(\.title) == ["grinning face", "red heart"])
        #expect(r.effects == [PluginEffect(notice: "loaded")]) // only lines before the header
        #expect(r.problems == ["line 2: not a JSON object"])
        // An item's `copy` after the header is the item's, not a copy effect.
        #expect(!r.effects.contains { $0.copy != nil })
    }

    @Test func detailViewKeepsTheTextAsIs() throws {
        let out = "{\"view\":\"detail\",\"title\":\"Weather\",\"code\":true}\n  Sydney\n{\"title\":\"not an item\"}\n\n"
        let view = try #require(PluginResult.parse(Data(out.utf8)).view)
        #expect(view.layout == .detail)
        #expect(view.code)
        #expect(view.text == "  Sydney\n{\"title\":\"not an item\"}")
        let short = try #require(PluginResult.parse(Data(#"{"view":"detail","text":"one line"}"#.utf8)).view)
        #expect(short.text == "one line")
        #expect(!short.code)
    }

    @Test func columnsAreClampedAndUnknownViewsSaySo() throws {
        #expect(PluginResult.parse(Data(#"{"view":"grid","columns":40}"#.utf8)).view?.columns == 10)
        #expect(PluginResult.parse(Data(#"{"view":"LIST"}"#.utf8)).view?.layout == .list)
        let bad = PluginResult.parse(Data(#"{"view":"form"}"#.utf8))
        #expect(bad.view == nil)
        #expect(bad.effects.first?.notice?.contains("unknown view") == true)
    }

    // MARK: - Arguments

    @Test func raycastStyleArgumentsDecode() throws {
        let line = #"""
            {"title":"Weather","run":"./w.sh","arguments":[{ "type": "text", "placeholder": "City", "percentEncoded": true },{"type":"dropdown","placeholder":"Units","optional":true,"data":[{"title":"Metric","value":"m"},{"value":"u"}]},{"type":"password"},{"type":"text"}]}
            """#
        let (items, problems) = PluginOutput.parse(Data(line.utf8))
        #expect(problems.isEmpty)
        let fields = try #require(items.first).fields
        #expect(fields.count == 3) // at most 3
        #expect(fields[0] == PluginArgument(placeholder: "City"))
        #expect(fields[1].type == .dropdown)
        #expect(fields[1].data == [.init(title: "Metric", value: "m"), .init(title: "u", value: "u")])
        #expect(fields[2].type == .password)

        #expect(fields[0].value(for: "Sydney") == "Sydney")
        #expect(fields[0].value(for: "  ") == nil) // required
        #expect(fields[1].value(for: "") == "") // optional
        #expect(fields[1].value(for: "metric") == "m")
        #expect(fields[1].value(for: "u") == "u")
        #expect(fields[1].value(for: "Kelvin") == nil)
        // Without `run` there's nothing to pass them to.
        #expect(PluginItem(title: "x", arguments: [PluginArgument()]).fields.isEmpty)
    }

    @Test func argumentsReachTheCommand() async throws {
        let plugin = Plugin(id: "t", name: "T", description: "", directory: FileManager.default.temporaryDirectory.path)
        let out = try await PluginRunner.output(of: #"printf '%s|%s|%s' "$1" "$2" "$EUCLID_ARG_2"; :"#, plugin: plugin,
                                                arguments: ["São Paulo", "it's"], shell: "/bin/zsh", pathPrefix: nil,
                                                timeout: .seconds(10))
        #expect(String(decoding: out, as: UTF8.self) == "São Paulo|it's|it's")
    }

    @Test func aLongRunKeepsGoingWithoutTheWait() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-keep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plugin = Plugin(id: "t", name: "T", description: "", directory: dir.path)
        let start = ContinuousClock.now
        do {
            _ = try await PluginRunner.output(of: "sleep 3; touch done", plugin: plugin, shell: "/bin/zsh", pathPrefix: nil,
                                              timeout: .milliseconds(200), keepRunning: true)
            Issue.record("should have stopped waiting")
        } catch let f as PluginRunner.Failure {
            #expect(f.stillRunning)
        }
        #expect(ContinuousClock.now - start < .milliseconds(2500)) // didn't wait the 3 s out
        let done = dir.appendingPathComponent("done").path
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: done) { try await Task.sleep(for: .milliseconds(200)) }
        #expect(FileManager.default.fileExists(atPath: done)) // not killed
    }

    // MARK: - --pick

    @Test func pickInput() {
        let lines = PickInput.parse("main\n\n  feature/x  \n{\"title\":\"Sydney\",\"icon\":\"🌤\"}\n{not json\n")
        #expect(lines.map(\.line) == ["main", "  feature/x  ", "{\"title\":\"Sydney\",\"icon\":\"🌤\"}", "{not json"])
        #expect(lines.map(\.item.title) == ["main", "feature/x", "Sydney", "{not json"])
        #expect(lines[2].item.icon == "🌤")
    }

    // MARK: - Example plugins

    struct Installed {
        let dir: URL
        let plugin: Plugin
        func run(_ command: String, query: String = "", arguments: [String]? = nil, env: [String: String] = [:]) async throws -> String {
            let data = try await PluginRunner.output(of: command, plugin: plugin, query: query, arguments: arguments, shell: "/bin/zsh",
                                                     pathPrefix: nil,
                                                     environment: ProcessInfo.processInfo.environment.merging(env) { $1 },
                                                     timeout: .seconds(20))
            return String(decoding: data, as: UTF8.self)
        }

        /// ↵ on `item`: its `run`, read as the panel reads it.
        func activate(_ item: PluginItem, arguments: [String]? = nil) async throws -> PluginResult {
            guard let run = item.run else { throw PluginRunner.Failure("\(item.title) has no run") }
            return PluginResult.parse(Data(try await self.run(run, arguments: arguments).utf8))
        }
    }

    func install(_ name: String, settings: [String: String] = [:]) throws -> Installed {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-ex-\(UUID().uuidString)")
        let folder = try PluginGuide.installExample(name, in: dir.appendingPathComponent("plugins"))
        var issues: [ConfigIssue] = []
        let text = try String(contentsOf: folder.appendingPathComponent("plugin.toml"), encoding: .utf8)
        var plugin = try #require(PluginLoader.parse(text, id: name, directory: folder.path, &issues))
        #expect(issues.isEmpty)
        plugin.settings.merge(settings) { $1 }
        return Installed(dir: dir, plugin: plugin)
    }

    func script(_ dir: URL, _ name: String, _ text: String) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func raycastScriptCommands() async throws {
        let scripts = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-rc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scripts) }
        try script(scripts, "weather.sh", #"""
            #!/bin/bash
            # @raycast.schemaVersion 1
            # @raycast.title Weather
            # @raycast.mode fullOutput
            # @raycast.icon 🌤
            # @raycast.packageName Web
            # @raycast.argument1 { "type": "text", "placeholder": "City", "percentEncoded": true }
            # @raycast.argument2 { "type": "dropdown", "placeholder": "Units", "optional": true, "data": [{"title": "Metric", "value": "m"}] }
            printf '\033[32mWeather for %s\033[0m (%s)\nsunny\n' "$1" "$2"
            """#)
        try script(scripts, "tools/hi.py", """
            #!/bin/sh
            # @raycast.schemaVersion 1
            # @raycast.title Say "Hi"
            # @raycast.mode compact
            # @raycast.needsConfirmation true
            # @raycast.icon images/hi.png
            echo working; echo 'Hi there'
            """)
        try script(scripts, "clock.sh", "#!/bin/sh\n# @raycast.title Clock\n# @raycast.mode inline\necho '12:34'\n")
        try script(scripts, "fail.sh", "#!/bin/sh\n# @raycast.title Fails\n# @raycast.mode silent\necho boom >&2; exit 3\n")
        try script(scripts, "quiet.sh", "#!/bin/sh\n# @raycast.title Quiet\n# @raycast.mode silent\necho done\n")
        try "# @raycast.title Not a script\n".write(to: scripts.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let rc = try install("raycast", settings: ["folders": scripts.path])
        defer { try? FileManager.default.removeItem(at: rc.dir) }

        // The source: one row per script, sorted by path; inline output is the subtitle.
        let (rows, problems) = PluginOutput.parse(Data(try await rc.run("./list.sh").utf8))
        #expect(problems.isEmpty)
        #expect(rows.map(\.title) == ["Clock", "Fails", "Quiet", "Say \"Hi\"", "Weather"])
        let clock = rows[0], hi = rows[3], weather = rows[4]
        #expect(clock.subtitle == "12:34")
        #expect(hi.icon == scripts.appendingPathComponent("tools/images/hi.png").path)
        #expect(weather.icon == "🌤")
        #expect(weather.subtitle == "Web")
        #expect(weather.fields.map(\.placeholder) == ["City", "Units"])

        // ↵ with the fields filled in: fullOutput → a detail view, colours stripped, arguments percent-encoded.
        let full = try await rc.activate(weather, arguments: ["São Paulo", "m"])
        let detail = try #require(full.view)
        #expect(detail.layout == .detail)
        #expect(detail.title == "Weather")
        #expect(detail.code)
        // macOS passes arguments decomposed (a + U+0303), Linux as typed: either encoding is right.
        #expect(["Weather for S%C3%A3o%20Paulo (m)\nsunny", "Weather for Sa%CC%83o%20Paulo (m)\nsunny"].contains(detail.text))

        // needsConfirmation: a list view asking first; its Run item runs it for real.
        let asked = try await rc.activate(hi)
        let ask = try #require(asked.view)
        #expect(ask.layout == .list)
        #expect(ask.items.map(\.title) == ["Run Say \"Hi\"", "Cancel"])
        let ran = try await rc.activate(ask.items[0])
        #expect(ran.effects == [PluginEffect(notice: "Hi there")]) // compact: the last line

        // silent: nothing on success, the error otherwise.
        let quiet = try await rc.activate(rows[2]), fails = try await rc.activate(rows[1])
        #expect(quiet.effects.isEmpty)
        #expect(fails.effects == [PluginEffect(notice: "⚠︎ Fails: boom")])

        // `rc wea Sydney metric`: the first words fill the first arguments, the last takes the rest.
        let answer = PluginOutput.parse(Data(try await rc.run("./list.sh", query: "wea Sydney New South Wales").utf8)).items
        #expect(answer.map(\.title) == ["Weather · Sydney New South Wales"])
        #expect(answer[0].fields.isEmpty) // already filled in
        let typedResult = try await rc.activate(answer[0])
        let typed = try #require(typedResult.view)
        #expect(typed.text == "Weather for Sydney (New South Wales)\nsunny")
        #expect(PluginOutput.parse(Data(try await rc.run("./list.sh", query: "say").utf8)).items.map(\.title) == ["Say \"Hi\""])
        #expect(try await rc.run("./list.sh", query: "nothing").isEmpty)
    }

    @Test func raycastWithNoScriptsSaysWhere() async throws {
        let rc = try install("raycast", settings: ["folders": "/nonexistent/euclid-rc"])
        defer { try? FileManager.default.removeItem(at: rc.dir) }
        let rows = PluginOutput.parse(Data(try await rc.run("./list.sh").utf8)).items
        #expect(rows.map(\.title) == ["No Raycast scripts yet"])
        #expect(try await rc.run("./list.sh", query: "x").isEmpty)
    }

    @Test func emojiGridAndAnswer() async throws {
        let emoji = try install("emoji")
        defer { try? FileManager.default.removeItem(at: emoji.dir) }
        let rows = PluginOutput.parse(Data(try await emoji.run("./items.sh").utf8)).items
        let row = try #require(rows.first)
        let grid = try await emoji.activate(row)
        let view = try #require(grid.view)
        #expect(grid.problems.isEmpty)
        #expect(view.layout == .grid)
        #expect(view.items.count > 1_800 && view.items.count <= PluginOutput.maxItems)
        #expect(view.items.first == PluginItem(title: "grinning face", subtitle: "face-smiling", copy: "😀", paste: "😀",
                                               icon: "😀", id: "😀"))
        let hearts = PluginOutput.parse(Data(try await emoji.run("./find.sh", query: "red heart").utf8)).items
        #expect(hearts.first?.paste == "❤️")
        #expect(PluginOutput.parse(Data(try await emoji.run("./find.sh", query: "face").utf8)).items.count == 9)
    }

    @Test func volumeRowsAndAnswer() async throws {
        let vol = try install("volume")
        defer { try? FileManager.default.removeItem(at: vol.dir) }
        let (rows, problems) = PluginOutput.parse(Data(try await vol.run("./items.sh").utf8))
        #expect(problems.isEmpty)
        #expect(rows.map(\.title) == ["Volume Up", "Volume Down", "Mute", "Unmute", "Set Volume"])
        let levels = try #require(rows.last?.fields.first)
        #expect(levels.type == .dropdown)
        #expect(levels.value(for: "50%") == "50")
        #expect(PluginOutput.parse(Data(try await vol.run("./find.sh", query: "40").utf8)).items.map(\.run) == ["./set.sh 40"])
        #expect(PluginOutput.parse(Data(try await vol.run("./find.sh", query: "mute").utf8)).items.map(\.run) == ["./set.sh mute"])
        #expect(try await vol.run("./find.sh", query: "400").isEmpty)
        #expect(try await vol.run("./find.sh", query: "loud").isEmpty)
    }
}
