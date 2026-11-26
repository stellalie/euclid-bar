import Foundation

/// `euclid-bar --completions zsh`: tab completion for the command line. Flags, plugin examples and
/// `--plugin` commands are written in; tool and theme names are asked of euclid-bar as you type,
/// so your own themes and tools are always there.
///
///     euclid-bar --completions zsh > ~/.zfunc/_euclid-bar   # with ~/.zfunc on $fpath, before compinit
public enum Completions {
    static let flags: [(String, String)] = [
        ("--tool", "run an agent tool: search the clipboard, notes, history"),
        ("--theme", "list or switch themes"),
        ("--plugin", "add or list plugins"),
        ("--try-plugin", "run a plugin once and show its rows"),
        ("--pick", "pick a line from stdin in the panel (dmenu)"),
        ("--check-config", "check config.toml and plugins"),
        ("--mcp", "the MCP server for coding agents"),
        ("--completions", "print this completion script"),
    ]

    public static func zsh() -> String {
        let flagSpecs = flags.map { "'\($0.0):\($0.1.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: " ")
        let examples = PluginGuide.examples.keys.sorted().joined(separator: " ")
        return #"""
            #compdef euclid-bar
            # Tab completion for euclid-bar (Euclid's command line). Written by `euclid-bar --completions zsh`.
            _euclid-bar() {
              local cmd=${words[1]}
              if (( CURRENT == 2 )); then
                local -a flags=(\#(flagSpecs))
                _describe -t flags 'euclid-bar' flags
                return
              fi
              case ${words[2]} in
                --tool)
                  (( CURRENT == 3 )) || return 1
                  local -a tools=(${(f)"$($cmd --tool 2>/dev/null | sed -n '3,$s/^\([a-z_]*\) .*/\1/p')"})
                  compadd -a tools ;;
                --theme)
                  (( CURRENT == 3 )) || return 1
                  local -a themes=(${(f)"$($cmd --theme 2>/dev/null | sed -n 's/^[* ] \([a-z0-9_-]*\).*/\1/p')"})
                  compadd -a themes ;;
                --plugin)
                  if (( CURRENT == 3 )); then compadd add list
                  elif (( CURRENT == 4 )) && [[ ${words[3]} == add ]]; then compadd \#(examples)
                  fi ;;
                --completions)
                  (( CURRENT == 3 )) && compadd zsh ;;
                --try-plugin)
                  (( CURRENT == 3 )) && compadd -- ${~:-$HOME/.config/euclid/plugins/*(/N:t)} ;;
              esac
            }
            _euclid-bar "$@"

            """#
    }
}
