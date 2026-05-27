import Foundation

/// Picks the right HostAdapter for a session and runs it, with fallback.
///
/// Try-order: specific adapters first (iTerm2, Terminal, VS Code fork,
/// JetBrains), then GenericAppAdapter last so it only runs when nothing
/// specific matched (or when a specific adapter threw).
public struct HostRouter: Sendable {

    public let adapters: [any HostAdapter]

    public init(adapters: [any HostAdapter]) {
        self.adapters = adapters
    }

    /// Default router wires up every adapter we ship.
    public static let `default` = HostRouter(adapters: [
        iTerm2Adapter(),
        TerminalAppAdapter(),
        VSCodeForkAdapter(),
        JetBrainsAdapter(),
        GenericAppAdapter(),  // always last — its canHandle returns true for anything
    ])

    /// Try each matching adapter in order. Returns when one succeeds.
    /// If every matching adapter throws, the GenericAppAdapter still runs as
    /// a last-ditch best-effort.
    public func focus(session: Session) async {
        for adapter in adapters where adapter.canHandle(session.hostHint) {
            do {
                try await adapter.focus(session: session)
                return
            } catch {
                // Log and try the next adapter that also matches (usually Generic).
                #if canImport(Foundation)
                NSLog("CCBar HostRouter: \(type(of: adapter)) failed: \(error). Trying next.")
                #endif
            }
        }
    }
}
