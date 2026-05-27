import Foundation
import AppKit
import Sparkle

/// Thin wrapper over Sparkle's `SPUStandardUpdaterController`.
///
/// Sparkle reads its feed URL + signing key from `Info.plist`:
///   - `SUFeedURL`        — URL to the appcast.xml (GitHub Releases, GitHub Pages, …)
///   - `SUPublicEDKey`    — base64 EdDSA public key (paired with the private key
///                          used by `scripts/release.sh` to sign each release)
///   - `SUEnableAutomaticChecks` — true: silent background checks on a schedule
///
/// The standard controller drives the whole flow (background check → download →
/// install → relaunch). We just need to expose two entry points to the UI:
///   - `checkForUpdates()` — user clicks "업데이트 확인" in the gear menu
///   - `currentVersion` — read from CFBundleShortVersionString for display
@MainActor
final class AppUpdater {
    private let controller: SPUStandardUpdaterController

    init() {
        // `startingUpdater: true` boots the background scheduler immediately.
        // Sparkle reads SUFeedURL etc from the host app's Info.plist.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Trigger an interactive update check now. Sparkle shows a "checking…"
    /// dialog and walks the user through any available update.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Human-readable current version, e.g. "0.1.0".
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Build number — usually monotonically increasing, useful for ordering.
    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}
