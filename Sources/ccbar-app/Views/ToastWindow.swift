import AppKit
import SwiftUI

/// Manages a stack of floating toast panels.
///
/// New toasts insert at the top of the stack (closest to the menu bar icon).
/// Older toasts shift down. Each toast has its own auto-dismiss timer and
/// hover state, so hovering one toast doesn't pause the others' timers.
///
/// Position: anchored under the screen hosting our status item, horizontally
/// centered on the icon's x-coordinate (same heuristic as before — sniff
/// `NSApp.windows` for a tiny window at the menu bar).
@MainActor
final class ToastWindowController {
    /// Cap the visible stack — older toasts are dropped when this is exceeded.
    private let maxToasts: Int = 6
    /// Vertical gap between stacked toasts.
    private let toastSpacing: CGFloat = 6
    /// Horizontal margin from screen edges (and from menu bar).
    private let margin: CGFloat = 12

    private struct ActiveToast {
        let id: UUID
        let panel: NSPanel
        var dismissTask: Task<Void, Never>?
        var isHovered: Bool
    }

    /// Stack of active toasts. Index 0 is the topmost (newest, closest to icon).
    private var toasts: [ActiveToast] = []

    /// User-set dismiss timing. Strong ref (no retain cycle — Preferences has no
    /// back-pointer; weak was unexpectedly going nil on Swift 6).
    private var preferences: Preferences?

    /// Invoked when the user clicks the card body (`onOpen` action).
    var onOpen: ((_ sessionID: UUID?) -> Void)?

    func bind(preferences: Preferences) {
        self.preferences = preferences
    }

    // MARK: - Public

    func show(_ content: ToastContent) {
        let id = UUID()
        let panel = makePanel()

        let view = ToastView(
            content: content,
            onOpen: { [weak self] in
                self?.onOpen?(content.sessionID)
                self?.dismissToast(id: id)
            },
            onDismiss: { [weak self] in
                self?.dismissToast(id: id)
            },
            onHoverChange: { [weak self] hovered in
                self?.setHovered(hovered, for: id)
            }
        )
        // Let the view drive the panel height — body text length varies.
        let hosting = NSHostingView(rootView: view)
        // Make sure the unfilled host area is fully transparent.
        // NSHostingView's default backing color shows through outside the
        // SwiftUI card's rounded corners, which looks like a grey frame on
        // light mode.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 13.0, *) {
            // Keep the hosting view's frame tied to the SwiftUI intrinsic size
            // so the panel doesn't pick up stale shadow/overflow rectangles.
            hosting.sizingOptions = .intrinsicContentSize
        }
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        // Newest at top.
        toasts.insert(ActiveToast(id: id, panel: panel, dismissTask: nil, isHovered: false), at: 0)

        // Trim excess from the bottom (oldest).
        while toasts.count > maxToasts {
            let oldest = toasts.removeLast()
            oldest.dismissTask?.cancel()
            oldest.panel.orderOut(nil)
        }

        layoutToasts()
        panel.orderFrontRegardless()
        scheduleAutoDismiss(id: id)
    }

    /// Close all toasts.
    func dismissAll() {
        for t in toasts {
            t.dismissTask?.cancel()
            t.panel.orderOut(nil)
        }
        toasts.removeAll()
    }

    // MARK: - Per-toast lifecycle

    private func dismissToast(id: UUID) {
        guard let idx = toasts.firstIndex(where: { $0.id == id }) else { return }
        toasts[idx].dismissTask?.cancel()
        toasts[idx].panel.orderOut(nil)
        toasts.remove(at: idx)
        layoutToasts()
    }

    private func setHovered(_ hovered: Bool, for id: UUID) {
        guard let idx = toasts.firstIndex(where: { $0.id == id }) else { return }
        toasts[idx].isHovered = hovered
        if hovered {
            toasts[idx].dismissTask?.cancel()
            toasts[idx].dismissTask = nil
        } else {
            scheduleAutoDismiss(id: id)
        }
    }

    private func scheduleAutoDismiss(id: UUID) {
        guard let idx = toasts.firstIndex(where: { $0.id == id }) else { return }
        toasts[idx].dismissTask?.cancel()
        guard !toasts[idx].isHovered else { return }
        guard let seconds = preferences?.toastDuration.seconds else {
            // User chose "수동으로 닫기" — leave it pinned until they close it
            // (or it gets dropped from the stack when we hit maxToasts).
            return
        }
        toasts[idx].dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.dismissToast(id: id)
        }
    }

    // MARK: - Layout

    /// Re-position every active toast in a vertical stack below the menu bar icon.
    /// Leaves the same gap (`toastSpacing`) between the menu bar and the first
    /// toast as exists between any two stacked toasts — the top of the stack
    /// shouldn't feel glued to the menu bar.
    private func layoutToasts() {
        let (screen, anchorX) = iconScreenAndCenterX()
        let visible = screen.visibleFrame
        var currentY = visible.maxY - toastSpacing

        for toast in toasts {
            let width = toast.panel.frame.width
            let height = toast.panel.frame.height
            currentY -= height

            let proposedX = anchorX - width / 2
            let clampedX = min(max(proposedX, visible.minX + margin), visible.maxX - width - margin)
            toast.panel.setFrameOrigin(NSPoint(x: clampedX, y: currentY))

            currentY -= toastSpacing
        }
    }

    /// Find the screen to place the toast on, and the x-coordinate to anchor
    /// horizontally around.
    ///
    /// Priority:
    ///   1. Screen containing the mouse cursor (where the user is actually looking).
    ///   2. If that screen has its own menu bar with our status item, anchor under
    ///      the icon. Otherwise, fall back to that screen's right edge.
    ///   3. If even the mouse screen can't be determined, fall back to the
    ///      original status-item screen, then to `NSScreen.main`.
    private func iconScreenAndCenterX() -> (NSScreen, CGFloat) {
        let mouseLocation = NSEvent.mouseLocation

        // Find the screen the cursor is currently on.
        if let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            if let iconX = iconCenterX(on: mouseScreen) {
                return (mouseScreen, iconX)
            }
            // Mouse screen has no menu bar (single-menubar mode) — right-align there.
            return (mouseScreen, mouseScreen.visibleFrame.maxX - 200)
        }

        // Fallback: any screen hosting our status item.
        for screen in NSScreen.screens {
            if let iconX = iconCenterX(on: screen) {
                return (screen, iconX)
            }
        }
        let fallback = NSScreen.main ?? NSScreen.screens.first!
        return (fallback, fallback.visibleFrame.maxX - 200)
    }

    /// Returns the x-coordinate of our status item on `screen`, or nil if the
    /// status item lives on a different screen.
    private func iconCenterX(on screen: NSScreen) -> CGFloat? {
        let toastPanels = Set(toasts.map(\.panel).map(ObjectIdentifier.init))
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        for w in NSApp.windows {
            guard w.isVisible, w.screen === screen else { continue }
            if toastPanels.contains(ObjectIdentifier(w)) { continue }
            let f = w.frame
            let atMenuBarTop = abs(f.maxY - screen.frame.maxY) < menuBarHeight + 4
            let smallEnough = f.width < 60 && f.height < menuBarHeight + 8
            if atMenuBarTop && smallEnough {
                return f.midX
            }
        }
        return nil
    }

    // MARK: - Panel factory

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // System shadow follows the alpha shape of the content (our rounded
        // card), so we don't have to paint shadows in SwiftUI and risk leaking
        // grey artifacts outside the rounded corners.
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        return panel
    }
}
