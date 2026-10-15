import SwiftUI
import AppKit

/// Keeps the MenuBarExtra popover window the same height as its content.
///
/// The popover's height is driven by `PopoverView.dynamicHeight`, which changes
/// while it's open (search filtering, expanding 최근, the 5s refresh). Left
/// alone, MenuBarExtra grows its window when content gets taller but never
/// shrinks it, so smaller content ended up vertically *centered* in a tall,
/// transparent window — the popover looked detached from the menu bar icon
/// (verified via frame logs: window stayed 810pt tall with its top at the menu
/// bar while the content shrank). We resize the window to `height` ourselves,
/// keeping its top edge where the system placed it.
///
/// The resize runs *synchronously* inside `updateNSView`, i.e. in the same
/// SwiftUI update that changed the content, so content and window commit in
/// one frame. Deferring it (an earlier attempt) showed the shrunken content
/// centered in the old window for a frame — visible flicker.
///
/// Also reports the visible height of the screen the popover is actually on
/// (the menu bar icon's screen), which differs from `NSScreen.main` on
/// multi-display setups.
struct PopoverWindowPinner: NSViewRepresentable {
    let height: CGFloat
    let onScreenHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> PinnerView {
        let v = PinnerView()
        v.onScreenHeight = onScreenHeight
        v.height = height
        return v
    }

    func updateNSView(_ nsView: PinnerView, context: Context) {
        nsView.onScreenHeight = onScreenHeight
        nsView.height = height
        nsView.fitWindow()
    }

    final class PinnerView: NSView {
        var onScreenHeight: ((CGFloat) -> Void)?
        var height: CGFloat = 0
        private weak var observedWindow: NSWindow?
        /// Guards against re-entry: setFrame lays out the hosting view, which
        /// can call back into `updateNSView` before we return.
        private var isFitting = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let nc = NotificationCenter.default
            if let old = observedWindow {
                nc.removeObserver(self, name: nil, object: old)
            }
            observedWindow = window
            guard let window else { return }
            nc.addObserver(self, selector: #selector(didBecomeKey(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: window)
            reportScreenHeight()
            fitWindow()
        }

        @objc private func didBecomeKey(_ note: Notification) {
            reportScreenHeight()
            fitWindow()
        }

        func fitWindow() {
            guard !isFitting, let window, height > 0 else { return }
            let frame = window.frame
            guard abs(frame.height - height) > 0.5 else { return }
            isFitting = true
            defer { isFitting = false }
            let top = frame.maxY
            window.setFrame(
                NSRect(x: frame.minX, y: top - height, width: frame.width, height: height),
                display: true
            )
            NSLog("CCBar popover fit: h \(Int(frame.height)) → \(Int(height)) (top=\(Int(top)))")
        }

        private func reportScreenHeight() {
            guard let h = window?.screen?.visibleFrame.height else { return }
            // Deferred: viewDidMoveToWindow can run mid SwiftUI layout, and
            // mutating @State there triggers "modifying state during update".
            Task { @MainActor [weak self] in self?.onScreenHeight?(h) }
        }
    }
}
