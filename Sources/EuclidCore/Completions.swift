import Foundation

/// `euclid-bar --completions zsh|bash|fish`: tab completion for the command line. Flags, plugin examples and
/// `--plugin` commands are written in; tool and theme names are asked of euclid-bar as you type,
/// so your own themes and tools are always there.
///
///     euclid-bar --completions zsh > ~/.zfunc/_euclid-bar   # with ~/.zfunc on $fpath, before compinit
///     euclid-bar --completions bash > ~/.local/share/bash-completion/completions/euclid-bar
///     euclid-bar --completions fish > ~/.config/fish/completions/euclid-bar.fish
public enum Completions {
    public static let shells = ["zsh", "bash", "fish"]

    /// The script for `shell`, or nil for a shell we don't write one for.
    public static func script(for shell: String) -> String? {
        switch shell {
        case "zsh": zsh()
        case "bash": bash()
        case "fish": fish()
        default: nil
        }
    }

    /// The names `--tool` and `--theme` list, as each script reads them.
    static let toolNames = #"sed -n '3,$s/^\([a-z_]*\) .*/\1/p'"#
    static let themeNames = #"sed -n 's/^[* ] \([a-z0-9_-]*\).*/\1/p'"#
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
                  (( CURRENT == 3 )) && compadd zsh bash fish ;;
                --try-plugin)
                  (( CURRENT == 3 )) && compadd -- ${~:-$HOME/.config/euclid/plugins/*(/N:t)} ;;
              esac
            }
            _euclid-bar "$@"

            """#
    }

    public static func bash() -> String {
        let flags = Self.flags.map(\.0).joined(separator: " ")
        let examples = PluginGuide.examples.keys.sorted().joined(separator: " ")
        return #"""
            # Tab completion for euclid-bar (Euclid's command line). Written by `euclid-bar --completions bash`.
            _euclid_bar() {
              local cur=${COMP_WORDS[COMP_CWORD]} cmd=${COMP_WORDS[0]} words=""
              if (( COMP_CWORD == 1 )); then
                words="\#(flags)"
              else
                case ${COMP_WORDS[1]} in
                  --tool) (( COMP_CWORD == 2 )) && words=$("$cmd" --tool 2>/dev/null | \#(toolNames)) ;;
                  --theme) (( COMP_CWORD == 2 )) && words=$("$cmd" --theme 2>/dev/null | \#(themeNames)) ;;
                  --plugin)
                    if (( COMP_CWORD == 2 )); then words="add list"
                    elif (( COMP_CWORD == 3 )) && [[ ${COMP_WORDS[2]} == add ]]; then words="\#(examples)"; fi ;;
                  --completions) (( COMP_CWORD == 2 )) && words="zsh bash fish" ;;
                  --try-plugin)
                    (( COMP_CWORD == 2 )) && words=$(cd "$HOME/.config/euclid/plugins" 2>/dev/null && ls -d -- */ 2>/dev/null | tr -d /) ;;
                esac
              fi
              COMPREPLY=($(compgen -W "$words" -- "$cur"))
            }
            complete -F _euclid_bar euclid-bar

            """#
    }

    public static func fish() -> String {
        let first = "not __fish_seen_argument " + flags.map { "-l \($0.0.dropFirst(2))" }.joined(separator: " ")
        let flagLines = flags.map { "complete -c euclid-bar -n '\(first)' -l \($0.0.dropFirst(2)) -d '\($0.1.replacingOccurrences(of: "'", with: ""))'" }
        let examples = PluginGuide.examples.keys.sorted().joined(separator: " ")
        func after(_ flag: String, _ more: String = "") -> String {
            "complete -c euclid-bar -n '__fish_seen_argument -l \(flag); and test (count (commandline -opc)) -eq 2\(more)'"
        }
        return ([
            "# Tab completion for euclid-bar (Euclid's command line). Written by `euclid-bar --completions fish`.",
            "complete -c euclid-bar -f",
        ] + flagLines + [
            after("tool") + " -a '(euclid-bar --tool 2>/dev/null | \(toolNames.replacingOccurrences(of: "'", with: "\\'")))'",
            after("theme") + " -a '(euclid-bar --theme 2>/dev/null | \(themeNames.replacingOccurrences(of: "'", with: "\\'")))'",
            after("plugin") + " -a 'add list'",
            "complete -c euclid-bar -n '__fish_seen_argument -l plugin; and __fish_seen_subcommand_from add' -a '\(examples)'",
            after("completions") + " -a 'zsh bash fish'",
            after("try-plugin") + " -a '(path basename ~/.config/euclid/plugins/*/ 2>/dev/null)'",
        ]).joined(separator: "\n") + "\n"
    }
}
