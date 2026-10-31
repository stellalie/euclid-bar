/// Written to `config.toml` on first launch. Must stay valid: a test parses it.
public enum DefaultConfig {
    public static let text = #"""
# Euclid configuration. Changes apply on save, no restart needed
# (except clipboard.limit, which applies on next launch).
# Check from a terminal: /Applications/Euclid.app/Contents/MacOS/euclid-bar --check-config

# Shared files (your team's actions, snippets, plugin settings) read underneath this one.
# Settings here win; your own actions stay first. Relative paths are next to this file.
# include = ["~/work/team-dotfiles/euclid.toml"]

# Global hotkey that opens the panel. When set here, it wins over the app.
# Modifiers: cmd, opt, ctrl, shift. Keys: a–z, 0–9, space, return, tab, f1–f12.
hotkey = "opt+space"

# What Edit Config… opens this file with. Unset = your default text editor.
# An app ("Sublime Text", "Zed", "Visual Studio Code") or a command ("subl", "code", "zed").
# editor = "Sublime Text"

[clipboard]
limit = 5000                 # entries kept
ignore_apps = []             # bundle IDs never recorded, e.g. ["com.1password.1password"]

[shell]
path = "/bin/zsh"            # actions run as a login shell (-l): ~/.zprofile loads, ~/.zshrc doesn't

# Environment for every action. Use it for variables you export in ~/.zshrc
# (interactive-only), e.g. provider settings for `pi --print` in the background:
[env]
# AWS_PROFILE = "my-profile"
# AWS_REGION  = "us-east-1"

# Browser history shows up in search next to your clipboard (↵ opens the page).
# Read locally from each browser's own history file; nothing leaves your Mac.
[history]
enabled  = true
# browsers = ["dia", "safari"]   # default: every browser found
#                                # (dia, arc, chrome, brave, edge, vivaldi, chromium, safari)
limit    = 5000                  # most recent pages kept in search

# Installed apps show up in search (↵ opens or focuses the app).
[apps]
enabled = true
# folders = ["~/Tools"]          # extra folders, on top of /Applications and friends

# Git repos under these folders show up in search (↵ runs `open` with the repo as $1).
[projects]
roots = ["~/code", "~/src", "~/dev", "~/Developer", "~/projects", "~/work"]
depth = 3                        # how deep to look for repos under each root
open  = 'open "$1"'              # e.g. 'code "$1"', 'zed "$1"', 'ghostty-run tab nvim "$1"'
# ⌘K on a project lists its Makefile targets, package.json scripts, just recipes and
# swift/cargo/go build + test. This runs the one you pick ($1 = "cd '<repo>' && make test"):
task  = 'ghostty-run tab eval "$1"'

# Files by name, via Spotlight. Shown below everything else, after 3+ letters.
[files]
enabled = true
limit   = 8

[search]
# Shown first when the search box is empty, by name (apps, projects or actions).
favorites = []                   # e.g. ["Ghostty", "euclid-bar", "Search web"]

# Look and feel.
[appearance]
theme      = "default"           # or dracula, nord, tokyo-night, catppuccin-mocha, catppuccin-latte, gruvbox-dark,
                                 # gruvbox-light, solarized-dark, solarized-light, monokai, or themes/<name>.toml
# accent   = "#7c5cff"           # match highlight; default: the theme's, or your system accent colour
density    = "comfortable"       # or "compact": smaller rows, more results
glass      = true                # Liquid Glass background on macOS 26+
show_speed = true                # "12,431 items · 0.6 ms" in the footer

# Search your Obsidian notes by title and text (↵ opens the note in Obsidian).
[obsidian]
# vault = "~/Notes"

# What `euclid-bar --mcp` lets your coding agents (Claude Code, Codex) search. Read-only, local.
[agents]
share = ["clipboard", "notes", "history"]

# Updates (release builds). Also in the menu bar icon and in search: type "update".
[updates]
check        = true              # look for a new version once a day
auto_install = true              # download it in the background, install on quit
channel      = "stable"          # "dev": a build of every change merged to main, for testing

# Euclid asks about both of these once, on first launch. Your answer is saved here.
#
# Send crash reports and internal errors to the Euclid developer, so they get fixed.
# Sent: app and macOS version, the crashed code's stack, the error message. Never your searches,
# clipboard, files, config or anything that identifies you. A copy of each is kept in
# ~/Library/Logs/Euclid/Reports, so you can read exactly what was sent.
#
# usage_ping: once a day, send a random install ID (made when you turn it on, forgotten when you
# turn it off), the app and macOS version, so the developer can count how many people use Euclid.
# Nothing else. The last one sent is in ~/Library/Logs/Euclid/Reports/usage-ping.json.
[privacy]
crash_reports = false
usage_ping    = false

# Type the alias to jump straight to an app, project or action.
# For an action, "alias text" runs it on "text": `gh swift testing`.
[aliases]
# code = "Visual Studio Code"

# ---------------------------------------------------------------------------
# Actions, in order. The first is ⌘↵; ⌘1–⌘9 run the first nine; ⌘K lists all.
# Optional `alias = "gh"`: type "gh something" to run it on "something".
#
# Each action runs:   <shell> -l -c '<run>' euclid "<query>"
# so inside `run`:
#   $1 / $EUCLID_QUERY   what you typed
#   $EUCLID_QUERY_URL    the same, URL-encoded
# The query is passed as an argument, never pasted into the command,
# so quotes or $(...) in what you type can't run anything.
# Tip: use 'single quotes' around run, so double quotes inside need no escaping.
#
# Commands run in the background. Anything goes: open URLs, call CLIs, scripts.
# Scripts in ~/.config/euclid/bin are on PATH. Euclid installs one you can edit:
#   ghostty-run tab|split|window <command...>   run a command in Ghostty
# ---------------------------------------------------------------------------

[[action]]
name  = "Search web"
alias = "g"
run   = 'open "https://www.google.com/search?q=$EUCLID_QUERY_URL"'

[[action]]
name  = "Search GitHub"
alias = "gh"
run   = 'open "https://github.com/search?type=code&q=$EUCLID_QUERY_URL"'

# [[action]]
# name = "pi in Ghostty"
# run  = 'ghostty-run tab pi "$1"'          # or: split, window

# Plugins: folders in ~/.config/euclid/plugins; AGENTS.md there is the whole format.
# `euclid-bar --plugin add github` adds an example (also: bitbucket, jira, linear, slack…).
# [plugins]
# paths    = ["~/work/team/euclid-plugins"]   # a team's shared plugins
# disabled = ["github"]
# [plugin.github]                             # your values for a plugin's settings
# limit = 50

# Snippets: text you paste often. Find them by name or keyword; ↵ pastes.
# Placeholders: {date} {time} {datetime} {clipboard} {uuid}
# [[snippet]]
# name    = "Standup template"
# keyword = "standup"
# text    = """
# Yesterday:
# Today:
# Blockers: none ({date})
# """
# hotkey  = "ctrl+opt+s"     # optional: pastes it from any app, panel closed

# Text expansion: type a snippet's keyword in any app and it's replaced by the text.
# A keyword starting with a symbol (";sig") expands at once; a plain word ("standup")
# when you type a space or punctuation after it. Needs Accessibility access (macOS asks).
[expansion]
enabled = false

# Hotkeys that open or run one thing directly: an app, project, action or snippet, by name.
# An [[action]] or [[snippet]] can also take `hotkey = "…"`. Actions run with an empty $1.
[hotkeys]
# Ghostty      = "ctrl+opt+t"
# "euclid-bar" = "ctrl+opt+e"
"""#
}
