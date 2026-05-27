import Foundation
#if canImport(AppKit)
import AppKit
import ApplicationServices

/// Bring a window of `bundleID`'s process to the front using the
/// Accessibility API (`AXRaise` action).
///
/// Why this exists: `set index of w to 1` inside iTerm2's AppleScript only
/// reorders the app's internal window list. macOS keeps showing whichever
/// window was last clicked because the *window-server* still considers that
/// one frontmost. `AXRaise` is the macOS-blessed way to actually re-elevate
/// a window — and crucially, it switches Spaces / displays automatically
/// when the target is on a different one.
///
/// Strategy: we rely on the AppleScript step having already put the target
/// at iTerm2's window index 1, then ask Accessibility to raise window[0] of
/// the iTerm2 process.
///
/// Requires the user to have granted CCBar **Accessibility permission**
/// (System Settings → Privacy & Security → Accessibility).
public enum AccessibilityRaise {

    /// True if our process is trusted for accessibility actions. When
    /// `prompt == true` and the trust check fails, macOS pops the standard
    /// "App would like Accessibility access" prompt and points the user at
    /// the Settings pane.
    ///
    /// We hard-code the option key string rather than dereferencing the global
    /// `kAXTrustedCheckOptionPrompt` — Swift 6 flags reading that C global as
    /// not-concurrency-safe, and the string value never changes.
    public static func isTrusted(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Raise the first AX window of the running app matching `bundleID`.
    /// Used only as a fallback — `raiseWindow(matchingTitle:...)` is preferred
    /// because the AX window list is ordered by recently-focused, not by our
    /// AppleScript reordering.
    @discardableResult
    public static func raiseFirstWindow(ofBundle bundleID: String) -> Bool {
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first
        else { return false }

        // Activate the app *before* AXRaise so macOS doesn't subsequently
        // restore the app's most-recent key window on top of ours.
        running.activate()
        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        var windowsRef: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        )
        guard copyResult == .success,
              let windows = windowsRef as? [AXUIElement],
              let target = windows.first
        else { return false }

        return AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
    }

    /// Raise the AX window whose `kAXTitle` equals (or contains) `title`.
    @discardableResult
    public static func raiseWindow(matchingTitle title: String, ofBundle bundleID: String) -> Bool {
        guard !title.isEmpty,
              let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .first
        else { return false }

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &windowsRef
              ) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return false }

        // Activate first, then AXRaise — the reverse order lets macOS
        // re-restore the app's previously-frontmost window on top of ours,
        // which causes the "jump bounces back to another iTerm window" bug.
        running.activate()
        for window in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                    window,
                    kAXTitleAttribute as CFString,
                    &titleRef
                  ) == .success,
                  let windowTitle = titleRef as? String
            else { continue }
            if windowTitle == title || windowTitle.contains(title) || title.contains(windowTitle) {
                return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
            }
        }
        return false
    }

    /// Raise the AX window whose position+size matches `bounds` (with a few-px
    /// tolerance). The most reliable matcher — iTerm2 window titles change as
    /// the user types or switches tabs, but the frame is stable.
    @discardableResult
    public static func raiseWindow(matchingBounds bounds: CGRect, ofBundle bundleID: String) -> Bool {
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first
        else { return false }

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &windowsRef
              ) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return false }

        // Activate first, then AXRaise (see note in raiseWindow(matchingTitle:)).
        running.activate()
        for window in windows {
            guard let frame = axFrame(of: window) else { continue }
            let dx = abs(frame.origin.x - bounds.origin.x)
            let dy = abs(frame.origin.y - bounds.origin.y)
            let dw = abs(frame.width  - bounds.width)
            let dh = abs(frame.height - bounds.height)
            if dx < 4, dy < 4, dw < 4, dh < 4 {
                return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
            }
        }
        return false
    }

    /// Position + size of an AX window as a CGRect (or nil if unavailable).
    private static func axFrame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        // CFType→AXValue casts are safe because the AX API guarantees these
        // attributes return AXValue when the call succeeds.
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}
#endif
