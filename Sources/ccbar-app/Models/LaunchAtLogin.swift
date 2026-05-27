import Foundation
import AppKit
import ServiceManagement

/// Wrapper around `SMAppService.mainApp` so the rest of the app doesn't have
/// to import ServiceManagement directly. macOS 13+.
///
/// Status notes:
///   - `.enabled`: the app is registered and will launch on login.
///   - `.notRegistered`: not set up. Calling `register()` switches to `.enabled`
///      (or `.requiresApproval` if macOS wants the user to confirm).
///   - `.requiresApproval`: the user disabled this in Login Items → we can't
///      override; we surface the state and link them to Settings.
///   - `.notFound`: the binary isn't where `SMAppService` expected — usually
///      means we're running from a debug build outside `/Applications`.
@MainActor
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Register / unregister CCBar for "open at login". Returns the resulting
    /// status so the caller can show an appropriate UI hint (e.g. when macOS
    /// returns `.requiresApproval`).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> SMAppService.Status {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("[LaunchAtLogin] toggle to \(enabled) failed: \(error)")
        }
        return service.status
    }

    /// Open Login Items pane in System Settings so the user can flip their
    /// global toggle if macOS is holding our registration in `.requiresApproval`.
    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
