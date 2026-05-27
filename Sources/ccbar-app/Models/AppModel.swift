import Foundation
import Observation
import AppKit
import CCBarCore

/// MainActor-isolated @Observable wrapper around the actor-based SessionStore.
///
/// SwiftUI views read `sessions` directly; the model takes care of:
///   - one-shot bootstrap on launch
///   - attaching JSONLWatcher so FSEvents drive incremental updates
///   - periodic ProcessProbe refresh so `.idle`/`.ended` stays current
///
/// All public state mutations happen on the MainActor; the actor methods on
/// SessionStore are awaited from a background Task.
@MainActor
@Observable
final class AppModel {
    /// All known sessions, sorted by lastActivity desc. Drives the UI.
    private(set) var sessions: [Session] = []
    private(set) var lastBootstrapAt: Date?
    private(set) var isBootstrapping = false

    // MARK: - Subscription usage state

    /// Latest usage snapshot. Nil before the first popover open.
    private(set) var usage: SubscriptionUsage?
    /// Last fetch error surfaced to the UI for diagnostic display.
    private(set) var usageError: UsageApiClient.Failure?
    /// True while a fetch is in flight; UI shows a small spinner.
    private(set) var usageIsLoading = false

    // MARK: - Sidecar (user-set aliases, favorites)

    /// Cached snapshot of the user's sidecar. Views read this directly; mutations go
    /// through `setAlias`/`toggleFavorite` so the disk write and the cache stay in sync.
    private(set) var sidecar: Sidecar = .empty

    // MARK: - User preferences

    /// Persistent UI knobs (e.g. toast dismiss timing). Views observe directly.
    let preferences = Preferences()

    /// Sparkle wrapper. Holds the SPUStandardUpdaterController for the whole
    /// app lifetime; created once during AppModel init so background checks
    /// start immediately (no popover required).
    @ObservationIgnored
    let updater = AppUpdater()

    // MARK: - Hook reception

    /// Most recently received hook event. Surfaced so the UI can show a transient
    /// indicator that "something just happened" while we wire up the proper toast
    /// (M3 Phase C).
    private(set) var lastHook: HookEvent?

    /// Cache of iTerm window names keyed by TTY path (e.g. "/dev/ttys003").
    /// Populated lazily from `handle(hookEvent:)` whenever a hook's `ttyPath`
    /// hasn't been resolved yet. Used by the toast / card UI to show a
    /// "where it actually fired" hint alongside the user-set alias —
    /// invaluable when an old `claude -c` continuation has drifted from
    /// the alias the user originally gave it.
    private(set) var iTermWindowByTTY: [String: String] = [:]
    /// Local HTTP server port (0 until HookServer is ready). Persisted to a file
    /// so the user's shell hooks can locate us.
    private(set) var hookServerPort: UInt16 = 0

    // MARK: - Hook injection (settings.json)

    /// True when our hook entries are present in `~/.claude/settings.json`.
    /// Drives the Settings menu toggle.
    private(set) var hookInjectionInstalled: Bool = false

    /// True when CCBar has macOS Accessibility (손쉬운 사용) permission.
    /// Without this, jumps across Spaces/displays don't work.
    private(set) var accessibilityTrusted: Bool = false

    /// True when CCBar is registered to launch at login. Mirrors
    /// SMAppService.mainApp.status — flipped in lockstep with the ⚙ toggle.
    private(set) var launchAtLoginEnabled: Bool = false
    /// True when the user has globally disabled CCBar in System Settings →
    /// Login Items, so our register() returns `.requiresApproval` and the
    /// auto-launch won't actually happen. Surfaced in the UI.
    private(set) var launchAtLoginRequiresApproval: Bool = false

    /// Underlying store. Hidden from views; everything flows through `sessions`.
    private let store = SessionStore()
    private let watcher = JSONLWatcher()
    private let usageClient = UsageApiClient()
    private let sidecarStore = SidecarStore()
    private let settingsInjector = SettingsInjector()
    private let hostRouter = HostRouter.default
    private var hookServer: HookServer?
    /// Owns the floating toast NSPanel. Created lazily on first hook event.
    /// `@ObservationIgnored` because (a) it's pure infrastructure (no view binds to it)
    /// and (b) `@Observable` macros don't compose with `lazy var`.
    @ObservationIgnored
    private lazy var toaster: ToastWindowController = {
        let t = ToastWindowController()
        t.bind(preferences: preferences)
        t.onOpen = { [weak self] sessionID in
            self?.requestPopoverOpen(focusing: sessionID)
        }
        return t
    }()

    private var watcherTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init() {
        // Kick off bootstrap + HookServer immediately so we don't depend on the
        // popover being opened. PopoverView still calls .task { await start() }
        // for safety; start() is idempotent thanks to the lastBootstrapAt guard.
        Task { @MainActor in
            await self.start()
        }
    }

    /// Kick off all background work. Idempotent — safe to call from .task multiple times.
    func start() async {
        guard !isBootstrapping, lastBootstrapAt == nil else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }

        // Start HookServer first — it's independent of session bootstrap and we want
        // the port file to exist as soon as possible so hook scripts can find us.
        await startHookServer()
        // Load sidecar quickly (single small file).
        sidecar = await sidecarStore.current()
        // Reflect any pre-existing CCBar hook entries (e.g. from a previous install).
        await refreshHookInjectionState()
        refreshLaunchAtLogin()

        // First-time prompt for Accessibility if we don't already have it.
        // This is non-blocking — macOS shows the system prompt asynchronously.
        // If the user already granted, this call is a no-op.
        accessibilityTrusted = AccessibilityRaise.isTrusted(prompt: true)

        // Two-phase bootstrap: load the most-recent ~150 sessions synchronously
        // so the popover is usable in well under a second, then finish the
        // rest in the background. With ~5,000 historical sessions a full
        // bootstrap takes ~6s; this hides that cost from the user.
        do {
            try await store.bootstrap(limit: 150)
        } catch {
            NSLog("CCBar bootstrap (quick) failed: \(error)")
        }
        await store.refreshProcessInfo()
        await refresh()
        lastBootstrapAt = Date()

        attachWatcher()
        startPeriodicRefresh()

        // Finish ingesting older sessions in the background — UI is already
        // responsive, just keep the data complete for "전체 보기" / search.
        Task.detached { [store] in
            do {
                try await store.bootstrapRemainder()
            } catch {
                NSLog("CCBar bootstrap (remainder) failed: \(error)")
            }
        }
    }

    // MARK: - Hook injection (settings.json)

    /// Re-check whether our hook entries are still in settings.json. Called from
    /// `start()` and after every install/uninstall. Also sweeps stale CCBar
    /// script paths from older installs (e.g. the pre-fix path that contained
    /// a literal space and broke `/bin/sh`).
    func refreshHookInjectionState() async {
        do {
            try await settingsInjector.sweepStalePaths()
        } catch {
            NSLog("CCBar stale-path sweep failed: \(error)")
        }
        hookInjectionInstalled = await settingsInjector.isInstalled()
    }

    /// Toggle entry point for the settings UI.
    /// - `enabled = true`: backs up settings.json once, adds our entries to all
    ///   supported hook events.
    /// - `enabled = false`: removes only our entries; user hooks stay.
    func setHookInjection(enabled: Bool) async {
        do {
            if enabled {
                try await settingsInjector.install()
            } else {
                try await settingsInjector.uninstall()
            }
        } catch {
            NSLog("CCBar settings injection failed: \(error)")
        }
        await refreshHookInjectionState()
    }

    // MARK: - HookServer lifecycle

    /// Start the local HTTP listener and write the chosen port to a well-known file
    /// (`~/Library/Application Support/CCBar/port`) so the user's shell hook scripts
    /// can discover us.
    private func startHookServer() async {
        // Capture `self` weakly inside the @Sendable handler; jump to MainActor to
        // mutate observable state.
        let server = HookServer { [weak self] event in
            Task { @MainActor in
                self?.handle(hookEvent: event)
            }
        }
        // Debug-only /focus endpoint so we can drive jumps from curl without
        // having to click a card. The HookServer callback runs on its own
        // background queue, so dispatch the actual focus work to the MainActor.
        // The synchronous return is optimistic — we can't await an async hop
        // here, so we always respond 204 and let logs show whether focus
        // actually found a session.
        server.focusHandler = { [weak self] sessionID in
            Task { @MainActor in
                guard let self else { return }
                self.focus(sessionID: sessionID)
            }
            return true
        }
        do {
            let port = try await server.start()
            self.hookServer = server
            self.hookServerPort = port
            writePortFile(port: port)
            NSLog("CCBar HookServer listening on 127.0.0.1:\(port)")
        } catch {
            NSLog("CCBar HookServer failed to start: \(error)")
        }
    }

    /// Apply the hook event to the SessionStore (Phase B), record it for UI
    /// (`lastHook`), refresh the view snapshot, and (Phase C) raise a toast for
    /// user-facing events (Stop / Notification).
    private func handle(hookEvent event: HookEvent) {
        lastHook = event
        NSLog("CCBar hook \(event.rawEventName) session=\(event.sessionID?.uuidString ?? "?") tty=\(event.ttyPath ?? "-") msg=\(event.message ?? "")")
        Task { [weak self] in
            guard let self else { return }
            await self.store.applyHookEvent(event)
            await self.refresh()
            self.maybeShowToast(for: event)
        }
        // Fill the iTerm window-name cache for any new TTY we see. This makes
        // the next toast / card render show "별명 · 창이름" instead of just the
        // alias — important when the user has multiple sessions sharing an
        // alias or cwd. Cheap because we only do the AppleScript round-trip
        // once per unique TTY.
        if let tty = event.ttyPath, iTermWindowByTTY[tty] == nil {
            Task { [weak self] in
                guard let self else { return }
                if let name = await iTermWindowName(forTTY: tty) {
                    await MainActor.run { [weak self] in
                        self?.iTermWindowByTTY[tty] = name
                    }
                }
            }
        }
    }

    /// Human-friendly identifier for the iTerm window that currently hosts
    /// `session` — falls back to nil if we haven't resolved it yet (the cache
    /// is filled by the first hook from a TTY).
    func windowLabel(for session: Session) -> String? {
        switch session.hostHint {
        case .iTerm2(let tty), .terminal(let tty):
            return iTermWindowByTTY[tty]
        default:
            return nil
        }
    }

    /// Decide whether `event` deserves a toast and render it.
    private func maybeShowToast(for event: HookEvent) {
        let kind: ToastContent.Kind
        switch event.kind {
        case .stop:         kind = .completed
        case .notification: kind = .waiting
        default:            return     // SessionStart / PreToolUse / PostToolUse don't toast
        }

        // Look up the affected session so we can show a meaningful title/preview.
        let session = sessions.first { $0.id == event.sessionID }

        // Honor the "show -p sessions" preference for toasts too — no point
        // surfacing a one-shot sdk-cli completion if the user said "hide those".
        if let session, !session.isInteractive, !preferences.showNonInteractive {
            return
        }

        // Idle-reminder filter — Claude Code's Notification hook fires for
        // two distinct cases: (a) a real permission prompt the user must
        // answer, and (b) an idle reminder that pops ~60s after Stop when
        // the user hasn't typed anything. Case (b) duplicates the Stop
        // toast and adds no information, so we mute it here. The two
        // variants are distinguishable by the hook's `message` text:
        //   "Claude needs your permission …"     ← keep
        //   "Claude is waiting for your input"   ← drop
        // Using `contains` instead of an exact match so future minor
        // wording changes from Claude Code still match.
        if event.kind == .notification,
           let msg = event.message,
           msg.contains("waiting for your input") {
            return
        }

        // Skill auto-loop filter — skip toasts when the session's most recent
        // user message is a self-driven skill invocation (e.g. oh-my-claudecode's
        // ralph/ULTRAWORK loop, ai-slop-cleaner, …). Those messages don't
        // represent a human-driven turn the user is waiting on, and they fire
        // continuously — spamming toasts for hours from a window the user
        // has forgotten about. The signature prefix is stable across these
        // skills: they all start with "Base directory for this skill:".
        //
        // We probe the jsonl on disk first because the in-memory
        // `session.lastUserMessage` can lag behind by one turn — FSEvents
        // can deliver the skill's user record after the corresponding Stop
        // hook arrives, especially right after app launch while bootstrap
        // is still catching up. Disk read gives us the ground truth at the
        // moment of the hook for a one-shot ~5 ms cost.
        if let session {
            let probe = Self.lastUserMessageOnDisk(at: session.jsonlPath)
                ?? session.lastUserMessage
            if Self.isSkillAutoLoop(message: probe) {
                return
            }
        }

        let title: String = {
            if let s = session { return displayName(for: s) }
            return event.title ?? "Claude Code"
        }()
        let body: String? = {
            switch kind {
            case .completed:
                // Stop → show the last assistant message preview if we have one.
                if let last = session?.lastAssistantMessage, !last.isEmpty {
                    return String(last.prefix(240))
                }
                return "응답 완료"
            case .waiting:
                // Notification → use the hook's `message` (e.g. permission text).
                return event.message ?? "사용자 입력 대기"
            case .info:
                return event.message
            }
        }()

        // Subtitle: iTerm window name for this session's TTY. The hook event
        // itself carries `ttyPath`, so we look up the cache directly even
        // if we haven't matched the session in `sessions` yet (e.g. brand
        // new session that hook arrived for before bootstrap finished
        // ingesting it). Falls back to nil → toast just shows title+body.
        let subtitle: String? = {
            if let tty = event.ttyPath, let name = iTermWindowByTTY[tty] {
                return name
            }
            if let session, let name = windowLabel(for: session) {
                return name
            }
            return nil
        }()

        toaster.show(ToastContent(
            kind: kind,
            title: title,
            subtitle: subtitle,
            body: body,
            sessionID: event.sessionID
        ))
    }

    /// Hook for toast click + popover card tap. Asks HostRouter to bring the
    /// session's IDE / terminal window to the front.
    private func requestPopoverOpen(focusing sessionID: UUID?) {
        guard let sessionID,
              let session = sessions.first(where: { $0.id == sessionID })
        else {
            NSLog("CCBar focus: no session for \(sessionID?.uuidString ?? "nil")")
            return
        }
        Task { [hostRouter] in
            await hostRouter.focus(session: session)
        }
    }

    /// Public entry point for SessionCard taps. Same path as the toast open
    /// action — kept as a separate name for readability in the view layer.
    func focus(session: Session) {
        Task { [hostRouter] in
            await hostRouter.focus(session: session)
            await MainActor.run { [weak self] in
                self?.refreshAccessibilityTrust()
            }
        }
    }

    /// Quick check (no prompt). Called when the popover opens so the UI can
    /// surface a permission banner if needed.
    func refreshAccessibilityTrust() {
        accessibilityTrusted = AccessibilityRaise.isTrusted(prompt: false)
    }

    /// Sync our cached `launchAtLogin*` flags with SMAppService.
    func refreshLaunchAtLogin() {
        let s = LaunchAtLogin.status
        launchAtLoginEnabled = (s == .enabled)
        launchAtLoginRequiresApproval = (s == .requiresApproval)
    }

    /// Toggle entry point for the ⚙ menu.
    func setLaunchAtLogin(_ enabled: Bool) {
        let result = LaunchAtLogin.setEnabled(enabled)
        launchAtLoginEnabled = (result == .enabled)
        launchAtLoginRequiresApproval = (result == .requiresApproval)
    }

    /// Open System Settings to the Accessibility pane and request a fresh
    /// permission check (with the prompt this time).
    func requestAccessibilityPermission() {
        _ = AccessibilityRaise.isTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - New session

    /// Start a fresh `claude` session in a new iTerm2 window at `cwd`.
    /// `mode` controls the exact flags (continue last / skip permissions / both).
    /// Logs the error path for now; future revision will surface failure as
    /// a toast.
    func startNewSession(at cwd: URL, mode: NewSessionLauncher.Mode = .basic) {
        Task {
            do {
                try await NewSessionLauncher.launch(host: .iTerm2, cwd: cwd, mode: mode)
            } catch {
                NSLog("[AppModel] startNewSession failed for \(cwd.path): \(error)")
            }
        }
    }

    /// Suggestions for the "+ 새 세션" menu: favorites first (user-pinned), then
    /// recently-active cwds that aren't already a favorite. Capped so the menu
    /// stays manageable.
    func newSessionSuggestions(limit: Int = 8) -> [URL] {
        var seen = Set<URL>()
        var out: [URL] = []
        // 1) Favorites: ordered by the user's pin order on the cwd they belong to.
        let favoriteCwds = sidecar.favoriteSessions.compactMap { id in
            sessions.first { $0.id == id }?.cwd.standardizedFileURL
        }
        for cwd in favoriteCwds where seen.insert(cwd).inserted {
            out.append(cwd)
            if out.count >= limit { return out }
        }
        // 2) Recent cwds from sessions (sessions is already sorted by lastActivity desc).
        for session in sessions {
            let cwd = session.cwd.standardizedFileURL
            if seen.insert(cwd).inserted {
                out.append(cwd)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// Trigger a focus jump for an arbitrary session ID. Used by the HookServer
    /// `/focus` endpoint for headless debugging — we POST a session ID and the
    /// app drives the host adapter the same way as a UI click.
    func focus(sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            NSLog("[AppModel] focus(sessionID:) — no session for \(sessionID)")
            return
        }
        focus(session: session)
    }

    private func writePortFile(port: UInt16) {
        let url = AppModel.portFileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "\(port)\n".write(to: url, atomically: true, encoding: .utf8)
            installSendHookScript()
        } catch {
            NSLog("CCBar port file write failed: \(error)")
        }
    }

    /// Installs (overwrites) a shell helper that forwards Claude Code hook
    /// stdin JSON to our local listener.
    ///
    /// Path: `~/.claude/ccbar/send-hook.sh` (intentionally space-free — see
    /// `SettingsInjector.sendHookScriptURL` for why).
    private func installSendHookScript() {
        let scriptURL = SettingsInjector.sendHookScriptURL
        let dir = scriptURL.deletingLastPathComponent()
        let portFilePath = AppModel.portFileURL.path
        // We enrich the stdin JSON with `_ccbar_tty`, looked up from the
        // claude PID ($PPID). This lets SessionStore.applyHookEvent pin the
        // session's hostHint to the *exact* iTerm tab that fired the hook,
        // dodging the ambiguity when several claude sessions share a cwd.
        // sed-based injection: we splice ",\"_ccbar_tty\":\"...\"" before
        // the final `}` of the payload. Hook payloads are emitted as a
        // single-line JSON object, so matching the last `}` is safe.
        // Falls back gracefully (no key inserted) if anything fails.
        let script = """
        #!/bin/bash
        # CCBar hook forwarder — sends Claude Code hook stdin JSON to the local app.
        # Silent no-op when CCBar isn't running. Never blocks Claude Code longer than 2s.
        set -euo pipefail
        PORT_FILE="\(portFilePath)"
        [ -f "$PORT_FILE" ] || exit 0
        PORT=$(cat "$PORT_FILE")
        [ -n "$PORT" ] || exit 0

        # Capture the originating claude's TTY (PPID = the claude process invoking us).
        CCBAR_TTY=""
        if TTY_RAW=$(ps -p "$PPID" -o tty= 2>/dev/null); then
            TTY_TRIMMED=$(printf '%s' "$TTY_RAW" | tr -d ' \\t\\n')
            if [ -n "$TTY_TRIMMED" ] && [ "$TTY_TRIMMED" != "??" ]; then
                CCBAR_TTY="/dev/$TTY_TRIMMED"
            fi
        fi

        PAYLOAD=$(cat)
        if [ -n "$CCBAR_TTY" ]; then
            # Splice "_ccbar_tty":"<path>" before the closing brace. Use a
            # literal '\\x00' separator so slashes in the path don't trip sed.
            ENRICHED=$(printf '%s' "$PAYLOAD" | sed -e "s|}[[:space:]]*$|,\\"_ccbar_tty\\":\\"$CCBAR_TTY\\"}|")
            [ -n "$ENRICHED" ] && PAYLOAD="$ENRICHED"
        fi

        printf '%s' "$PAYLOAD" | curl -s --max-time 2 -X POST "http://127.0.0.1:$PORT/event" \\
            -H "Content-Type: application/json" \\
            --data-binary @- > /dev/null 2>&1 || true
        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            NSLog("CCBar send-hook.sh install failed: \(error)")
        }
    }

    /// Public so the future settings UI / hook scripts can refer to the same path.
    public static var portFileURL: URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("CCBar/port", isDirectory: false)
    }

    // MARK: - Sidecar mutations

    /// Resolve a session's display name.
    ///
    /// Aliases are **per-session only** — even sessions in the same project
    /// directory display independently. We used to inherit a "project alias"
    /// across sessions in the same cwd, but that conflated independent
    /// conversations (two `claude` runs in the same folder, on different
    /// tasks) under one name. Per-session is the cleaner mental model:
    /// "this card is this conversation".
    func displayName(for session: Session) -> String {
        if let alias = sidecar.aliases[session.id], !alias.isEmpty {
            return alias
        }
        return session.defaultDisplayName
    }

    /// True if `message` looks like an automated skill-invocation payload that
    /// oh-my-claudecode (and similar tools) emit on every loop iteration —
    /// `ralph`, `ULTRAWORK`, `ai-slop-cleaner`, … they all share the prefix
    /// `Base directory for this skill:`. Used by `maybeShowToast` to mute
    /// notifications on background self-driven loops so the bar doesn't get
    /// spammed for hours from a forgotten iTerm window.
    static func isSkillAutoLoop(message: String?) -> Bool {
        guard let m = message else { return false }
        return m.hasPrefix("Base directory for this skill:")
    }

    /// Tail-read the jsonl and return the most recent `user`-role message text.
    ///
    /// Used by `maybeShowToast` to dodge a race against FSEvents: when a Stop
    /// hook arrives microseconds after the skill loop's user record was written,
    /// `SessionStore.lastUserMessage` may still hold the previous turn's value.
    /// Reading the tail of the file directly is cheap (we only scan the last
    /// 64 KB) and gives us the ground truth at the moment the hook fires.
    ///
    /// Returns `nil` on any IO/decoding failure — the caller falls back to
    /// the in-memory value, so this is a best-effort probe, not load-bearing.
    static func lastUserMessageOnDisk(at url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        let end: UInt64
        do { end = try fh.seekToEnd() } catch { return nil }
        guard end > 0 else { return nil }
        let window: UInt64 = 64 * 1024
        let start = end > window ? end - window : 0
        do { try fh.seek(toOffset: start) } catch { return nil }

        let data: Data
        do { data = try fh.readToEnd() ?? Data() } catch { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        // Walk lines in reverse so we hit the most recent record first.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let raw = line.data(using: .utf8),
                  let any = try? JSONSerialization.jsonObject(with: raw),
                  let obj = any as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  (msg["role"] as? String) == "user"
            else { continue }

            if let s = msg["content"] as? String { return s }
            if let arr = msg["content"] as? [[String: Any]] {
                for part in arr {
                    if (part["type"] as? String) == "text",
                       let t = part["text"] as? String {
                        return t
                    }
                }
            }
        }
        return nil
    }

    func alias(for sessionID: UUID) -> String? {
        sidecar.aliases[sessionID]
    }

    func isFavorite(sessionID: UUID) -> Bool {
        sidecar.favoriteSessions.contains(sessionID)
    }

    /// Pass `nil` (or empty string) to clear the alias.
    /// Per-session only — does not affect other sessions in the same cwd.
    func setAlias(_ alias: String?, for sessionID: UUID) async {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueToStore = (trimmed?.isEmpty == false) ? trimmed : nil
        do {
            try await sidecarStore.setAlias(valueToStore, for: sessionID)
            sidecar = await sidecarStore.current()
        } catch {
            NSLog("setAlias failed: \(error)")
        }
    }

    func toggleFavorite(sessionID: UUID) async {
        do {
            try await sidecarStore.toggleFavorite(sessionID: sessionID)
            sidecar = await sidecarStore.current()
        } catch {
            NSLog("toggleFavorite failed: \(error)")
        }
    }

    /// Manually pull the latest snapshot from the store.
    /// Called by the watcher loop and the periodic refresh.
    func refresh() async {
        sessions = await store.sessions
    }

    /// Fetch (or re-use cached) subscription usage. Called by PopoverView's `.task`
    /// when the popover becomes visible, so we hit the network only when the user
    /// actually wants to see the numbers.
    ///
    /// Failures never clobber a previously-good `usage` value — the UI continues to
    /// show the last known good numbers and only surfaces the error as a small badge.
    func refreshUsage(force: Bool = false) async {
        usageIsLoading = true
        defer { usageIsLoading = false }
        let result = await usageClient.fetch(force: force)
        switch result {
        case .success(let u):
            usage = u
            usageError = nil
        case .failure(let f):
            usageError = f
            // Intentionally leave `usage` alone — UI prefers stale-but-real over nothing.
        }
    }

    // MARK: - Background loops

    private func attachWatcher() {
        watcherTask?.cancel()
        let store = self.store
        let stream = watcher.events()
        watcherTask = Task { [weak self] in
            for await event in stream {
                await store.ingest(event: event)
                await self?.refresh()
            }
        }
    }

    private func startPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.store.refreshProcessInfo()
                await self.refresh()
                // Accessibility status can flip while the popover is already
                // open (user just granted permission in System Settings) — keep
                // it in sync so the banner disappears automatically.
                self.refreshAccessibilityTrust()
            }
        }
    }

    // AppModel lives for the whole app lifetime, so no deinit cleanup is needed.
    // (And Swift 6 won't let deinit touch MainActor-isolated state anyway.)
}
