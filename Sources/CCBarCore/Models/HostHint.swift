import Foundation

/// What kind of app/window hosts a Claude Code session, plus enough info to focus it.
///
/// Derived by ProcessProbe by walking the `claude` PID's parent chain until it reaches
/// the first GUI application (iTerm2, Terminal, VS Code, IntelliJ, …).
public enum HostHint: Codable, Hashable, Sendable {
    /// iTerm2 — `tty` is the device path used to match against iTerm2's session list.
    case iTerm2(tty: String)
    /// Apple Terminal.app — `tty` is matched against `selected tab of window N`.
    case terminal(tty: String)
    /// Warp — no reliable AppleScript; we only activate the app and copy `cd <cwd>`.
    case warp
    /// Ghostty — same fallback approach as Warp.
    case ghostty
    /// VS Code family (VSCode / Cursor / Antigravity / Windsurf …).
    /// `bundleID` selects which fork, `scheme` is the URL scheme (vscode/cursor/antigravity).
    case vscodeFork(bundleID: String, scheme: String)
    /// JetBrains IDEs — bundle ID determines which IDE (IntelliJ, PyCharm, …).
    case jetbrains(bundleID: String)
    /// Couldn't determine. Show the session but skip jump.
    case unknown

    public var displayName: String {
        switch self {
        case .iTerm2: return "iTerm2"
        case .terminal: return "Terminal"
        case .warp: return "Warp"
        case .ghostty: return "Ghostty"
        case .vscodeFork(let bundleID, _):
            switch bundleID {
            case "com.microsoft.VSCode": return "VS Code"
            case "com.google.antigravity": return "Antigravity"
            default:
                // Cursor / Windsurf / etc — bundle IDs vary by build. Best effort.
                let lower = bundleID.lowercased()
                if lower.contains("cursor") { return "Cursor" }
                if lower.contains("windsurf") { return "Windsurf" }
                return bundleID
            }
        case .jetbrains(let bundleID):
            // com.jetbrains.intellij → "IntelliJ"
            let suffix = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            return suffix.prefix(1).uppercased() + suffix.dropFirst()
        case .unknown: return "Unknown"
        }
    }
}
