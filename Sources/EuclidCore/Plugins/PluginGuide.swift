import Foundation

/// The plugin guide Euclid keeps at `<config>/plugins/AGENTS.md`, written for people and
/// for coding agents ("make me a plugin that…"), plus the example plugins `--plugin add` installs.
public enum PluginGuide {
    static let marker = "<!-- Written by Euclid; it's replaced on update. Put your own notes in another file. -->"

    /// Write `AGENTS.md` into the plugins folder unless you replaced it with your own.
    public static func install(in pluginsDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let url = pluginsDirectory.appendingPathComponent("AGENTS.md")
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            guard existing.hasPrefix(marker), existing != guide else { return } // yours, or current
        }
        try guide.write(to: url, atomically: true, encoding: .utf8)
    }

    /// An example plugin's files, by name: `euclid-bar --plugin add github`.
    public static let examples: [String: [(name: String, text: String, executable: Bool)]] = [
        "github": [("plugin.toml", githubManifest, false), ("items.sh", githubScript, true)],
        "linear": [("plugin.toml", linearManifest, false), ("items.sh", linearScript, true)],
        "slack": [("plugin.toml", slackManifest, false), ("channels.sh", slackChannels, true), ("search.sh", slackSearch, true)],
        "tokens": [("plugin.toml", tokensManifest, false), ("today.sh", tokensScript, true)],
    ]

    /// Write an example into `<plugins>/<name>`. Fails if that folder already exists.
    public static func installExample(_ name: String, in pluginsDirectory: URL) throws -> URL {
        guard let files = examples[name] else {
            throw PluginRunner.Failure("no example plugin named '\(name)' (try: \(examples.keys.sorted().joined(separator: ", ")))")
        }
        let folder = pluginsDirectory.appendingPathComponent(name)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { throw PluginRunner.Failure("\(folder.path) already exists") }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            let url = folder.appendingPathComponent(file.name)
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            if file.executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        return folder
    }

    static let githubManifest = #"""
name = "GitHub"
description = "Your open PRs, PRs waiting on your review, and issues assigned to you. Uses the GitHub CLI: brew install gh && gh auth login"

[source]
run = "./items.sh"
refresh_minutes = 5

[[action]]
name = "Search GitHub code"
run  = 'open "https://github.com/search?type=code&q=$EUCLID_QUERY_URL"'

[settings]
limit = 30          # per list; override in config.toml with [plugin.github] limit = 50
"""#

    static let githubScript = #"""
#!/bin/sh
# Prints one JSON object per line for Euclid. `gh` does the auth and the JSON (--jq).
set -eu
command -v gh >/dev/null 2>&1 || { echo "needs the GitHub CLI: brew install gh && gh auth login" >&2; exit 1; }
limit=${EUCLID_SETTING_LIMIT:-30}
row='{title, subtitle: "\(.repository.nameWithOwner) · #\(.number)", open: .url, id: .url, icon: "arrow.triangle.pull"}'

gh search prs --review-requested=@me --state=open --limit "$limit" --json number,title,url,repository \
  --jq ".[] | $row + {label: \"Review\", suggest: true} | tojson"
gh search prs --author=@me --state=open --limit "$limit" --json number,title,url,repository \
  --jq ".[] | $row + {label: \"Your PR\"} | tojson"
gh search issues --assignee=@me --state=open --limit "$limit" --json number,title,url,repository \
  --jq ".[] | $row + {label: \"Issue\", icon: \"smallcircle.filled.circle\"} | tojson"
"""#

    static let linearManifest = #"""
name = "Linear"
description = "Linear issues assigned to you. Store a personal API key (Linear › Settings › Security & access) in the Keychain: security add-generic-password -s euclid-linear -a \"$USER\" -w '<key>'"

[source]
run = "./items.sh"
refresh_minutes = 5

[settings]
token_command = "security find-generic-password -s euclid-linear -w"
limit = 50
"""#

    static let linearScript = #"""
#!/bin/sh
# Linear issues assigned to you and not done. ↵ opens the issue, ⌘C copies its ID (ENG-123).
set -eu
command -v jq >/dev/null 2>&1 || { echo "needs jq: brew install jq" >&2; exit 1; }
key=$(eval "$EUCLID_SETTING_TOKEN_COMMAND" 2>/dev/null) || key=""
[ -n "$key" ] || { echo "no Linear API key: security add-generic-password -s euclid-linear -a \"$USER\" -w '<key>'" >&2; exit 1; }
query='query($n: Int) { viewer { assignedIssues(first: $n, orderBy: updatedAt,
  filter: { state: { type: { nin: ["completed", "canceled"] } } }) {
  nodes { identifier title url state { name } team { key } } } } }'
jq -n --arg q "$query" --argjson n "${EUCLID_SETTING_LIMIT:-50}" '{query: $q, variables: {n: $n}}' |
  curl -fsS https://api.linear.app/graphql -H "Authorization: $key" -H 'Content-Type: application/json' --data @- |
  jq -c 'if .errors then error(.errors[0].message) else .data.viewer.assignedIssues.nodes[] end
         | {title, subtitle: "\(.identifier) · \(.state.name)", open: .url, id: .url, copy: .identifier,
            label: .team.key, icon: "checklist"}'
"""#

    static let slackManifest = #"""
name = "Slack"
description = "Jump to your Slack channels, and search messages with `slack <words>`. Needs a user token (xoxp-) with channels:read, groups:read and search:read, in the Keychain: security add-generic-password -s euclid-slack -a \"$USER\" -w '<token>'"

[source]
run = "./channels.sh"
refresh_minutes = 60

[answer]
run    = "./search.sh"
prefix = "slack"

[settings]
token_command = "security find-generic-password -s euclid-slack -w"
"""#

    static let slackChannels = #"""
#!/bin/sh
# Channels you're in; ↵ opens them in the Slack app.
set -eu
command -v jq >/dev/null 2>&1 || { echo "needs jq: brew install jq" >&2; exit 1; }
token=$(eval "$EUCLID_SETTING_TOKEN_COMMAND" 2>/dev/null) || token=""
[ -n "$token" ] || { echo "no Slack token: security add-generic-password -s euclid-slack -a \"$USER\" -w '<xoxp-token>'" >&2; exit 1; }
api() { curl -fsS -H "Authorization: Bearer $token" "https://slack.com/api/$1"; }
team=$(api auth.test | jq -r 'if .ok then .team_id else error(.error) end')
api "users.conversations?types=public_channel,private_channel&exclude_archived=true&limit=1000" |
  jq -c --arg team "$team" 'if .ok then .channels[] else error(.error) end
         | {title: "#\(.name)", subtitle: (.purpose.value // ""), open: "slack://channel?team=\($team)&id=\(.id)",
            id: .id, icon: (if .is_private then "lock" else "number" end)}'
"""#

    static let slackSearch = #"""
#!/bin/sh
# `slack deploy failed`: the 10 best matching messages; ↵ opens the message.
set -eu
token=$(eval "$EUCLID_SETTING_TOKEN_COMMAND" 2>/dev/null) || token=""
[ -n "$token" ] || { echo "no Slack token (see plugin.toml)" >&2; exit 1; }
q=$(jq -rn --arg q "$1" '$q | @uri')
curl -fsS -H "Authorization: Bearer $token" "https://slack.com/api/search.messages?count=10&query=$q" |
  jq -c 'if .ok then .messages.matches[] else error(.error) end
         | {title: (.text | gsub("\\s+"; " ") | .[0:140]), subtitle: "#\(.channel.name) · \(.username // "")",
            open: .permalink, id: .permalink, icon: "bubble.left", preview: .text}'
"""#

    static let tokensManifest = #"""
name = "Claude tokens"
description = "Today's Claude Code token use and cost on the bar, from ccusage. Click it for the full report."

[badge]
run   = "./today.sh"
icon  = "gauge.with.dots.needle.33percent"
refresh_minutes = 5
click = 'ghostty-run tab npx -y ccusage@latest daily'
"""#

    static let tokensScript = #"""
#!/bin/sh
# Prints today's Claude Code usage for the badge, e.g. "1.2M tok · $4.10". Needs Node (npx) and jq.
set -eu
command -v jq >/dev/null 2>&1 || { echo "needs jq: brew install jq" >&2; exit 1; }
if command -v ccusage >/dev/null 2>&1; then set -- ccusage; else set -- npx -y ccusage@latest; fi
"$@" daily --since "$(date +%Y%m%d)" --json |
  jq -r '[.totals.totalTokens // 0, .totals.totalCost // 0] | @tsv' |
  awk -F '\t' '{ t = $1 + 0
                 s = t >= 1e6 ? sprintf("%.1fM", t / 1e6) : t >= 1e3 ? sprintf("%.0fk", t / 1e3) : t
                 printf "%s tok · $%.2f\n", s, $2 }'
"""#

    public static let guide = marker + "\n" + #"""
# Euclid plugins

A plugin is a folder here with a `plugin.toml` and the scripts it runs. Euclid reloads it when
you save, so write it, try it, and it's live. This file is the whole format.

## Make one (people and coding agents)

1. Make a folder: `~/.config/euclid/plugins/<id>/` (lowercase, no spaces; the id is the folder name).
2. Write `plugin.toml` and a script (any language; make it executable with `chmod +x`).
3. Try it: `/Applications/euclid-bar.app/Contents/MacOS/euclid-bar --try-plugin <id> [query]`.
   It runs every part once and prints the rows, the badge text or the exact error. Fix and repeat.
4. It's already live: open Euclid (⌥Space). Problems show in the footer and in `--check-config`.

## plugin.toml

```toml
name = "GitHub"                    # shown as the section title
description = "What it does, one line"

[source]                           # items in search, refreshed in the background
run = "./items.sh"                 # runs in this folder, in your login shell
refresh_minutes = 5                # 1–1440, default 10

[answer]                           # replies to what you type, below the instant results
run    = "./tz.sh"                 # gets the text as $1 (and $EUCLID_QUERY)
prefix = "tz"                      # `tz 3pm` runs it with "3pm"
match  = '^\d+(am|pm)$'            # and/or: runs on the whole query when it matches
                                   # one of the two is required; 2 s limit

[badge]                            # a short status chip on the search bar
run   = "./today.sh"               # first line of output, up to 40 characters; empty = hidden
icon  = "gauge"                    # optional SF Symbol name
refresh_minutes = 5                # default 5
click = 'ghostty-run tab ccusage'  # optional: runs when you click the badge

[[action]]                         # added to ⌘K, after your own actions
name = "Search GitHub code"
run  = 'open "https://github.com/search?type=code&q=$EUCLID_QUERY_URL"'

[settings]                         # defaults; users override in config.toml: [plugin.<id>]
limit = 30                         # scripts get $EUCLID_SETTING_LIMIT
```

Every part is optional, but a plugin needs at least one of `[source]`, `[answer]`, `[badge]`
or `[[action]]`.

## What scripts print

One JSON object per line (or a single JSON array). Only `title` is required.

```json
{"title":"Fix login on Safari","subtitle":"acme/web · #412","open":"https://github.com/acme/web/pull/412","label":"Review","suggest":true}
```

| Field | Meaning |
|---|---|
| `title` | The row's text (searched) |
| `subtitle` | Second line (searched) |
| `open` | `↵` opens this URL or file path |
| `paste` | `↵` pastes this text into the app you were in |
| `copy` | `↵` copies this text (and `⌘C` copies it) |
| `run` | `↵` runs this shell command in the plugin folder |
| `icon` | SF Symbol name, e.g. `arrow.triangle.pull` |
| `label` | Shown on the right; default: the plugin's name |
| `preview` | Text for the preview pane (`→`) |
| `id` | Stable identity, so Euclid learns what you pick; default: `open`, then `title` |
| `suggest` | `true` = also shown when the search box is empty (3 per plugin) |

`↵` does the first of `open`, `paste`, `copy`, `run` that is set. All fields are strings except
`suggest`. Print errors to stderr and exit non-zero: Euclid shows the first stderr line.

## What scripts get

- Working directory: the plugin folder. `$EUCLID_PLUGIN_DIR` is its path.
- `$1` and `$EUCLID_QUERY`: the text (answers and actions); `$EUCLID_QUERY_URL`: URL-encoded.
- `$EUCLID_SETTING_<KEY>` for each setting, uppercased.
- `~/.config/euclid/bin` first on PATH: `ghostty-run tab|split|window <cmd>` and
  `herdr-run tab|split <cmd>` open a terminal running a command.
- `[env]` from config.toml. Scripts run in a login shell, so Homebrew tools are on PATH.

The text you type is only ever passed as `$1` and environment variables, never pasted into a
command, so quote it: `"$1"`.

## Rules of thumb

- Keep sources fast and quiet: they run in the background with a 30 s limit, answers with 2 s.
- Put secrets in the Keychain and read them in the script:
  `security find-generic-password -s my-service -w`. Never in plugin.toml.
- At most 2,000 items per source.
- A team can share plugins from a repo: `[plugins] paths = ["~/work/team/euclid-plugins"]`.
- Turn one off without deleting it: `[plugins] disabled = ["<id>"]`.

## Examples

`euclid-bar --plugin add <name>` writes a working example into this folder. Read them, copy them,
change them:

- `github`: your PRs, review requests and issues, through the `gh` CLI (a source).
- `linear`: Linear issues assigned to you, through the GraphQL API (a source, key in the Keychain).
- `slack`: jump to channels, and `slack <words>` searches messages (a source and an answer).
- `tokens`: today's Claude Code tokens and cost on the bar, through `ccusage` (a badge).
"""#
}
