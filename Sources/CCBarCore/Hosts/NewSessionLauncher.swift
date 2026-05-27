import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Spawn a fresh Claude Code session in a host of the user's choice.
///
/// Today we only support iTerm2 (most common host in our setup). Other
/// hosts can be added as separate cases when there's a user that needs them
/// — each follows the same pattern: open a new tab/window, write the
/// `cd "<cwd>" && claude` line.
public enum NewSessionLauncher {

    /// Where to start the new session.
    public enum Host: Sendable {
        case iTerm2
    }

    /// How to invoke `claude` in the new window.
    ///
    /// Distinct cases instead of separate `continue` / `skipPermissions`
    /// booleans so the UI can put each combination in its own menu item with
    /// a fixed, translated label — easier to localize and reason about than
    /// a dynamic "(-c) (--dangerously-skip-permissions)" string.
    public enum Mode: Sendable, CaseIterable, Identifiable, Hashable {
        case basic
        case continueLast
        case skipPermissions
        case continueLastWithSkipPermissions

        public var id: Self { self }

        /// User-facing label in the menu.
        public var label: String {
            switch self {
            case .basic:                          return "기본"
            case .continueLast:                   return "대화 이어하기"
            case .skipPermissions:                return "권한 부여"
            case .continueLastWithSkipPermissions: return "권한 부여 · 대화 이어하기"
            }
        }

        /// CLI flags appended to `claude`. Empty for `.basic`.
        fileprivate var arguments: String {
            switch self {
            case .basic:                          return ""
            case .continueLast:                   return " -c"
            case .skipPermissions:                return " --dangerously-skip-permissions"
            case .continueLastWithSkipPermissions: return " -c --dangerously-skip-permissions"
            }
        }
    }

    public enum LaunchError: Error, Sendable {
        case unsupportedHost
        case scriptFailed(String)
    }

    /// Open a new iTerm2 window at `cwd` and run the chosen `claude` invocation.
    /// The command runs inside an interactive shell so the user's PATH and
    /// aliases apply (in particular, `~/.local/bin/claude` resolves).
    public static func launch(host: Host, cwd: URL, mode: Mode = .basic) async throws {
        switch host {
        case .iTerm2:
            try await launchITerm2(cwd: cwd, mode: mode)
        }
    }

    private static func launchITerm2(cwd: URL, mode: Mode) async throws {
        let escapedCwd = cwd.path.replacingOccurrences(of: "'", with: "'\\''")
        let command = "cd '\(escapedCwd)' && claude\(mode.arguments)"

        let script = """
        tell application "iTerm2"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text "\(command)"
            end tell
        end tell
        """
        #if canImport(AppKit)
        try await runAppleScript(script, label: "iTerm2 new session")
        #else
        throw LaunchError.unsupportedHost
        #endif
    }
}
