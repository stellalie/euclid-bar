/// Helper scripts installed into `<config>/bin` on first launch. Never
/// overwritten, so they're yours to edit. Actions get that directory first on PATH.
public enum DefaultScripts {
    public static let all: [(name: String, text: String)] = [("ghostty-run", ghosttyRun)]

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
# When the command exits, the terminal drops into your shell.
# Installed by Euclid. Edit freely: Euclid never overwrites it.
set -eu

place=${1:-}
case $place in
  tab|split|window) shift ;;
  *) print -u2 "usage: ghostty-run tab|split|window <command> [args...]"; exit 64 ;;
esac
(( $# )) || { print -u2 "ghostty-run: missing command"; exit 64 }

inner=${(j: :)${(q)@}}
term_cmd="/bin/zsh -l -c 'eval \"\$EUCLID_CMD\"; exec \"\${SHELL:-/bin/zsh}\" -l'"

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
}
