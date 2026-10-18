<div align="center">

<img src="Resources/AppIcon.png" width="128" alt="Euclid icon">

# Meet Euclid

**Your blazing fast, fully customisable search-anything companion for macOS.**<br>
Built for developers who live in the terminal.

[**Download for macOS**](https://github.com/stellalie/euclid-bar/releases/latest) · [Recipes](#recipes) · [Config](#configuration) · [Build from source](#build-from-source)

![Euclid demo](docs/demo.gif)

<sub>Rendered from the real app UI with `make demo` · [MP4](docs/demo.mp4)</sub>

</div>

---

Press **`⌥Space`**. Type three letters. That command you copied an hour ago, the docs page you read
yesterday, the question you want to throw at your AI agent: it's all one keystroke away. Then Euclid
gets out of your way.

## Why Euclid

- ⚡ **Blazing fast.** Native Swift + AppKit, no Electron, no web views. Searches **10,000 items in under
  a millisecond**, opens in ~20 ms, idles at ~0% CPU and ~30 MB of RAM.
- 🔎 **Search anything.** **Apps**, your **git projects**, **files** (via Spotlight), **clipboard
  history** and **browser history** (Dia, Arc, Chrome, Brave, Edge, Vivaldi, Safari) in one
  fuzzy-matched list, plus an inline **calculator** (`12 * 3.5`, `1.5 gb in mb`, `72 f in c`).
- 🧠 **Learns what you mean.** The result you pick for what you type ranks first next time. Give
  anything a short **alias** (`gh swift testing` searches GitHub) and pin **favorites** to the empty box.
- 🧩 **Fully customisable.** Every action is **one shell command** in a TOML file. If it runs in your
  terminal, it's an Euclid action. No extension SDK, no marketplace, no JavaScript.
- 🛠️ **Built for developers.** Dotfiles-friendly config in `~/.config/euclid`, live reload on save,
  `--check-config` for CI, and first-class **Ghostty** and **herdr** integration for sending prompts to
  `pi`, `claude`, or any agent in a new tab or split.
- 🔒 **Private by design.** Everything stays on your Mac. Copies from password managers are never
  recorded. Browser history is read locally, read-only.

## How it works

| Key | What happens |
|---|---|
| `⌥Space` | Summon Euclid over any app (configurable) |
| *type* | Fuzzy-search apps, projects, files, clipboard and browser history, instantly |
| `↵` | Open the app, project or file · paste the clip into the previous app · open the page · run the action · copy the answer |
| `⌘↵` | Run your **#1 action** on what you typed |
| `⌘1`–`⌘9` | Run action N |
| `⌘K` | Action palette: `↑↓` `↵`, `1`–`9`, type to filter |
| `→` / `⌘Y` | Preview the selection (full text, image, Quick Look) |
| `⌘C` / `⌘⌫` | Copy / delete the selected clip (`⌘C` on a page copies its URL, on an app, project or file its path) |

Nothing matches? Your actions show up instead, so a question is always one `↵` away from your AI agent.

## Recipes

Actions live in `~/.config/euclid/config.toml`, in order (first = `⌘1` and `⌘↵`). Your query arrives
as `$1` (`$EUCLID_QUERY_URL` is URL-encoded). It's passed as an argument and never pasted into the
command, so quotes, `$(…)` or backticks in what you type can't run anything.

```toml
[[action]]                                   # ⌘1, and ⌘↵
name = "Ask pi in a new Ghostty tab"
run  = 'ghostty-run tab pi "$1"'             # or: split, window

[[action]]                                   # ⌘2
name = "Claude in a herdr split"
run  = 'herdr-run split claude "$1"'         # or: tab, split-down

[[action]]
name = "Search GitHub code"
run  = 'open "https://github.com/search?type=code&q=$EUCLID_QUERY_URL"'

[[action]]
name = "Open repo"                           # type: stellalie/euclid-bar
run  = 'open "https://github.com/$1"'

[[action]]
name = "npm package"
run  = 'open "https://www.npmjs.com/package/$1"'

[[action]]
name = "man page in Ghostty"
run  = 'ghostty-run tab man "$1"'

[[action]]
name = "Pretty-print JSON to clipboard"
run  = 'printf %s "$1" | jq . | pbcopy'
```

`ghostty-run` and `herdr-run` are small scripts Euclid installs into `~/.config/euclid/bin` (on
`PATH` for every action). Read them, tweak them, or drop your own scripts next to them.

## Install

1. **Download** `euclid-bar-<version>-macos-universal.zip` from
   [Releases](https://github.com/stellalie/euclid-bar/releases/latest) (Apple Silicon + Intel,
   macOS 14+).
2. **Unzip** and drag `euclid-bar.app` into `/Applications`.
3. **First launch:** Euclid isn't notarized by Apple (yet), so macOS will block it the first time.
   Either run
   ```sh
   xattr -dr com.apple.quarantine /Applications/euclid-bar.app
   ```
   or open it once, then go to **System Settings › Privacy & Security** and click **Open Anyway**.
4. Press **`⌥Space`**. The 🧠 in your menu bar has *Edit Config…* and *Quit*.

**Permissions** (asked only when needed):
- **Accessibility**: for `↵` to paste into the previous app. Without it, Euclid copies instead.
- **Automation**: the first time an action drives Ghostty.
- **Full Disk Access** *(optional)*: only to include Safari history.

## Configuration

`~/.config/euclid/config.toml` is created with comments on first launch and **applies on save**. A typo
never breaks the app: the last good config stays active and the error shows in the panel footer.

```toml
hotkey = "opt+space"

[clipboard]
limit = 5000
ignore_apps = ["com.1password.1password"]     # never record copies from these apps

[history]
enabled  = true
browsers = ["dia", "safari"]                  # default: every browser found
limit    = 5000

[apps]
enabled = true                                # /Applications, /System/Applications, ~/Applications

[projects]
roots = ["~/code"]                            # git repos under these show up in search
open  = 'code "$1"'                           # how ↵ opens one ($1 = the repo's path)

[files]
enabled = true                                # Spotlight, by name, after 3+ letters
limit   = 8

[search]
favorites = ["Ghostty", "euclid-bar"]         # shown first when the box is empty

[aliases]
code = "Visual Studio Code"                   # type `code` ↵

[env]                                         # extra env vars for every action
AWS_PROFILE = "my-profile"                    # e.g. what you only export in ~/.zshrc

[appearance]
accent     = "#7c5cff"                        # selection + match highlight (default: system accent)
density    = "compact"                        # or "comfortable"
glass      = true                             # Liquid Glass on macOS 26+
show_speed = true                             # "12,431 items · 0.6 ms" in the footer

[obsidian]
vault = "~/Notes"                             # search notes by title and text

[pages]
enabled = true                                # index the text of public pages you visited (off by default)

[bitbucket]                                   # your PRs, review requests and repos
email = "you@example.com"                     # Cloud; for Data Center set base_url instead
# token_command = "security find-generic-password -s euclid-bitbucket -w"   # the default

[[snippet]]
name    = "Standup"
keyword = "standup"                           # typing it pins the snippet first
text    = "Yesterday:\nToday:\nBlockers: none ({date})"
```

Type straight into the box for quick developer answers: an epoch (`1697040000`) or ISO date,
`uuid`, `now`, `b64 text` / a base64 string, JSON (pretty + minified), `%`-encoded URLs, `#ff8800`
or `rgb(…)`, and JWTs. `↵` copies the answer.

`→` (at the end of what you typed) or `⌘Y` opens a preview: the full clip, images, Quick Look for
files, a project's README, or an indexed page's text.

Any `[[action]]` can take an `alias`: with `alias = "gh"`, typing `gh swift testing` runs it on
"swift testing".

Validate it from a terminal (great in dotfiles CI):

```sh
/Applications/euclid-bar.app/Contents/MacOS/euclid-bar --check-config
```

Clipboard history and learned ranking live in `~/Library/Application Support/Euclid`, separate from
the config, so they never end up in your dotfiles repo.

## Build from source

Requires Xcode 16+ (Swift 6) on macOS 14+. Check what your Mac will build with:

```sh
swift --version   # needs "Swift version 6" or newer
xcode-select -p   # which Xcode or Command Line Tools is active
```

If it says Swift 5, point it at a newer Xcode with `sudo xcode-select -s /Applications/Xcode.app`, or
for one build without sudo, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make run`. Every
`make` target checks this first and prints the fix.

```sh
git clone https://github.com/stellalie/euclid-bar && cd euclid-bar
make run      # build build/euclid-bar.app and launch it
make test     # unit tests
make perf     # release-mode search benchmarks
make demo     # re-render docs/demo.gif from the real UI
```

<details>
<summary>Project layout</summary>

```
Sources/EuclidCore   UI-free logic: search, clipboard store, browser history, config, actions
Sources/EuclidBar    AppKit app: hotkey, panel, menu bar, demo/icon renderers
Tests/               Swift Testing
scripts/             bundle.sh, release.sh, make-dev-cert.sh, check-toolchain.sh
```

`make cert` creates a local signing identity so macOS keeps Accessibility permission across rebuilds.
</details>

## Roadmap

- Stream an action's output into the panel (`output = "panel"`): ask `pi --print`, `↵` pastes the answer
- Meaning-based search for browser history

## License

[MIT](LICENSE) © Stella Lie
