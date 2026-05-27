import SwiftUI
import AppKit
import CCBarCore

/// One row in the popover representing a single Claude Code session.
///
/// Right-click → rename alias, toggle favorite, copy cwd. Hover shows a longer
/// preview tooltip with the last user + assistant exchange.
struct SessionCard: View {
    @Environment(AppModel.self) private var appModel

    let session: Session

    /// Inline editing state. When true the title row swaps to a TextField.
    /// We use inline edit instead of a .sheet because SwiftUI sheets outlive
    /// the MenuBarExtra popover (closing the popover doesn't dismiss the sheet),
    /// which is confusing.
    @State private var isRenaming = false
    @State private var renameInput = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HostBadge(host: session.hostHint, size: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                titleRow
                metaRow
                if let preview = previewText, !preview.isEmpty {
                    // Preview reads as actual content — keep it close to primary
                    // so it doesn't blend into the card background.
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .ccBarCard()
        .overlay(alignment: .topLeading) {
            statusPip
                .offset(x: -4, y: -4)
        }
        .contentShape(Rectangle())
        // Left-click → jump to this session's host (iTerm2 / VS Code / …).
        // Suppressed while renaming so clicking inside the TextField doesn't fire.
        .onTapGesture {
            guard !isRenaming else { return }
            appModel.focus(session: session)
        }
        .help(hoverTooltip)
        .contextMenu { contextMenuItems }
    }

    // MARK: - Title row

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !isRenaming && hasAlias {
                Image(systemName: "tag.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .help("사용자 지정 별칭")
            }
            if appModel.isFavorite(sessionID: session.id) && !isRenaming {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .help("즐겨찾는 세션")
            }

            if isRenaming {
                TextField(session.defaultDisplayName, text: $renameInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
                    .onAppear { renameFocused = true }
                Button("취소", action: cancelRename)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            } else {
                Text(displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            if !isRenaming {
                tokenChip
            }
        }
    }

    // MARK: - Rename actions

    private func startRename() {
        renameInput = appModel.alias(for: session.id) ?? ""
        isRenaming = true
    }

    private func commitRename() {
        let value = renameInput
        Task { await appModel.setAlias(value, for: session.id) }
        isRenaming = false
    }

    private func cancelRename() {
        isRenaming = false
        renameInput = ""
    }

    private var tokenChip: some View {
        Text(formatTokens(session.usage.newTokens))
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.background.tertiary, in: .capsule)
            .help("입력+출력 \(session.usage.newTokens.formatted()) tok  ·  캐시 \(session.usage.cacheTokens.formatted()) tok")
    }

    // MARK: - Meta

    private var metaRow: some View {
        HStack(spacing: 4) {
            Text(abbreviatedCwd)
                .lineLimit(1)
                .truncationMode(.middle)
            separator
            // Prefer the concrete iTerm window name when we have it cached
            // (filled by hook from this session's TTY) — it identifies the
            // exact window much more usefully than just "iTerm2".
            if let windowName = appModel.windowLabel(for: session) {
                Text(windowName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(session.hostHint.displayName)
            }
            separator
            Text(relativeTime)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    // MARK: - Status pip

    @ViewBuilder
    private var statusPip: some View {
        if session.status != .ended {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(.background, lineWidth: 1.5))
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(hasAlias ? "이름 다시 지정…" : "이름 지정…") {
            startRename()
        }
        if hasAlias {
            Button("기본 이름으로 되돌리기") {
                Task { await appModel.setAlias(nil, for: session.id) }
            }
        }
        Divider()
        Button(appModel.isFavorite(sessionID: session.id) ? "즐겨찾기 해제" : "즐겨찾기 추가") {
            Task { await appModel.toggleFavorite(sessionID: session.id) }
        }
        Divider()
        Button("작업 디렉토리 복사") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(session.cwd.path, forType: .string)
        }
        Button("세션 ID 복사") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(session.id.uuidString, forType: .string)
        }
    }

    // MARK: - Hover tooltip
    //
    // SwiftUI's .help() is plain text only — fine for a richer-than-card-preview
    // glance but not for full markdown rendering. A real hover popover with the
    // last 5 turns is a future enhancement (would need its own popover/overlay).

    private var hoverTooltip: String {
        var lines: [String] = []
        lines.append("이름: \(displayName)")
        if hasAlias { lines.append("(기본: \(session.defaultDisplayName))") }
        lines.append("CWD: \(session.cwd.path)")
        lines.append("호스트: \(session.hostHint.displayName)  ·  메시지 \(session.messageCount)개")
        lines.append("입력+출력 \(session.usage.newTokens.formatted()) tok  ·  캐시 \(session.usage.cacheTokens.formatted()) tok")
        if let last = session.lastAssistantMessage, !last.isEmpty {
            lines.append("")
            lines.append("최근 응답:")
            lines.append(String(last.prefix(400)))
        } else if let user = session.lastUserMessage, !user.isEmpty {
            lines.append("")
            lines.append("최근 사용자 메시지:")
            lines.append(String(user.prefix(400)))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Computed

    private var hasAlias: Bool {
        appModel.alias(for: session.id) != nil
    }

    private var displayName: String {
        appModel.displayName(for: session)
    }

    private var statusColor: Color {
        switch session.status {
        case .running: .green
        case .waiting: .orange
        case .idle: .blue
        case .ended: .secondary
        }
    }

    private var previewText: String? {
        session.lastAssistantMessage ?? session.lastUserMessage
    }

    private var abbreviatedCwd: String {
        let path = session.cwd.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: session.lastActivity, relativeTo: Date())
    }

    private func formatTokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }
}

