import SwiftUI
import AppKit
import CCBarCore

/// Horizontal row of chips, one per favorited session.
/// Hidden entirely when there are no favorites.
///
/// Each chip shows the session's display name (alias > ai-title > "untitled").
/// Click → copies the session's cwd to the pasteboard (placeholder action until
/// host adapters ship in M4 and can actually focus the session's IDE/terminal).
struct FavoritesStrip: View {
    @Environment(AppModel.self) private var appModel

    /// Resolve favorite session IDs to actual Session values.
    ///
    /// We keep ended sessions in the strip on purpose — they remind the user
    /// "this was the work I was doing in `~/dev/foo`" so they can hop back
    /// over and start a fresh `claude` in the same directory. Click on an
    /// ended chip launches a new session at that cwd; click on a live chip
    /// jumps to it.
    private var favorites: [Session] {
        let ids = appModel.sidecar.favoriteSessions
        guard !ids.isEmpty else { return [] }
        return appModel.sessions.filter { ids.contains($0.id) }
    }

    var body: some View {
        if !favorites.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                    Text("즐겨찾는 세션")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                // Wrap chips onto new rows instead of scrolling sideways.
                WrappingHStack(hSpacing: 6, vSpacing: 6) {
                    ForEach(favorites) { session in
                        chip(for: session)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, DT.popoverPadding)
            .padding(.vertical, 8)
            .background(DT.popoverBackground)
            .overlay(alignment: .top) {
                Divider().opacity(0.6)
            }
        }
    }

    private func chip(for session: Session) -> some View {
        let isEnded = session.status == .ended
        return Button {
            // Live → jump to that session. Ended → spawn a fresh claude run
            // in the same cwd so the user can pick the work back up.
            if isEnded {
                appModel.startNewSession(at: session.cwd)
            } else {
                appModel.focus(session: session)
            }
        } label: {
            HStack(spacing: 4) {
                HostBadge(host: session.hostHint, size: 14)
                Text(appModel.displayName(for: session))
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                if isEnded {
                    // Faint "click to restart" hint at the right edge.
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Circle()
                        .fill(statusColor(for: session.status))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.background.tertiary, in: .capsule)
            .opacity(isEnded ? 0.65 : 1.0)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isEnded {
                Button("이 세션으로 점프") {
                    appModel.focus(session: session)
                }
                Divider()
            }
            Menu("이 폴더에서 새 세션 시작") {
                ForEach(NewSessionLauncher.Mode.allCases) { mode in
                    Button(mode.label) {
                        appModel.startNewSession(at: session.cwd, mode: mode)
                    }
                }
            }
            Divider()
            Button("작업 디렉토리 복사") { copyToPasteboard(session.cwd.path) }
            Button("Finder에서 열기") { revealInFinder(session.cwd) }
            Divider()
            Button("즐겨찾기에서 제거", role: .destructive) {
                Task { await appModel.toggleFavorite(sessionID: session.id) }
            }
        }
        .help(chipTooltip(for: session))
    }

    private func chipTooltip(for session: Session) -> String {
        var lines: [String] = [appModel.displayName(for: session)]
        lines.append("CWD: \(session.cwd.path)")
        lines.append("호스트: \(session.hostHint.displayName) · 상태: \(session.status.rawValue)")
        lines.append("")
        lines.append(session.status == .ended
            ? "클릭: 이 폴더에서 새 세션 시작"
            : "클릭: 이 세션으로 점프")
        return lines.joined(separator: "\n")
    }

    private func statusColor(for status: SessionStatus) -> Color {
        switch status {
        case .running: .green
        case .waiting: .orange
        case .idle:    .blue
        case .ended:   .secondary
        }
    }

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
