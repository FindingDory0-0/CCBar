import SwiftUI
import AppKit
import CCBarCore

/// Top-level popover content shown when the user clicks the menu bar icon.
///
/// Layout sketch:
///   ┌ 헤더 ─────────────────────────┐
///   │ 💬 Claude Code         [⚙]    │
///   ├──────────────────────────────┤
///   │ [Usage card]                  │
///   │                               │
///   │  활성 (N)                      │
///   │   [Session card]              │
///   │   [Session card] ...          │
///   │                               │
///   │  ⏵ 최근 (8 / 4823)            │
///   │   (expanded → cards)          │
///   └──────────────────────────────┘
struct PopoverView: View {
    @Environment(AppModel.self) private var appModel

    /// Whether the "최근" section is expanded. Default collapsed so active sessions
    /// stay above the fold. State persists for the lifetime of the popover view.
    @State private var showRecent: Bool = false

    /// Search query. Filters by alias, ai-title, cwd path, and last message
    /// previews (case-insensitive substring).
    @State private var searchText: String = ""

    /// How many ended sessions to show beneath the active ones when expanded.
    private let recentEndedLimit = 8

    /// Higher cap during search — the user is looking for a specific session
    /// and shouldn't have to expand "최근" first.
    private let searchEndedLimit = 50

    // MARK: - Dynamic height
    //
    // MenuBarExtra (.window style) doesn't let the user drag-resize the popover.
    // We size the window to fit content, up to 90 % of the visible screen.

    /// Approximate height of one SessionCard incl. inter-row spacing.
    /// Update if the card layout changes meaningfully.
    private let estimatedCardHeight: CGFloat = 88

    private var dynamicHeight: CGFloat {
        // Apply the same filters the view uses, so the popover only sizes
        // itself for what's actually drawn.
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = !trimmedQuery.isEmpty
        let baseVisible = appModel.preferences.showNonInteractive
            ? appModel.sessions
            : appModel.sessions.filter { $0.isInteractive }
        let filtered = isSearching
            ? baseVisible.filter { matches($0, query: trimmedQuery) }
            : baseVisible
        let active = filtered.filter { $0.status != .ended }.count
        let recentTotal = filtered.filter { $0.status == .ended }.count
        let recentLimit = isSearching ? searchEndedLimit : recentEndedLimit
        let recentExpanded = isSearching || showRecent
        let recentVisible = recentExpanded ? min(recentTotal, recentLimit) : 0

        // Chrome: title bar 36 + search bar 48 + usage card ~110 + paddings ~32
        let chromeHeight: CGFloat = 36 + 48 + 110 + 32
        // Section labels: 활성 (always when active>0) + 최근 (always when recentTotal>0)
        let labels: CGFloat = (active > 0 ? 28 : 0) + (recentTotal > 0 ? 28 : 0)
        let cardsHeight = CGFloat(active + recentVisible) * estimatedCardHeight
        // FavoritesStrip is hidden when there are no favorites; otherwise we
        // estimate how many rows the chips will wrap into. Conservative
        // assumption: ~4 chips per row at popover width 420.
        let favoriteCount = appModel.sidecar.favoriteSessions.count
        let favoritesHeight: CGFloat = {
            guard favoriteCount > 0 else { return 0 }
            let chipsPerRow = 4
            let rows = (favoriteCount + chipsPerRow - 1) / chipsPerRow
            // 36 = header label + padding; 26 per chip row
            return 36 + CGFloat(rows) * 26
        }()

        let ideal = chromeHeight + labels + cardsHeight + favoritesHeight
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        let cap = screen * 0.9
        return min(max(ideal, DT.popoverMinHeight), cap)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            searchBar
            accessibilityBanner   // hides itself when permission is granted
            ScrollView {
                VStack(alignment: .leading, spacing: DT.sectionSpacing) {
                    usageCard
                    sessionsArea
                }
                .padding(.horizontal, DT.popoverPadding)
                .padding(.vertical, DT.popoverPadding)
            }
            FavoritesStrip()   // hides itself when there are no favorites
        }
        .frame(width: DT.popoverWidth, height: dynamicHeight)
        // Solid popover surface — overrides the default MenuBarExtra vibrancy
        // so cards stand out clearly regardless of what's behind the menu bar.
        .background(DT.popoverBackground)
        .task {
            await appModel.refreshUsage()
            appModel.refreshAccessibilityTrust()
            appModel.refreshLaunchAtLogin()
        }
    }

    // MARK: - Title bar

    /// Search field just under the title bar. Filters every session-list view
    /// (active + recent) by case-insensitive substring on alias, ai-title,
    /// cwd path, and last user/assistant message previews.
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("별명 · 제목 · 경로 · 미리보기 검색", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("검색어 지우기")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.tertiary, in: .rect(cornerRadius: 8))
        .padding(.horizontal, DT.popoverPadding)
        .padding(.vertical, 8)
        .background(DT.popoverBackground)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    /// Visible only when CCBar lacks Accessibility permission — without it
    /// jumps fall back to "just activate the app" and don't actually reach the
    /// right window when other Spaces / monitors are involved.
    @ViewBuilder
    private var accessibilityBanner: some View {
        if !appModel.accessibilityTrusted {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("점프 기능에 손쉬운 사용 권한이 필요합니다")
                        .font(.caption.weight(.semibold))
                    Text("다른 Space / 모니터의 창으로 가려면 필요해요")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("권한 열기") {
                    appModel.requestAccessibilityPermission()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, DT.popoverPadding)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.08))
            .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.callout)
                .foregroundStyle(.tint)
            Text("Claude Code")
                .font(.headline)
            Spacer()
            if appModel.isBootstrapping {
                ProgressView()
                    .controlSize(.small)
            }
            newSessionMenu
            settingsMenu
        }
        .padding(.horizontal, DT.popoverPadding)
        .padding(.vertical, 10)
        .background(DT.popoverBackground)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }

    /// "+ 새 세션" menu — each suggested cwd has a sub-menu with the four launch
    /// modes (기본 / 대화 이어하기 / 권한 부여 / 권한 부여 · 대화 이어하기).
    private var newSessionMenu: some View {
        Menu {
            let suggestions = appModel.newSessionSuggestions(limit: 10)
            if suggestions.isEmpty {
                Text("최근 사용한 폴더 없음")
                    .foregroundStyle(.secondary)
            } else {
                Section("최근/즐겨찾기 폴더") {
                    ForEach(suggestions, id: \.self) { cwd in
                        Menu(displayLabel(for: cwd)) {
                            ForEach(NewSessionLauncher.Mode.allCases) { mode in
                                Button(mode.label) {
                                    appModel.startNewSession(at: cwd, mode: mode)
                                }
                            }
                        }
                        .help(cwd.path)
                    }
                }
            }
            Divider()
            Menu("다른 폴더…") {
                ForEach(NewSessionLauncher.Mode.allCases) { mode in
                    Button(mode.label) { presentFolderPicker(mode: mode) }
                }
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("새 Claude Code 세션 시작 (iTerm2)")
    }

    /// Show a folder picker and launch a new session at the chosen path.
    private func presentFolderPicker(mode: NewSessionLauncher.Mode = .basic) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "새 세션 시작 (\(mode.label))"
        panel.message = "Claude Code를 시작할 폴더를 선택하세요."
        if panel.runModal() == .OK, let url = panel.url {
            appModel.startNewSession(at: url, mode: mode)
        }
    }

    /// Trim a cwd path for menu display: replace $HOME with ~, last two
    /// components only.
    private func displayLabel(for cwd: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = cwd.path
        if path.hasPrefix(home) { path = "~" + path.dropFirst(home.count) }
        let parts = path.split(separator: "/")
        if parts.count > 3 {
            return ".../" + parts.suffix(2).joined(separator: "/")
        }
        return path
    }

    /// Gear menu in the title bar.
    /// Houses the toast-duration picker and the settings.json injection toggle.
    private var settingsMenu: some View {
        @Bindable var prefs = appModel.preferences
        return Menu {
            // Launch CCBar at login.
            Toggle(isOn: Binding(
                get: { appModel.launchAtLoginEnabled },
                set: { appModel.setLaunchAtLogin($0) }
            )) {
                VStack(alignment: .leading) {
                    Text("Mac 부팅 시 자동 실행")
                    if appModel.launchAtLoginRequiresApproval {
                        Text("시스템 설정 → 로그인 항목에서 허용 필요")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            if appModel.launchAtLoginRequiresApproval {
                Button("로그인 항목 설정 열기") {
                    LaunchAtLogin.openLoginItemsSettings()
                }
            }
            Divider()

            // settings.json injection — drives whether real Claude Code activity
            // triggers our toasts. Without this, only manual fake POSTs fire.
            Toggle(isOn: Binding(
                get: { appModel.hookInjectionInstalled },
                set: { newValue in
                    Task { await appModel.setHookInjection(enabled: newValue) }
                }
            )) {
                VStack(alignment: .leading) {
                    Text("Claude Code 작업 알림 받기")
                    Text("settings.json 에 hook 등록 (첫 설치 시 자동 백업)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            Toggle(isOn: $prefs.showNonInteractive) {
                VStack(alignment: .leading) {
                    Text("claude -p 세션도 표시")
                    Text("일회성 SDK 호출. 기본은 숨김")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            Picker("토스트 자동 닫기", selection: $prefs.toastDuration) {
                ForEach(Preferences.ToastDuration.allCases) { d in
                    Text(d.label).tag(d)
                }
            }
            Divider()
            Button("업데이트 확인…") {
                appModel.updater.checkForUpdates()
            }
            Text("v\(appModel.updater.currentVersion) (build \(appModel.updater.currentBuild))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } label: {
            Image(systemName: "gearshape")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Usage card

    private var usageCard: some View {
        UsageBars()
            .ccBarCard()
    }

    // MARK: - Sessions area

    @ViewBuilder
    private var sessionsArea: some View {
        // Filter out `claude -p` (non-interactive) sessions unless the user
        // explicitly opted in via the settings menu.
        let baseVisible = appModel.preferences.showNonInteractive
            ? appModel.sessions
            : appModel.sessions.filter { $0.isInteractive }
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = !trimmedQuery.isEmpty
        let visible = isSearching
            ? baseVisible.filter { matches($0, query: trimmedQuery) }
            : baseVisible
        let active = visible.filter { $0.status != .ended }
        let endedAll = visible.filter { $0.status == .ended }
        // Lift the "최근" limit during search — the user is hunting for a specific
        // session and shouldn't have to expand the section first.
        let limit = isSearching ? searchEndedLimit : recentEndedLimit
        let endedVisible = endedAll.prefix(limit)
        // Also auto-expand the "최근" section during search so results are visible.
        let recentExpanded = isSearching || showRecent

        if active.isEmpty && endedAll.isEmpty {
            emptyState
        } else {
            if !active.isEmpty {
                activeLabel(count: active.count)
                VStack(spacing: DT.cardSpacing) {
                    ForEach(active) { SessionCard(session: $0) }
                }
            }
            if !endedAll.isEmpty {
                recentToggle(visible: endedVisible.count, total: endedAll.count)
                if recentExpanded {
                    VStack(spacing: DT.cardSpacing) {
                        ForEach(endedVisible) { SessionCard(session: $0) }
                    }
                }
            }
        }
    }

    private func activeLabel(count: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
            Text("활성")
                .font(.subheadline.weight(.semibold))
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }

    /// Clickable header that toggles the "최근" section.
    /// Shows `보이는 / 전체` so the user understands the truncation.
    private func recentToggle(visible: Int, total: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                showRecent.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showRecent ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text("최근")
                    .font(.subheadline.weight(.semibold))
                Text(formatCount(visible: visible, total: total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func formatCount(visible: Int, total: Int) -> String {
        // Show "(8 / 4,823)" when truncated, just "(N)" when everything fits.
        total > visible ? "\(visible) / \(total.formatted())" : "\(total)"
    }

    /// Case-insensitive substring match across display name, ai-title, cwd path,
    /// and last message previews. `query` is assumed already trimmed.
    private func matches(_ session: Session, query: String) -> Bool {
        let q = query.lowercased()
        if appModel.displayName(for: session).lowercased().contains(q) { return true }
        if session.cwd.path.lowercased().contains(q) { return true }
        if let title = session.aiTitle?.lowercased(), title.contains(q) { return true }
        if let last = session.lastAssistantMessage?.lowercased(), last.contains(q) { return true }
        if let user = session.lastUserMessage?.lowercased(), user.contains(q) { return true }
        return false
    }

    private var emptyState: some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 10) {
            Image(systemName: trimmed.isEmpty
                  ? "bubble.left.and.bubble.right"
                  : "magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(
                !trimmed.isEmpty
                    ? "\"\(trimmed)\" 검색 결과 없음"
                    : (appModel.isBootstrapping ? "세션 불러오는 중…" : "Claude Code 세션이 없습니다")
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
