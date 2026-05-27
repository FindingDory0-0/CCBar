import Foundation

/// Brings a session's host window/IDE to the front.
///
/// Each adapter handles one or more `HostHint` variants. Adapters can fail
/// (e.g. AppleScript denied, app not installed) — the router will try the
/// next matching adapter as a fallback.
public protocol HostAdapter: Sendable {
    /// Whether this adapter is capable of focusing the given host.
    func canHandle(_ hint: HostHint) -> Bool
    /// Focus / activate the session's host. Throws on failure so the router
    /// can try a fallback adapter.
    func focus(session: Session) async throws
}

public enum HostJumpError: Error, Sendable {
    case unsupportedHost
    case adapterFailed(String)
    case appNotInstalled(bundleID: String)
}
