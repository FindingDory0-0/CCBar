import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Focuses JetBrains IDEs (IntelliJ IDEA, PyCharm, WebStorm, GoLand, …).
///
/// JetBrains apps don't share a single URL scheme, so we simply activate the
/// app by its bundle identifier. The IDE's own "remember last project" logic
/// brings the right window forward — which is usually the project the user
/// was just working in.
///
/// A future refinement could shell out to `idea <cwd>` if the JetBrains CLI
/// launcher is installed, but bundle activation works without any setup.
public struct JetBrainsAdapter: HostAdapter {

    public init() {}

    public func canHandle(_ hint: HostHint) -> Bool {
        if case .jetbrains = hint { return true }
        return false
    }

    public func focus(session: Session) async throws {
        guard case .jetbrains(let bundleID) = session.hostHint else {
            throw HostJumpError.unsupportedHost
        }
        #if canImport(AppKit)
        try await activateApp(bundleID: bundleID)
        #endif
    }
}
