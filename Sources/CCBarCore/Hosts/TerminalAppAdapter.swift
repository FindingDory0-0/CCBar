import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Focuses an Apple Terminal.app window/tab by TTY match.
///
/// Terminal.app's AppleScript surfaces TTY differently from iTerm2: each tab
/// is a `tab of window N`. We iterate windows → tabs to find the right one,
/// then set it as selected and bring the window to the front.
public struct TerminalAppAdapter: HostAdapter {

    public init() {}

    public func canHandle(_ hint: HostHint) -> Bool {
        if case .terminal = hint { return true }
        return false
    }

    public func focus(session: Session) async throws {
        guard case .terminal(let tty) = session.hostHint else {
            throw HostJumpError.unsupportedHost
        }
        guard !tty.isEmpty else {
            try await activateApp(bundleID: "com.apple.Terminal")
            return
        }
        let script = """
        tell application "Terminal"
            activate
            set targetTTY to "\(tty)"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is targetTTY then
                        set selected of t to true
                        set frontmost of w to true
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        try await runAppleScript(script, label: "Terminal.app jump")
    }
}
