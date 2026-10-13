/// Written to `config.toml` on first launch. Must stay valid: a test parses it.
public enum DefaultConfig {
    public static let text = #"""
# Euclid configuration. Changes apply on save, no restart needed
# (except clipboard.limit, which applies on next launch).
# Check from a terminal: Euclid.app/Contents/MacOS/Euclid --check-config

# Global hotkey that opens the panel. When set here, it wins over the app.
# Modifiers: cmd, opt, ctrl, shift. Keys: a–z, 0–9, space, return, tab, f1–f12.
hotkey = "opt+space"

[clipboard]
limit = 5000                 # entries kept
ignore_apps = []             # bundle IDs never recorded, e.g. ["com.1password.1password"]

[shell]
path = "/bin/zsh"            # actions run as a login shell (-l), so your PATH is loaded

# ---------------------------------------------------------------------------
# Actions, in order. The first is ⌘↵; ⌘1–⌘9 run the first nine; ⌘K lists all.
#
# Each action runs:   <shell> -l -c '<run>' euclid "<query>"
# so inside `run`:
#   $1 / $EUCLID_QUERY   what you typed
#   $EUCLID_QUERY_URL    the same, URL-encoded
# The query is passed as an argument, never pasted into the command,
# so quotes or $(...) in what you type can't run anything.
# Tip: use 'single quotes' around run, so double quotes inside need no escaping.
#
# output:
#   "background"     (default) run it and stay out of the way
#   "ghostty-tab"    new tab in the front Ghostty window (new window if none)
#   "ghostty-split"  split the focused Ghostty pane to the right
#   (the tab drops into your shell when the command exits)
# Coming next: "panel", "herdr-tab", "herdr-pane".
# ---------------------------------------------------------------------------

[[action]]
name = "Search web"
run  = 'open "https://www.google.com/search?q=$EUCLID_QUERY_URL"'

[[action]]
name = "Search GitHub"
run  = 'open "https://github.com/search?type=code&q=$EUCLID_QUERY_URL"'

# [[action]]
# name   = "Ask pi"
# run    = 'pi --print "$1"'
# output = "panel"

# [[action]]
# name   = "pi in Ghostty"
# run    = 'pi "$1"'
# output = "ghostty-tab"
"""#
}
