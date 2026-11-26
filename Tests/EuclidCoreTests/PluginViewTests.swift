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

    @Test func liveViewsReloadAndRefresh() throws {
        let live = try #require(PluginResult.parse(Data(#"{"view":"list","reload":" ./list.sh ","refresh_seconds":3}"#.utf8)).view)
        #expect(live.reload == "./list.sh")
        #expect(live.refreshSeconds == 3)
        #expect(PluginResult.parse(Data(#"{"view":"list","reload":"./l.sh","refresh_seconds":0}"#.utf8)).view?.refreshSeconds == 1)
        #expect(PluginResult.parse(Data(#"{"view":"list","reload":"./l.sh","refresh_seconds":9999}"#.utf8)).view?.refreshSeconds == 3600)
        // Refreshing needs something to run; a blank reload is none.
        let plain = try #require(PluginResult.parse(Data(#"{"view":"list","reload":" ","refresh_seconds":3}"#.utf8)).view)
        #expect(plain.reload == nil)
        #expect(plain.refreshSeconds == nil)
    }

    @Test func itemActionsDecode() throws {
        let nested = (1...25).map { #"{"title":"A\#($0)","run":"./a.sh \#($0)","actions":[{"title":"deeper"}]}"# }.joined(separator: ",")
        let line = #"{"title":"PR #42","open":"https://x","actions":[\#(nested)]}"#
        let item = try #require(PluginOutput.parse(Data(line.utf8)).items.first)
        let actions = try #require(item.actions)
        #expect(actions.count == PluginItem.maxActions)
        #expect(actions.first?.run == "./a.sh 1")
        #expect(actions.allSatisfy { $0.actions == nil }) // one level only
        #expect(PluginItem(title: "x", actions: []).actions == nil)
    }

    @Test func searchViewsAndBareRows() throws {
        let view = try #require(PluginResult.parse(Data(#"{"view":"list","search":"./find.sh","refresh_seconds":30}"#.utf8)).view)
        #expect(view.search == "./find.sh")
        #expect(view.reload == nil)
        #expect(view.refreshSeconds == 30) // a search can refresh too, with what's typed
        #expect(PluginResult.parse(Data(#"{"view":"detail","search":"./find.sh"}"#.utf8)).view?.search == nil)
        // What a search prints: rows with no header.
        let rows = "{\"title\":\"one\"}\nnope\n{\"title\":\"two\"}\n"
        let r = PluginResult.parse(Data(rows.utf8), rows: true)
        #expect(r.view?.items.map(\.title) == ["one", "two"])
        #expect(r.problems == ["line 2: not a JSON object"])
        #expect(PluginResult.parse(Data(rows.utf8)).view == nil) // only when asked
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
            // 8 s, far past the 0.2 s wait: on a busy 3-core CI runner running every suite at once,
            // getting back to this test can take a few seconds on its own (a 3 s sleep was too close).
            _ = try await PluginRunner.output(of: "sleep 8; touch done", plugin: plugin, shell: "/bin/zsh", pathPrefix: nil,
                                              timeout: .milliseconds(200), keepRunning: true)
            Issue.record("should have stopped waiting")
        } catch let f as PluginRunner.Failure {
            #expect(f.stillRunning)
        }
        #expect(ContinuousClock.now - start < .seconds(6)) // didn't wait the 8 s out
        let done = dir.appendingPathComponent("done").path
        for _ in 0..<75 where !FileManager.default.fileExists(atPath: done) { try await Task.sleep(for: .milliseconds(200)) }
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
        func run(_ command: String, query: String = "", arguments: [String]? = nil, env: [String: String] = [:],
                 bin: URL? = nil) async throws -> String {
            let data = try await PluginRunner.output(of: command, plugin: plugin, query: query, arguments: arguments, shell: "/bin/zsh",
                                                     pathPrefix: bin?.path,
                                                     environment: ProcessInfo.processInfo.environment.merging(env) { $1 },
                                                     timeout: .seconds(20))
            return String(decoding: data, as: UTF8.self)
        }

        /// ↵ on `item`: its `run`, read as the panel reads it.
        func activate(_ item: PluginItem, arguments: [String]? = nil, bin: URL? = nil) async throws -> PluginResult {
            guard let run = item.run else { throw PluginRunner.Failure("\(item.title) has no run") }
            return PluginResult.parse(Data(try await self.run(run, arguments: arguments, bin: bin).utf8))
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
        try PluginGuide.writeScript(text, to: url, executable: true) // never "text file busy" on Linux
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

    @Test func killProcessListsAndKills() async throws {
        let kp = try install("kill-process")
        defer { try? FileManager.default.removeItem(at: kp.dir) }
        let entry = try #require(PluginOutput.parse(Data(try await kp.run("./items.sh").utf8)).items.first)
        let opened = try await kp.activate(entry)
        let view = try #require(opened.view)
        #expect(opened.problems.isEmpty)
        #expect(view.reload == "./list.sh")
        #expect(view.refreshSeconds == 3)
        #expect(!view.items.isEmpty)
        #expect(view.items.allSatisfy { $0.run?.hasPrefix("./kill.sh ") == true && $0.id?.hasPrefix("pid:") == true })
        #expect(!view.items.contains { ["ps", "sort", "awk"].contains($0.title) }) // not its own pipeline

        // A process that ignores ↵'s polite quit: `kill sleep` finds it, ↵ asks, ↵ again force-quits.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sh")
        sleeper.arguments = ["-c", "trap '' TERM; exec sleep 30"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        try await Task.sleep(for: .milliseconds(200)) // until it's `sleep`
        let found = PluginOutput.parse(Data(try await kp.run(#"./list.sh rows "$1""#, query: "slee").utf8)).items
        let row = try #require(found.first { $0.id == "pid:\(sleeper.processIdentifier)" })
        #expect(row.title == "sleep")
        #expect(row.subtitle?.contains("PID \(sleeper.processIdentifier)") == true)
        let asked = try await kp.activate(row)
        #expect(asked.view == nil) // effects only, so a live view reloads
        #expect(asked.effects.first?.notice == "Asked sleep to quit · ↵ again force-quits it")
        #expect(try await kp.activate(row).effects.first?.notice == "Force-quit sleep")
        try await Task.sleep(for: .milliseconds(100))
        // Not reaped yet (a zombie), and already counts as gone.
        #expect(try await kp.activate(row).effects.first?.notice == "It already quit")
        for _ in 0..<50 where sleeper.isRunning { try await Task.sleep(for: .milliseconds(50)) } // never block a test thread
        #expect(try await kp.run(#"./list.sh rows "$1""#, query: "no-such-process-name").isEmpty)
    }

    @Test func dockerContainersDrillDown() async throws {
        let dk = try install("docker")
        defer { try? FileManager.default.removeItem(at: dk.dir) }
        // A fake docker with one running and one stopped container.
        let bin = dk.dir.appendingPathComponent("bin")
        try script(bin, "docker", #"""
            #!/bin/sh
            echo "$*" >> "$(dirname "$0")/calls"
            case $1 in
              ps) printf 'exited\tbbb222\t"db"\t"postgres:16"\t"Exited (0) 2 hours ago"\n'
                  printf 'running\taaa111\t"web \\"x\\""\t"nginx:1"\t"Up 3 minutes"\n' ;;
              inspect) [ "$4" = aaa111 ] && printf 'running\t"/web"\n' || printf 'exited\t"/db"\n' ;;
              port) echo '80/tcp -> 0.0.0.0:8080'; echo '80/tcp -> [::]:8080' ;;
              logs) printf 'first\nsecond\n' ;;
              start|stop|restart) echo "$2" ;;
            esac
            """#)
        func open(_ command: String) async throws -> PluginResult { PluginResult.parse(Data(try await dk.run(command, bin: bin).utf8)) }

        let list = try #require(try await open("./containers.sh").view)
        #expect(list.reload == "./containers.sh")
        #expect(list.items.map(\.title) == [#"web "x""#, "db"]) // running first
        #expect(list.items.map(\.icon) == ["🟢", "⚪️"])
        #expect(list.items.first?.subtitle == "nginx:1 · Up 3 minutes")

        let web = try #require(try await open("./container.sh aaa111").view)
        #expect(web.title == "web")
        #expect(web.items.map(\.title) == ["Logs", "Open Shell", "Open localhost:8080", "Restart", "Stop", "Copy ID"])
        #expect(web.items[2].open == "http://localhost:8080")
        let db = try #require(try await open("./container.sh bbb222").view)
        #expect(db.items.map(\.title) == ["Start", "Logs", "Copy ID"])

        let logs = try #require(try await open("./logs.sh aaa111").view)
        #expect(logs.layout == .detail)
        #expect(logs.text == "second\nfirst") // newest first
        #expect(logs.refreshSeconds == 2)

        #expect(try await open("./act.sh start bbb222").effects.first?.notice == "Started")
        #expect(try await open("./act.sh stop aaa111").effects.first?.notice == "Stopping…")
        // Ids go into commands, so only hex is accepted.
        await #expect(throws: PluginRunner.Failure.self) { _ = try await dk.run("./container.sh 'a;b'", bin: bin) }

        // Docker not running: one clear line.
        let down = dk.dir.appendingPathComponent("down")
        try script(down, "docker", "#!/bin/sh\necho 'Cannot connect to the Docker daemon' >&2\nexit 1\n")
        do {
            _ = try await dk.run("./containers.sh", bin: down)
            Issue.record("expected a failure")
        } catch let failure as PluginRunner.Failure {
            #expect(failure.description.contains("Docker isn't running: Cannot connect to the Docker daemon"))
        }
    }

    /// The `herdr` example against a fake `herdr` through the real `jq`: who needs you first, ↵ focuses.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/jq")))
    func herdrAgentsNeedYouFirst() async throws {
        let hd = try install("herdr", settings: ["app": ""])
        defer { try? FileManager.default.removeItem(at: hd.dir) }
        let bin = hd.dir.appendingPathComponent("bin")
        try script(bin, "herdr", #"""
            #!/bin/sh
            echo "$*" >> "$(dirname "$0")/calls"
            case "$1 $2" in
              "agent list") cat <<'JSON'
            {"result":{"type":"agent_list","agents":[
              {"pane_id":"w1:p1","name":"claude","agent_status":"working","foreground_cwd":"/tmp/api"},
              {"pane_id":"w1:p2","name":"codex","agent_status":"blocked","foreground_cwd":"/tmp/web"},
              {"pane_id":"w2:p1","name":"pi","agent_status":"done","terminal_title":"pi: fix tests"},
              {"pane_id":"w2:p2","agent_status":"idle"}]}}
            JSON
              ;;
              "agent focus") ;;
              "agent explain") echo "matched approval prompt" ;;
            esac
            """#)
        func open(_ command: String) async throws -> PluginResult { PluginResult.parse(Data(try await hd.run(command, bin: bin).utf8)) }

        let rows = PluginOutput.parse(Data(try await hd.run("./items.sh", bin: bin).utf8)).items
        #expect(rows.first?.title == "Herdr Agents")
        #expect(rows.first?.subtitle == "1 needs you · 1 working · 1 done")
        #expect(rows.dropFirst().map(\.title) == ["codex", "pi", "claude", "w2:p2"]) // blocked, done, working, idle
        #expect(rows[1].icon == "🔴")
        #expect(rows[1].subtitle == "needs you · /tmp/web")
        #expect(rows[1].run == "./focus.sh w1:p2")
        #expect(rows[1].actions?.map(\.title) == ["Jump to Pane", "Why This Status?", "Copy Pane ID"])
        #expect(rows.filter { $0.suggest == true }.map(\.title) == ["codex"]) // only who needs you, on the empty bar

        let list = try #require(try await open("./agents.sh").view)
        #expect(list.reload == "./agents.sh")
        #expect(list.refreshSeconds == 2)
        #expect(list.items.map(\.id) == ["herdr:w1:p2", "herdr:w2:p1", "herdr:w1:p1", "herdr:w2:p2"])

        #expect(try await hd.run("./badge.sh", bin: bin).trimmingCharacters(in: .whitespacesAndNewlines)
                == "1 needs you · 1 working · 1 done")
        _ = try await hd.run("./focus.sh next", bin: bin) // the blocked one
        _ = try await hd.run("./focus.sh w2:p1", bin: bin)
        let calls = try String(contentsOf: bin.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls.contains("agent focus w1:p2\n"))
        #expect(calls.contains("agent focus w2:p1\n"))
        let why = try #require(try await open("./explain.sh w1:p2").view)
        #expect(why.text == "matched approval prompt")
        // Ids go into commands, so only plain ids are accepted.
        await #expect(throws: PluginRunner.Failure.self) { _ = try await hd.run("./focus.sh 'a;b'", bin: bin) }

        // herdr not running: the badge hides, the list says why.
        let down = hd.dir.appendingPathComponent("down")
        try script(down, "herdr", "#!/bin/sh\necho 'no herdr server' >&2\nexit 1\n")
        #expect(try await hd.run("./badge.sh", bin: down).isEmpty)
        do {
            _ = try await hd.run("./agents.sh", bin: down)
            Issue.record("expected a failure")
        } catch let failure as PluginRunner.Failure {
            #expect(failure.description.contains("herdr isn't running: no herdr server"))
        }
    }

    /// The herdr badge notifies once per agent that starts waiting on you, never on its first check.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/jq")))
    func herdrNotifiesWhenAnAgentNeedsYou() async throws {
        let hd = try install("herdr", settings: ["app": ""])
        defer { try? FileManager.default.removeItem(at: hd.dir) }
        let bin = hd.dir.appendingPathComponent("bin")
        try script(bin, "herdr", "#!/bin/sh\ncat \"$(dirname \"$0\")/agents.json\"\n")
        // A fake terminal-notifier, first on PATH: a real one (CI runners have it) never runs.
        try script(bin, "terminal-notifier", """
            #!/bin/sh
            printf '%s\\n' "$@" > "$(dirname "$0")/clicked"
            echo "$4" >> "$(dirname "$0")/notified"
            """)
        func agents(_ list: [(String, String, String)]) throws {
            let rows = list.map { #"{"pane_id":"\#($0.0)","name":"\#($0.1)","agent_status":"\#($0.2)"}"# }
            try #"{"result":{"agents":[\#(rows.joined(separator: ","))]}}"#
                .write(to: bin.appendingPathComponent("agents.json"), atomically: true, encoding: .utf8)
        }
        func notified() -> [String] {
            ((try? String(contentsOf: bin.appendingPathComponent("notified"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        try agents([("w1:p1", "claude", "blocked")])
        #expect(try await hd.run("./badge.sh", bin: bin) == "1 needs you\n")
        #expect(notified().isEmpty) // the first check only takes note
        try agents([("w1:p1", "claude", "blocked"), ("w1:p2", "codex", "blocked")])
        _ = try await hd.run("./badge.sh", bin: bin)
        #expect(notified() == ["codex needs you"])
        _ = try await hd.run("./badge.sh", bin: bin)
        #expect(notified() == ["codex needs you"]) // once
        try agents([("w1:p1", "claude", "working"), ("w1:p2", "codex", "blocked")])
        _ = try await hd.run("./badge.sh", bin: bin)
        try agents([("w1:p1", "claude", "blocked"), ("w1:p2", "codex", "blocked")])
        _ = try await hd.run("./badge.sh", bin: bin)
        #expect(notified() == ["codex needs you", "claude needs you"]) // blocked again after working

        // A click runs `herdr agent focus` on that agent, then brings the app forward.
        let clicky = try install("herdr", settings: ["app": "Ghostty"])
        defer { try? FileManager.default.removeItem(at: clicky.dir) }
        _ = try await clicky.run("./badge.sh", bin: bin)
        try agents([("w1:p1", "claude", "blocked"), ("w1:p2", "codex", "blocked"), ("w9:p1", "pi", "blocked")])
        _ = try await clicky.run("./badge.sh", bin: bin)
        let clicked = try String(contentsOf: bin.appendingPathComponent("clicked"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(clicked == ["-title", "Herdr", "-message", "pi needs you", "-group", "herdr-w9:p1", "-execute",
                            "'\(bin.path)/herdr' agent focus 'w9:p1' && open -a 'Ghostty'"])
        #expect(notified() == ["codex needs you", "claude needs you", "pi needs you"])

        let quiet = try install("herdr", settings: ["app": "", "notify": "false"])
        defer { try? FileManager.default.removeItem(at: quiet.dir) }
        _ = try await quiet.run("./badge.sh", bin: bin)
        try agents([("w1:p3", "pi", "blocked")])
        _ = try await quiet.run("./badge.sh", bin: bin)
        #expect(notified().count == 3)
    }

    /// The `handoff` mod: ⇧⌘A hands the selected result to the agent CLI, in its folder, as text only.
    @Test func handoffGivesTheAgentTheResult() async throws {
        let ho = try install("handoff", settings: ["terminal": #"printf %s\n"#]) // the "terminal" prints what it would run
        defer { try? FileManager.default.removeItem(at: ho.dir) }
        let key = try #require(ho.plugin.keys.first)
        #expect(key.name == "Hand off to agent")
        let bin = ho.dir.appendingPathComponent("bin")
        try script(bin, "claude", "#!/bin/sh\nexit 0\n")
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        func handoff(_ item: [String: String], with mod: Installed? = nil) async throws -> [String] {
            try await (mod ?? ho).run(key.run, env: item, bin: bin).components(separatedBy: "\n")
        }

        // A PR: the agent starts in your home folder and is told the title, details, link and text.
        let pr = try await handoff(["EUCLID_ITEM_KIND": "github", "EUCLID_ITEM_TITLE": "Fix login on Safari",
                                    "EUCLID_ITEM_SUBTITLE": "acme/web · #412", "EUCLID_ITEM_URL": "https://github.com/acme/web/pull/412",
                                    "EUCLID_ITEM_TEXT": "Reviewers: $(whoami)"])
        #expect(Array(pr.prefix(2)) == ["sh", "-c"])
        #expect(Array(pr[3...5]) == ["sh", home, "claude"])
        let prompt = pr[6...].joined(separator: "\n")
        #expect(prompt.hasPrefix("Here is something I'm looking at in my launcher."))
        #expect(prompt.contains("\nKind: github\nTitle: Fix login on Safari\nDetails: acme/web · #412\nLink: https://github.com/acme/web/pull/412\n"))
        #expect(prompt.contains("\nReviewers: $(whoami)")) // passed as text, never run

        // A project starts in its own folder; a file in the folder it's in.
        let project = try await handoff(["EUCLID_ITEM_KIND": "project", "EUCLID_ITEM_TITLE": "plugin", "EUCLID_ITEM_PATH": ho.dir.path])
        #expect(project[4] == ho.dir.path)
        let file = try await handoff(["EUCLID_ITEM_KIND": "file", "EUCLID_ITEM_TITLE": "handoff.sh",
                                      "EUCLID_ITEM_PATH": ho.dir.appendingPathComponent("plugins/handoff/handoff.sh").path])
        #expect(file[4] == ho.dir.appendingPathComponent("plugins/handoff").path)

        // gemini wants -i for a chat; anything else is refused rather than run.
        try script(bin, "gemini", "#!/bin/sh\nexit 0\n")
        let gemini = try install("handoff", settings: ["terminal": #"printf %s\n"#, "cli": "gemini"])
        let other = try install("handoff", settings: ["terminal": #"printf %s\n"#, "cli": "rm -rf"])
        defer { for m in [gemini, other] { try? FileManager.default.removeItem(at: m.dir) } }
        let gem = try await handoff(["EUCLID_ITEM_TITLE": "x"], with: gemini)
        #expect(Array(gem[5...6]) == ["gemini", "-i"])
        await #expect(throws: PluginRunner.Failure.self) { _ = try await handoff(["EUCLID_ITEM_TITLE": "x"], with: other) }
        await #expect(throws: PluginRunner.Failure.self) { _ = try await handoff([:]) } // nothing selected
    }

    /// The `claude-sessions` example over a fake ~/.claude: titled rows, newest first, ↵ resumes in its folder.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/jq")))
    func claudeSessionsListAndResume() async throws {
        let cs = try install("claude-sessions")
        defer { try? FileManager.default.removeItem(at: cs.dir) }
        let home = cs.dir.appendingPathComponent("claude")
        let project = home.appendingPathComponent("projects/-code-api")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let older = "11111111-aaaa-bbbb-cccc-000000000001", newer = "22222222-aaaa-bbbb-cccc-000000000002"
        try """
            {"type":"user","cwd":"\(cs.dir.path)","gitBranch":"main","message":{"role":"user","content":"fix the login bug"}}
            {"type":"ai-title","aiTitle":"Fix login on Safari"}
            {"type":"user","message":{"content":"a line that mentions \\"type\\":\\"ai-title\\" in passing"}}
            """.write(to: project.appendingPathComponent("\(older).jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)],
                                              ofItemAtPath: project.appendingPathComponent("\(older).jsonl").path)
        try """
            {"type":"user","cwd":"/no/such/folder","gitBranch":"HEAD","message":{"content":[]}}
            {"type":"last-prompt","lastPrompt":"why is   CI red"}
            """.write(to: project.appendingPathComponent("\(newer).jsonl"), atomically: true, encoding: .utf8)
        try "not a session".write(to: project.appendingPathComponent("notes.jsonl"), atomically: true, encoding: .utf8)

        let env = ["CLAUDE_CONFIG_DIR": home.path]
        let rows = PluginOutput.parse(Data(try await cs.run("./items.sh", env: env).utf8)).items
        #expect(rows.map(\.title) == ["why is CI red", "Fix login on Safari"]) // newest first; no title → last prompt
        #expect(rows.map(\.id) == ["claude:\(newer)", "claude:\(older)"])
        #expect(rows[0].subtitle == "/no/such/folder · just now")            // HEAD isn't a branch
        #expect(rows[1].subtitle?.hasSuffix(" · main · 2 h ago") == true)
        #expect(rows[1].run == "./resume.sh \(older)")
        #expect(rows[1].actions?.map(\.title) == ["Resume in Terminal", "Copy Session ID", "Open Folder"])

        // ↵ hands the terminal the folder and id as arguments.
        let bin = cs.dir.appendingPathComponent("bin")
        try script(bin, "term", "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$(dirname \"$0\")/args\"\n")
        let resume = try install("claude-sessions", settings: ["terminal": bin.appendingPathComponent("term").path])
        defer { try? FileManager.default.removeItem(at: resume.dir) }
        _ = try await resume.run("./resume.sh \(older)", env: env)
        let args = try String(contentsOf: bin.appendingPathComponent("args"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args.suffix(4) == ["sh", cs.dir.path, "claude", older])
        _ = try await resume.run("./resume.sh \(newer)", env: env)  // its folder is gone: home instead
        let args2 = try String(contentsOf: bin.appendingPathComponent("args"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args2.suffix(3).first == ProcessInfo.processInfo.environment["HOME"])
        // Ids go into commands, so only UUID characters are accepted.
        await #expect(throws: PluginRunner.Failure.self) { _ = try await resume.run("./resume.sh 'a;b'", env: env) }
        await #expect(throws: PluginRunner.Failure.self) { _ = try await resume.run("./resume.sh 0000", env: env) }
    }

    /// The `github` example against a fake `gh` that answers with canned JSON through the real `jq`.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/jq")))
    func githubActionsAndSearch() async throws {
        let gh = try install("github")
        defer { try? FileManager.default.removeItem(at: gh.dir) }
        let bin = gh.dir.appendingPathComponent("bin")
        try script(bin, "gh", #"""
            #!/bin/sh
            echo "$*" >> "$(dirname "$0")/calls"
            [ "$1" = search ] || exit 0
            while [ $# -gt 0 ]; do [ "$1" = --jq ] && filter=$2; [ "$1" = -- ] && words=$2; shift; done
            printf '[{"number":42,"title":"Fix login","url":"https://github.com/acme/web/pull/42","repository":{"nameWithOwner":"acme/web"},"isPullRequest":true,"state":"open"},{"number":7,"title":"Crash","url":"https://github.com/acme/web/issues/7","repository":{"nameWithOwner":"acme/web"},"isPullRequest":false,"state":"open"}]' |
              jq -r "$filter"
            """#)
        
        let rows = PluginOutput.parse(Data(try await gh.run("./items.sh", bin: bin).utf8)).items
        #expect(rows.first?.run == "./search.sh open")
        let pr = try #require(rows.dropFirst().first)
        #expect(pr.actions?.map(\.title) == ["Copy URL", "Approve", "Comment…"])
        #expect(pr.actions?[1].run == "./search.sh approve 'https://github.com/acme/web/pull/42'")
        #expect(pr.actions?[2].fields.count == 1)

        let opened = try await gh.activate(try #require(rows.first), bin: bin)
        let view = try #require(opened.view)
        #expect(view.search == "./search.sh rows")
        #expect(view.items.map(\.title) == ["Fix login", "Crash"])
        #expect(view.items.last?.actions?.map(\.title) == ["Copy URL", "Comment…"]) // no Approve on an issue

        // What the view runs as you type: `./search.sh rows "$@"`, rows only.
        let found = PluginResult.parse(Data(try await gh.run("./search.sh rows", arguments: ["login bug"], bin: bin).utf8), rows: true)
        #expect(found.view?.items.count == 2)
        let calls = try String(contentsOf: bin.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls.contains("-- login bug"))
        #expect(calls.contains("-- involves:@me is:open")) // before you type

        // An action with an argument: the comment is passed as text.
        let comment = try #require(pr.actions?[2])
        let done = try await gh.activate(comment, arguments: ["LGTM $(whoami)"], bin: bin)
        #expect(done.effects.first?.notice == "Commented")
        let after = try String(contentsOf: bin.appendingPathComponent("calls"), encoding: .utf8)
        #expect(after.contains("issue comment https://github.com/acme/web/pull/42 --body LGTM $(whoami)"))
    }
}
