/// Written to `config.toml` on first launch. Must stay valid: a test parses it.
public enum DefaultConfig {
    public static let text = #"""
# Euclid configuration. Changes apply on save, no restart needed
# (except clipboard.limit, which applies on next launch).
# Check from a terminal: euclid-bar.app/Contents/MacOS/euclid-bar --check-config

# Global hotkey that opens the panel. When set here, it wins over the app.
# Modifiers: cmd, opt, ctrl, shift. Keys: a–z, 0–9, space, return, tab, f1–f12.
hotkey = "opt+space"

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

# Files by name, via Spotlight. Shown below everything else, after 3+ letters.
[files]
enabled = true
limit   = 8

[search]
# Shown first when the search box is empty, by name (apps, projects or actions).
favorites = []                   # e.g. ["Ghostty", "euclid-bar", "Search web"]

# Look and feel.
[appearance]
# accent   = "#7c5cff"           # selection and match highlight; default: your system accent colour
density    = "comfortable"       # or "compact": smaller rows, more results
glass      = true                # Liquid Glass background on macOS 26+
show_speed = true                # "12,431 items · 0.6 ms" in the footer

# Full-text search of the pages in your browser history. Off by default: when on,
# Euclid downloads recent pages (no cookies, so only what's public) and indexes
# their text locally. Links that look like logins, resets or have query strings are skipped.
[pages]
enabled = false
limit   = 500                    # most recent pages to index
exclude_hosts = []               # e.g. ["mail.google.com", "internal.example.com"]

# Search your Obsidian notes by title and text (↵ opens the note in Obsidian).
[obsidian]
# vault = "~/Notes"

# Bitbucket: your open PRs, PRs waiting on your review, and your repos (↵ opens in the browser).
# Cloud: email + an API token (id.atlassian.com › Security › API tokens), stored in the Keychain:
#   security add-generic-password -s euclid-bitbucket -a "$USER" -w <token>
# Data Center: set base_url to your server and use an HTTP access token (no email).
# [bitbucket]
# email         = "you@example.com"
# base_url      = "https://api.bitbucket.org/2.0"     # or "https://bitbucket.example.com"
# token_command = "security find-generic-password -s euclid-bitbucket -w"
# repos         = ["workspace/repo"]   # Cloud: where to look for review requests (default: your 10 latest repos)
# refresh_minutes = 5

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
#   ghostty-run tab|split|window <command...>     run a command in Ghostty
#   herdr-run   tab|split|split-down <command...> run a command in herdr
# Coming next: output = "panel" streams a command's output into Euclid.
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
# name   = "Ask pi"
# run    = 'pi --print "$1"'
# output = "panel"

# [[action]]
# name = "pi in Ghostty"
# run  = 'ghostty-run tab pi "$1"'          # or: split, window

# [[action]]
# name = "pi in herdr"
# run  = 'herdr-run tab pi "$1"'            # or: split, split-down

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
"""#
}
