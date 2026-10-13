import Foundation
import EuclidCore

/// Opens an action in Ghostty (1.3+) via its AppleScript API: a new tab or a
/// split in the front window, or a new window if none is open.
///
/// Values go to osascript as argv items, never spliced into the script, and the
/// query reaches the shell only as the EUCLID_QUERY environment variable.
/// First use triggers macOS's "Euclid wants to control Ghostty" prompt.
enum GhosttyLauncher {
    enum Placement: String { case tab, split }

    private static let script = """
    on run argv
      set theCommand to item 1 of argv
      set placement to item 2 of argv
      set envList to {}
      if (count of argv) > 2 then set envList to items 3 thru -1 of argv
      tell application "Ghostty"
        set cfg to new surface configuration
        set command of cfg to theCommand
        set environment variables of cfg to envList
        if (count of windows) is 0 then
          new window with configuration cfg
        else if placement is "split" then
          split (focused terminal of selected tab of front window) direction right with configuration cfg
        else
          new tab in front window with configuration cfg
        end if
        activate
      end tell
    end run
    """

    static func open(_ action: Action, placement: Placement, query: String, shell: String,
                     completion: @escaping @Sendable (Result<Void, CommandRunner.Failure>) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script,
                       CommandRunner.terminalCommand(shell: shell, run: action.run),
                       placement.rawValue] + CommandRunner.euclidEnvironmentEntries(query: query)
        CommandRunner.run(p) { result in
            completion(result.mapError { failure in
                // -1743: the user denied (or hasn't granted) Automation permission.
                guard failure.stderr.contains("-1743") else { return failure }
                return .init(status: failure.status,
                             stderr: "not allowed to control Ghostty — enable it in System Settings › Privacy & Security › Automation")
            })
        }
    }
}
