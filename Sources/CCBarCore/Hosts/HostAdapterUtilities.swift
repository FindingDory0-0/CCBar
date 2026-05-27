import Foundation
#if canImport(AppKit)
import AppKit
#endif

#if canImport(AppKit)
/// Bring an app to the front by bundle identifier. Throws if the app isn't
/// installed / can't be located.
///
/// The whole launch is wrapped in a single `MainActor.run` to satisfy Swift 6
/// strict concurrency — `NSWorkspace.OpenConfiguration` isn't Sendable, so we
/// must create *and* use it on the same actor.
func activateApp(bundleID: String) async throws {
    let found: Bool = await MainActor.run {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        // Fire-and-forget. Activation is synchronous enough that we don't need
        // the completion handler for ordinary use.
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        return true
    }
    if !found {
        throw HostJumpError.appNotInstalled(bundleID: bundleID)
    }
}

/// Run an AppleScript snippet, throwing if it fails. Executes on the main
/// actor — NSAppleScript isn't documented as thread-safe.
func runAppleScript(_ source: String, label: String) async throws {
    _ = try await runAppleScriptReturning(source, label: label)
}

/// Same as `runAppleScript` but returns the script's `return` value as a String
/// (empty string if the script didn't return a string-coercible value).
@discardableResult
func runAppleScriptReturning(_ source: String, label: String) async throws -> String {
    try await MainActor.run {
        guard let script = NSAppleScript(source: source) else {
            throw HostJumpError.adapterFailed("\(label): script creation failed")
        }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            throw HostJumpError.adapterFailed("\(label): \(error)")
        }
        return descriptor.stringValue ?? ""
    }
}

/// Look up the iTerm2 window-name that currently owns `ttyPath` (e.g.
/// `/dev/ttys003`). Returns `nil` if no iTerm session matches — the TTY may
/// belong to Terminal.app, Warp, Ghostty, or have been closed.
///
/// Used as a human-friendly identifier in toasts and session cards so the
/// user can distinguish multiple sessions sharing the same alias / cwd
/// (e.g. when `claude -c` continues an older session under a stale name).
/// Cached by the caller — this AppleScript round-trip is ~50 ms, not
/// suitable for per-render lookups.
public func iTermWindowName(forTTY ttyPath: String) async -> String? {
    let script = """
    tell application "iTerm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if tty of s is "\(ttyPath)" then
                        return name of w
                    end if
                end repeat
            end repeat
        end repeat
        return ""
    end tell
    """
    guard let result = try? await runAppleScriptReturning(script, label: "iTermWindowName"),
          !result.isEmpty else {
        return nil
    }
    return result
}
#endif
