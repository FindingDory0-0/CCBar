import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Last-resort adapter — activates the host app and copies the session's cwd
/// to the pasteboard so the user can paste it into whatever tab they end up in.
///
/// Used for Warp, Ghostty, and `.unknown` hosts where we don't have a reliable
/// AppleScript path or URL scheme.
public struct GenericAppAdapter: HostAdapter {

    public init() {}

    /// Accepts anything — this is the universal fallback. HostRouter places it
    /// last so it only runs when no specific adapter matches.
    public func canHandle(_ hint: HostHint) -> Bool { true }

    public func focus(session: Session) async throws {
        #if canImport(AppKit)
        await MainActor.run {
            // Cwd → clipboard, as an obvious affordance for the user.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(session.cwd.path, forType: .string)
        }
        let bundleID: String? = {
            switch session.hostHint {
            case .iTerm2: return "com.googlecode.iterm2"
            case .terminal: return "com.apple.Terminal"
            case .warp: return "dev.warp.Warp-Stable"
            case .ghostty: return "com.mitchellh.ghostty"
            case .vscodeFork(let id, _): return id
            case .jetbrains(let id): return id
            case .unknown: return nil
            }
        }()
        if let bundleID {
            try? await activateApp(bundleID: bundleID)
        }
        #endif
    }
}
