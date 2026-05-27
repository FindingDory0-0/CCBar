import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Focuses VS Code / Cursor / Antigravity / Windsurf via their URL schemes.
///
/// Each fork registers a `<name>://` scheme that, when opened by an already-
/// running instance, activates the existing window containing the requested
/// folder. If the app isn't running, the same URL launches it.
///
/// We send `<scheme>://file<absolute-path>` — the canonical form supported by
/// the upstream VS Code (and inherited by every fork tested so far).
public struct VSCodeForkAdapter: HostAdapter {

    public init() {}

    public func canHandle(_ hint: HostHint) -> Bool {
        if case .vscodeFork = hint { return true }
        return false
    }

    public func focus(session: Session) async throws {
        guard case .vscodeFork(_, let scheme) = session.hostHint else {
            throw HostJumpError.unsupportedHost
        }
        // Path needs percent-encoding for non-ASCII chars (e.g. Korean paths).
        let path = session.cwd.path
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw HostJumpError.adapterFailed("path encoding failed")
        }
        guard let url = URL(string: "\(scheme)://file\(encoded)") else {
            throw HostJumpError.adapterFailed("invalid URL: \(scheme)://file\(encoded)")
        }
        #if canImport(AppKit)
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
