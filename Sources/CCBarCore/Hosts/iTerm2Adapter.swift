import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Focuses an iTerm2 window/tab by exact TTY match.
///
/// iTerm2's AppleScript exposes `tty` on each session (pane). We walk every
/// window → tab → session, find the one whose TTY equals our recorded value,
/// and `select` it from the inside out so the window comes to the front and
/// the correct tab is selected.
public struct iTerm2Adapter: HostAdapter {

    public init() {}

    public func canHandle(_ hint: HostHint) -> Bool {
        if case .iTerm2 = hint { return true }
        return false
    }

    public func focus(session: Session) async throws {
        guard case .iTerm2(let tty) = session.hostHint else {
            throw HostJumpError.unsupportedHost
        }
        guard !tty.isEmpty else {
            // Headless invocation (e.g. claude -p) has no controlling TTY —
            // best we can do is activate the app and let the user find the tab.
            try await activateApp(bundleID: "com.googlecode.iterm2")
            return
        }

        // Multi-window correctness:
        //
        // `set index of w to 1` only reorders windows *inside* iTerm2 — macOS
        // still considers whichever iTerm2 window was last clicked as the
        // frontmost. To actually raise the target window we first ask
        // NSRunningApplication to activate *all* of iTerm2's windows; then
        // the AppleScript reorders so our target ends up on top of the stack.
        #if canImport(AppKit)
        await MainActor.run {
            NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.googlecode.iterm2")
                .first?
                .activate(options: [.activateAllWindows])
        }
        #endif

        NSLog("[iTerm2Adapter] focus tty=\(tty)")

        // AppleScript:
        //   - Selects the right tab/session inside iTerm2.
        //   - Returns "<windowName>|<l>,<t>,<r>,<b>" so Swift can match the
        //     AX window by EITHER title or bounds. `as string` flattens the
        //     bounds list with no separators, so we serialise each item
        //     individually with commas.
        let script = """
        tell application "iTerm2"
            set targetTTY to "\(tty)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is targetTTY then
                            set index of w to 1
                            tell t to select
                            tell s to select
                            set b to bounds of w
                            return (name of w) & "|" & ((item 1 of b) as text) & "," & ((item 2 of b) as text) & "," & ((item 3 of b) as text) & "," & ((item 4 of b) as text)
                        end if
                    end repeat
                end repeat
            end repeat
            return ""
        end tell
        """
        let descriptor = try await runAppleScriptReturning(script, label: "iTerm2 jump")
        NSLog("[iTerm2Adapter] AppleScript returned: '\(descriptor)'")

        let (windowName, bounds) = Self.parseScriptReturn(descriptor)
        NSLog("[iTerm2Adapter] parsed name='\(windowName)' bounds=\(bounds.map(String.init(describing:)) ?? "nil")")

        #if canImport(AppKit)
        await MainActor.run {
            // Don't prompt automatically — the user may not be expecting it
            // right now. We surface a banner in the popover instead, and rely
            // on the explicit "권한 열기" button to launch the system pane.
            let trusted = AccessibilityRaise.isTrusted(prompt: false)
            NSLog("[iTerm2Adapter] AX trusted: \(trusted)")
            guard trusted else {
                NSLog("[iTerm2Adapter] ⚠️ Accessibility permission missing — cannot AXRaise across spaces/displays")
                return
            }

            // Try bounds match first (most robust — titles change with tab edits).
            if let bounds {
                let raised = AccessibilityRaise.raiseWindow(
                    matchingBounds: bounds,
                    ofBundle: "com.googlecode.iterm2"
                )
                NSLog("[iTerm2Adapter] bounds raise: \(raised)")
                if raised { return }
            }
            if !windowName.isEmpty {
                let raised = AccessibilityRaise.raiseWindow(
                    matchingTitle: windowName,
                    ofBundle: "com.googlecode.iterm2"
                )
                NSLog("[iTerm2Adapter] title raise: \(raised)")
                if raised { return }
            }
            let raised = AccessibilityRaise.raiseFirstWindow(ofBundle: "com.googlecode.iterm2")
            NSLog("[iTerm2Adapter] fallback raise: \(raised)")
        }
        #endif
    }

    /// Parse the AppleScript return string `"<name>|<l>,<t>,<r>,<b>"`.
    /// Returns the name and a CGRect (or nil bounds if parsing fails).
    static func parseScriptReturn(_ s: String) -> (name: String, bounds: CGRect?) {
        guard !s.isEmpty else { return ("", nil) }
        let parts = s.components(separatedBy: "|")
        let name = parts.first ?? ""
        guard parts.count >= 2 else { return (name, nil) }
        let nums = parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 4 else { return (name, nil) }
        // AppleScript bounds: {left, top, right, bottom}, top-left origin.
        let left = nums[0], top = nums[1], right = nums[2], bottom = nums[3]
        return (name, CGRect(x: left, y: top, width: right - left, height: bottom - top))
    }
}
