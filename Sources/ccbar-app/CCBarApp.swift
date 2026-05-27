import SwiftUI
import CCBarCore

/// CCBar — Claude Code Menu Bar app entry point.
///
/// Uses SwiftUI `MenuBarExtra` (macOS 13+) so we avoid hand-rolling NSStatusItem/NSPopover.
/// `.menuBarExtraStyle(.window)` gives us a popover-like floating window we can populate
/// with arbitrary SwiftUI views.
@main
struct CCBarApp: App {
    /// One shared AppModel for the whole process. Bridges actor-isolated SessionStore
    /// into SwiftUI's @Observable world (see Models/AppModel.swift).
    @State private var appModel = AppModel()

    init() {
        // Redirect stderr to a known file so we can diagnose without relying on
        // `log show` (which often misses NSLog output from sandboxed GUI apps).
        // Sole purpose during development — safe to remove later.
        let logPath = "/tmp/ccbar-debug.log"
        _ = freopen(logPath, "a+", stderr)
        NSLog("=== CCBar app started \(Date()) — debug log: \(logPath) ===")
        // (designated-requirement persistence test: this comment changes the binary)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(appModel)
                .task {
                    // Kick off bootstrap + periodic refresh as soon as the popover view appears.
                    // (The MenuBarExtra holds the content view; this fires once on app launch.)
                    await appModel.start()
                }
        } label: {
            // Template image (single-color) so it adapts to menu bar light/dark mode.
            Image(systemName: "bubble.left.and.bubble.right")
        }
        .menuBarExtraStyle(.window)
    }
}
