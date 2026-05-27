import SwiftUI
import CCBarCore

/// Square icon + tint pair that visually identifies the host (iTerm2 / VS Code / …).
/// SwiftUI doesn't ship vendor logos, so we map each host to an SF Symbol + brand-ish
/// color. Good enough to tell sessions apart at a glance.
struct HostBadge: View {
    let host: HostHint
    var size: CGFloat = 28

    var body: some View {
        let style = badgeStyle()
        Image(systemName: style.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(style.color)
            .frame(width: size, height: size)
            .background(style.color.opacity(0.14), in: .rect(cornerRadius: size * 0.27))
            .help(host.displayName)
    }

    // MARK: - Mapping

    private struct Style { let symbol: String; let color: Color }

    private func badgeStyle() -> Style {
        switch host {
        case .iTerm2:
            return Style(symbol: "apple.terminal", color: .teal)
        case .terminal:
            return Style(symbol: "apple.terminal", color: .secondary)
        case .warp:
            return Style(symbol: "wave.3.right", color: .purple)
        case .ghostty:
            return Style(symbol: "moon.stars", color: .indigo)
        case .vscodeFork(let bundleID, _):
            let lower = bundleID.lowercased()
            if bundleID == "com.google.antigravity" {
                return Style(symbol: "paintbrush.pointed.fill", color: .pink)
            }
            if lower.contains("cursor") {
                return Style(symbol: "cursorarrow.rays", color: .purple)
            }
            if lower.contains("windsurf") {
                return Style(symbol: "wind", color: .cyan)
            }
            return Style(symbol: "chevron.left.forwardslash.chevron.right", color: .blue)
        case .jetbrains:
            return Style(symbol: "hammer.fill", color: .orange)
        case .unknown:
            return Style(symbol: "questionmark.circle", color: .secondary)
        }
    }
}
