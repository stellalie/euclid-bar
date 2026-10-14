/// Helper scripts installed into `<config>/bin`. Actions get that directory first on PATH.
/// Once you edit a script it's yours: Euclid only upgrades files that are
/// byte-identical to a version it shipped (see `previousVersions`).
public enum DefaultScripts {
    public static let all: [(name: String, text: String)] = [("ghostty-run", ghosttyRun), ("herdr-run", herdrRun)]

    /// SHA-256 of every earlier shipped version, per script. A file matching one
    /// of these is unmodified, so it's safe to replace with the current version.
    public static let previousVersions: [String: Set<String>] = [
        // v1: ran the command in a non-interactive shell, so ~/.zshrc exports were missing.
        "ghostty-run": ["aaecd6d1093bc03da602c20138539c4e41c650638fcd68f782896df35a0141dd"],
        // v1: activated Ghostty but not the Ghostty tab running herdr.
        "herdr-run": ["0bc59f88e3b8160b5a2af785264bedafbe31e57cb1890fc656658155e750cc45"],
    ]

    /// Ghostty's CLI can't open tabs or splits on macOS (`+new-window is not
    /// supported on this platform`), so this uses its AppleScript API.
    public static let ghosttyRun = #"""
#!/bin/zsh
# ghostty-run: run a command in a new Ghostty tab, split, or window.
#
#   ghostty-run tab    pi "$1"
#   ghostty-run split  pi "$1"
#   ghostty-run window htop
#
# Arguments are re-quoted with zsh's (q) flag and reach Ghostty only through an
# environment variable, so quotes, $(...) or backticks in them never run.
# The command runs in an interactive login shell (loads ~/.zprofile and ~/.zshrc),
# exactly like typing it into a new tab. When it exits, you're left in your shell.
# Installed by Euclid. Edit freely: once edited, Euclid never overwrites it.
set -eu

place=${1:-}
case $place in
  tab|split|window) shift ;;
  *) print -u2 "usage: ghostty-run tab|split|window <command> [args...]"; exit 64 ;;
esac
(( $# )) || { print -u2 "ghostty-run: missing command"; exit 64 }

inner=${(j: :)${(q)@}}
term_cmd="/bin/zsh -l -i -c 'eval \"\$EUCLID_CMD\"; exec \"\${SHELL:-/bin/zsh}\" -l'"

if [[ -n ${GHOSTTY_RUN_DRY:-} ]]; then   # testing: print instead of opening Ghostty
  print -r -- "$term_cmd"; print -r -- "EUCLID_CMD=$inner"; exit 0
fi

osascript - "$place" "$term_cmd" "EUCLID_CMD=$inner" <<'APPLESCRIPT'
on run argv
  set placement to item 1 of argv
  tell application "Ghostty"
    set cfg to new surface configuration
    set command of cfg to item 2 of argv
    set environment variables of cfg to {item 3 of argv}
    if placement is "window" or (count of windows) is 0 then
      new window with configuration cfg
    else if placement is "split" then
      split (focused terminal of selected tab of front window) direction right with configuration cfg
    else
      new tab in front window with configuration cfg
    end if
    activate
  end tell
end run
APPLESCRIPT
"""#

    /// Run a command in a new herdr tab or split, via herdr's CLI.
    public static let herdrRun = #"""
#!/bin/zsh
# herdr-run: run a command in a new herdr tab or split.
#
#   herdr-run tab        pi "$1"
#   herdr-run split      pi "$1"     # split the focused pane to the right
#   herdr-run split-down pi "$1"
#
# The command is re-quoted with zsh's (q) flag and passed to the new pane as the
# EUCLID_CMD environment variable; the pane only ever types `eval "$EUCLID_CMD"`.
# Quotes, $(...) or backticks in the query never run.
#
#   HERDR_RUN_APP=Ghostty   app hosting herdr, brought to the front (empty = don't)
#   HERDR_RUN_FOCUS=0       create in the background, don't switch to it
#   HERDR_RUN_TITLE=...     Ghostty title of the terminal running herdr
#                           (default "<hostname -s>: <workspace label>", herdr's own title)
# With Ghostty, the exact terminal running herdr is focused, not just the app.
# The pane's own interactive shell runs the command, so ~/.zshrc exports apply.
# Installed by Euclid. Edit freely: once edited, Euclid never overwrites it.
set -eu

place=${1:-}
case $place in
  tab|split|split-down) shift ;;
  *) print -u2 "usage: herdr-run tab|split|split-down <command> [args...]"; exit 64 ;;
esac
(( $# )) || { print -u2 "herdr-run: missing command"; exit 64 }
command -v herdr >/dev/null || { print -u2 "herdr-run: herdr not found on PATH"; exit 69 }
command -v jq >/dev/null || { print -u2 "herdr-run: jq not found on PATH"; exit 69 }

inner=${(j: :)${(q)@}}
focus=--focus
[[ ${HERDR_RUN_FOCUS:-1} == 0 ]] && focus=--no-focus

case $place in
  tab)
    res=$(herdr tab create $focus --label "${1:t}" --env "EUCLID_CMD=$inner")
    pane=$(jq -r '.result.root_pane.pane_id' <<<"$res") ;;
  split|split-down)
    dir=right; [[ $place == split-down ]] && dir=down
    res=$(herdr pane split --direction $dir $focus --env "EUCLID_CMD=$inner")
    pane=$(jq -r '.result.pane.pane_id' <<<"$res") ;;
esac
[[ -n $pane && $pane != null ]] || { print -u2 "herdr-run: unexpected herdr response: $res"; exit 70 }

herdr pane run "$pane" 'eval "$EUCLID_CMD"' >/dev/null

[[ $focus == --focus ]] || exit 0
app=${HERDR_RUN_APP-Ghostty}
[[ -n $app ]] || exit 0
if [[ $app != Ghostty ]]; then open -a "$app"; exit 0; fi

# Find the Ghostty terminal showing herdr. herdr titles it "<host>: <workspace label>".
ws=$(jq -r '(.result.root_pane // .result.pane).workspace_id // empty' <<<"$res")
label=$(herdr workspace list | jq -r --arg ws "$ws" '.result.workspaces[] | select(.workspace_id == $ws) | .label')
title=${HERDR_RUN_TITLE:-"$(hostname -s): $label"}
osascript - "$title" >/dev/null <<'APPLESCRIPT' || open -a Ghostty
on run argv
  tell application "Ghostty"
    repeat with term in terminals
      if name of term is (item 1 of argv) then
        focus term
        activate
        return
      end if
    end repeat
  end tell
  error "no Ghostty terminal titled " & (item 1 of argv)
end run
APPLESCRIPT
exit 0
"""#
}
