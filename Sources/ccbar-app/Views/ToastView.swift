import SwiftUI
import CCBarCore

/// Visual model for a single toast.
struct ToastContent: Identifiable, Equatable {
    let id: UUID = UUID()
    let kind: Kind
    /// Header line — usually the session name (alias or auto-title).
    let title: String
    /// Optional subtitle below the title — shows the iTerm window name (or
    /// other host identifier) so the user can tell *which* iTerm window
    /// fired this when the alias is ambiguous (e.g. two sessions with
    /// similar names, or an old `claude -c` continuation under a stale
    /// alias).
    let subtitle: String?
    /// Optional second body line — last assistant text, or the Notification message.
    let body: String?
    let sessionID: UUID?

    enum Kind: Equatable {
        case completed       // Stop hook — green check
        case waiting         // Notification — orange warning
        case info            // SessionStart, future generic events

        var symbol: String {
            switch self {
            case .completed: "checkmark.circle.fill"
            case .waiting:   "exclamationmark.triangle.fill"
            case .info:      "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .completed: .green
            case .waiting:   .orange
            case .info:      .blue
            }
        }
    }
}

/// SwiftUI content for the toast NSPanel.
///
/// Interaction model:
///   - Click anywhere on the card → `onOpen` (will focus the session's IDE/terminal
///     once host adapters land in M4).
///   - Click the circled-X at top-right → `onDismiss`.
///   - Hover anywhere → pauses the auto-dismiss timer (handled by parent via
///     `onHoverChange`).
struct ToastView: View {
    let content: ToastContent
    let onOpen: () -> Void
    let onDismiss: () -> Void
    let onHoverChange: (Bool) -> Void

    var body: some View {
        // No arrow — once we stack multiple toasts, only the topmost would
        // be visually attached to the menu bar icon. Plain floating cards
        // anchored to the top-right read more naturally as a notification queue.
        cardWithClose
            .fixedSize()         // freeze the SwiftUI intrinsic size for NSHostingView
            .background(Color.clear)
            .onHover { hovered in
                onHoverChange(hovered)
            }
    }

    private var cardWithClose: some View {
        ZStack(alignment: .topTrailing) {
            // Whole-card tap target. Plain style keeps the visual to whatever the
            // `card` itself draws — no default button chrome.
            Button(action: onOpen) {
                card
            }
            .buttonStyle(.plain)

            closeButton
                .padding(8)
        }
    }

    /// Solid-circle X in the top-right corner.
    ///
    /// `xmark.circle.fill` is rendered in palette mode so we get a darker glyph on
    /// a translucent background, which works in both light and dark menu bars.
    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.secondary, .background.secondary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("닫기")
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: content.kind.symbol)
                .font(.title3)
                .foregroundStyle(content.kind.tint)
                .frame(width: 24, height: 24)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(content.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let sub = content.subtitle, !sub.isEmpty {
                    // "어느 창에서 발화" 단서. 별명이 인식과 어긋날 때
                    // 즉시 판별할 수 있도록 살짝 흐린 단색으로.
                    Text(sub)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let body = content.body, !body.isEmpty {
                    Text(body)
                        .font(.caption)
                        // Body == actual message. Keep close to primary so it
                        // stays readable on both light and dark surfaces.
                        .foregroundStyle(.primary.opacity(0.78))
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        // Extra trailing padding so long body text doesn't slip under the X.
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 32))
        .frame(width: 340, alignment: .topLeading)
        .contentShape(Rectangle())
        // Solid card surface — same palette as popover cards. No vibrancy.
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(DT.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(DT.cardBorder, lineWidth: 0.5)
        )
        // Shadow is drawn by NSPanel.hasShadow (see ToastWindowController). Using
        // SwiftUI's .shadow here leaked grey artifacts outside the rounded edges
        // because the shadow lives outside NSHostingView's frame and got clipped.
        .help("클릭하여 열기")
    }
}

