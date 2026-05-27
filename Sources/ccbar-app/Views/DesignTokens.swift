import SwiftUI
import AppKit

/// Shared design tokens — keep this small. If a value is used in only one place,
/// leave it inline; only promote to a token when two or more views need to agree.
///
/// Color palette (2026 modern flat trend):
///   - Solid surfaces, no vibrancy/material — easier to read.
///   - Cards sit one step brighter (light) or one step darker-but-distinct (dark)
///     than the popover background, with a subtle shadow + hairline border.
///   - JetBrains Toolbox / Linear / Notion are the closest references.
enum DT {
    static let cardCornerRadius: CGFloat = 12
    static let cardInnerPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 12
    static let cardSpacing: CGFloat = 6
    static let popoverWidth: CGFloat = 420
    static let popoverPadding: CGFloat = 12
    static let popoverMinHeight: CGFloat = 280

    // MARK: - Surface colors

    /// Outermost popover background. Solid (not material) so cards have something
    /// firm to contrast against.
    static let popoverBackground = Color(nsColor: .Surface.popover)
    /// Card surface — one step removed from the popover bg.
    static let cardBackground = Color(nsColor: .Surface.card)
    /// Card border — hairline that emphasizes the card edge in both light/dark.
    static let cardBorder = Color(nsColor: .Surface.cardBorder)
    /// Drop-shadow color (alpha baked in).
    static let cardShadow = Color(nsColor: .Surface.cardShadow)
}

// MARK: - NSColor palette
//
// We define the actual color values inside `NSColor` extensions so they get
// system-level dynamic resolution (light/dark, increase-contrast, etc.) when
// macOS asks them to re-evaluate.

extension NSColor {
    enum Surface {
        static let popover    = NSColor(name: nil) { dynamic($0, light: 0xF5F5F6, dark: 0x1B1B1D) }
        static let card       = NSColor(name: nil) { dynamic($0, light: 0xFFFFFF, dark: 0x2A2A2D) }
        static let cardBorder = NSColor(name: nil) {
            isDark($0)
                ? NSColor.white.withAlphaComponent(0.06)
                : NSColor.black.withAlphaComponent(0.08)
        }
        static let cardShadow = NSColor(name: nil) {
            isDark($0)
                ? NSColor.black.withAlphaComponent(0.40)
                : NSColor.black.withAlphaComponent(0.08)
        }

        /// Robust dark-mode check.
        ///
        /// Simply comparing `appearance.name == .darkAqua` misses every other dark
        /// variant macOS ships (vibrantDark, accessibilityHighContrastDarkAqua,
        /// and any new names a future macOS release introduces — Tahoe 26's
        /// Liquid Glass added more). `bestMatch(from:)` asks the appearance system
        /// itself which of [.aqua, .darkAqua] it is most like.
        private static func isDark(_ appearance: NSAppearance) -> Bool {
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        private static func dynamic(_ appearance: NSAppearance, light: Int, dark: Int) -> NSColor {
            let hex = isDark(appearance) ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green:   CGFloat((hex >>  8) & 0xFF) / 255,
                blue:    CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

// MARK: - Card modifier

extension View {
    /// Standard card chrome: solid surface, hairline border, subtle drop shadow.
    /// Reads cleanly in both light and dark mode, never confused with the
    /// desktop wallpaper behind the popover.
    func ccBarCard() -> some View {
        self
            .padding(DT.cardInnerPadding)
            .background(
                RoundedRectangle(cornerRadius: DT.cardCornerRadius)
                    .fill(DT.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.cardCornerRadius)
                    .stroke(DT.cardBorder, lineWidth: 0.5)
            )
            .shadow(color: DT.cardShadow, radius: 4, y: 1)
    }
}
