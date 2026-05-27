import Foundation

/// Central authority for all known Claude Code sessions.
///
/// Lifecycle:
///   1. `bootstrap()` — scan disk once, parse every JSONL, mark everything `.ended`.
///   2. `attachWatcher(_:)` — subscribe to FSEvents; new/modified files merge in.
///   3. `refreshProcessInfo()` — periodically (or on popover open) ask ProcessProbe
///      which sessions have a live `claude` process and update `status` + `hostHint`.
public actor SessionStore {
    /// Internal record: parsed session plus the byte offset for the next incremental read.
    private struct Entry {
        var session: Session
        var endOffset: Int64
        /// TTY path most recently reported by this session's own hook
        /// (`event.ttyPath` injected by send-hook.sh). Authoritative — the
        /// claude process literally told us its own TTY. We trust this over
        /// the cwd-matching fallback in `refreshProcessInfo`, because cwd
        /// matching is ambiguous when several sessions share a working dir
        /// (one of them being a `claude -c` continuation of another).
        ///
        /// Nil for sessions we've never seen a hook from — those still use
        /// the cwd-matching pass.
        var hookProvidedTTY: String?
    }

    private var entries: [UUID: Entry] = [:]
    /// JSONL URL → session ID, so FSEvents (which gives paths) can find the entry quickly.
    private var idByPath: [URL: UUID] = [:]

    public init() {}

    // MARK: - Public read API

    /// All known sessions, most recently active first.
    public var sessions: [Session] {
        entries.values
            .map(\.session)
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Sessions with a live `claude` process holding the JSONL open.
    public var activeSessions: [Session] {
        sessions.filter { $0.status != .ended }
    }

    public func session(id: UUID) -> Session? {
        entries[id]?.session
    }

    public var count: Int { entries.count }

    // MARK: - Bootstrap

    /// Discover JSONL files under the projects root and parse them.
    ///
    /// When `limit` is given, we sort files by modification time (newest first)
    /// and only parse the most-recent `limit` entries. The remaining files
    /// can be loaded later via `bootstrapRemainder()` — this lets the UI come
    /// up in well under a second instead of blocking on ~5,000 historical
    /// sessions.
    ///
    /// Status starts at `.ended` for everything; call `refreshProcessInfo()`
    /// afterward to bump live sessions.
    public func bootstrap(root: URL = ProjectsRoot.defaultURL, limit: Int? = nil) throws {
        var files = try ProjectsRoot.discoverJSONLFiles(under: root)
        if let limit, files.count > limit {
            // Sort by mtime descending (most-recent first), then truncate.
            files.sort { lhs, rhs in
                let lm = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rm = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return lm > rm
            }
            files = Array(files.prefix(limit))
        }
        for url in files {
            ingestFullParse(url: url)
        }
    }

    /// Parse any JSONL file we haven't already ingested. Idempotent — files
    /// already in `entries` are skipped, so calling this after a quick
    /// `bootstrap(limit:)` only does the leftover work.
    public func bootstrapRemainder(root: URL = ProjectsRoot.defaultURL) throws {
        let files = try ProjectsRoot.discoverJSONLFiles(under: root)
        for url in files where idByPath[url] == nil {
            ingestFullParse(url: url)
        }
    }

    // MARK: - FSEvents ingestion

    /// React to a single watcher event. Caller wires this up to JSONLWatcher.events().
    public func ingest(event: JSONLWatcher.Event) {
        switch event.kind {
        case .created:
            ingestFullParse(url: event.url)
        case .modified:
            ingestIncremental(url: event.url)
        case .renamed:
            // Renames fire for both old and new path. If the file is gone, drop it; otherwise re-parse.
            if FileManager.default.fileExists(atPath: event.url.path) {
                ingestFullParse(url: event.url)
            } else {
                remove(url: event.url)
            }
        case .removed:
            remove(url: event.url)
        }
    }

    /// Convenience: subscribe a watcher's stream and feed every event in.
    /// Returns when the stream ends.
    public func attachWatcher(_ watcher: JSONLWatcher) async {
        for await event in watcher.events() {
            ingest(event: event)
        }
    }

    private func ingestFullParse(url: URL) {
        guard let result = try? JSONLParser.parse(url: url) else { return }
        let id = result.session.id
        entries[id] = Entry(session: result.session, endOffset: result.endOffset)
        idByPath[url] = id
    }

    private func ingestIncremental(url: URL) {
        guard let id = idByPath[url], let existing = entries[id] else {
            // Modified without us having seen the create — fall back to a full parse.
            ingestFullParse(url: url)
            return
        }
        guard let result = try? JSONLParser.parse(
            url: url,
            fromOffset: existing.endOffset,
            prior: existing.session
        ) else { return }
        // Preserve hookProvidedTTY across incremental updates — it's a
        // long-lived binding that the parser doesn't know about.
        entries[id] = Entry(
            session: result.session,
            endOffset: result.endOffset,
            hookProvidedTTY: existing.hookProvidedTTY
        )
    }

    private func remove(url: URL) {
        guard let id = idByPath.removeValue(forKey: url) else { return }
        entries.removeValue(forKey: id)
    }

    // MARK: - Process info

    /// Mark each session as `.running`/`.idle`/`.ended` based on ProcessProbe.
    /// Also fills in `hostHint` for live sessions.
    ///
    /// Matching strategy (in order — earlier passes are authoritative):
    ///   0. **Hook-provided TTY** wins. If we've ever seen a hook from this
    ///      session, that hook told us the exact PID of the claude process
    ///      via its TTY. Match the live process with that same TTY and pin
    ///      this session to it. Bypasses the ambiguity of cwd matching when
    ///      several sessions share a working directory — most commonly when
    ///      one is a `claude -c` continuation of another.
    ///   1. **lsof-caught open JSONL path** — exact match (rare; claude
    ///      reopens its file per-write so lsof usually misses).
    ///   2. **cwd matching** — fallback for sessions we've never received
    ///      a hook from. Picks the most recently active session sharing
    ///      the process's cwd.
    ///
    /// Critically, processes already claimed by Pass 0 are excluded from
    /// the later passes, so cwd matching can't reassign them to a
    /// different session on the next 5-second refresh tick.
    public func refreshProcessInfo() {
        let processes: [ClaudeProcess]
        do {
            processes = try ProcessProbe.snapshot()
        } catch {
            return
        }

        var claimed: Set<UUID> = []
        var consumedPIDs: Set<Int32> = []

        // Pass 0: hook-provided TTY wins. Authoritative because the claude
        // process itself told us its TTY at hook-fire time.
        for (id, entry) in entries {
            guard let hookTTY = entry.hookProvidedTTY,
                  let proc = processes.first(where: { $0.tty == hookTTY })
            else { continue }
            claim(id: id, with: proc, into: &claimed)
            consumedPIDs.insert(proc.pid)
        }

        // Pass 1: exact lsof-catch.
        for proc in processes where !consumedPIDs.contains(proc.pid) {
            if let openPath = proc.openJSONLPath, let id = idByPath[openPath] {
                claim(id: id, with: proc, into: &claimed)
                consumedPIDs.insert(proc.pid)
            }
        }

        // Pre-sort sessions by lastActivity desc so cwd matching picks recent first.
        let sortedIDs = entries.values
            .sorted { $0.session.lastActivity > $1.session.lastActivity }
            .map(\.session.id)

        // Pass 2: cwd matching for remaining (unconsumed) processes.
        //
        // Sessions that already have a `hookProvidedTTY` are **excluded** here
        // — they're pinned to that specific TTY by Pass 0. If Pass 0 didn't
        // claim them (their TTY's process is dead), the right outcome is
        // `.ended`, not "let some other process in the same cwd take over."
        // Otherwise a freshly-closed session would steal the live PID of an
        // older session and flip the live session's card to .ended.
        for proc in processes where !consumedPIDs.contains(proc.pid) {
            guard let procCwd = proc.cwd else { continue }
            let target = sortedIDs.first { id in
                guard !claimed.contains(id),
                      let entry = entries[id]
                else { return false }
                // Pinned by Pass 0; don't let cwd fallback rebind it.
                if entry.hookProvidedTTY != nil { return false }
                return entry.session.cwd.standardizedFileURL.path == procCwd.standardizedFileURL.path
            }
            if let id = target {
                claim(id: id, with: proc, into: &claimed)
            }
        }

        // Anything not claimed by a live process and not already ended is now ended.
        // We don't blindly reset everything beforehand — that would clobber the
        // hook-driven `.waiting`/`.running` states for claimed sessions.
        for id in entries.keys where !claimed.contains(id) {
            if entries[id]?.session.status != .ended {
                entries[id]?.session.status = .ended
            }
        }
    }

    private func claim(id: UUID, with proc: ClaudeProcess, into claimed: inout Set<UUID>) {
        guard var entry = entries[id] else { return }
        // Without hook signals we treat "process holds the cwd" as `.idle` rather
        // than `.ended`. applyHookEvent() refines this when hooks arrive.
        // Preserve hook-set `.waiting`/`.running` if it's more specific.
        if entry.session.status == .ended {
            entry.session.status = .idle
        }
        entry.session.hostHint = proc.hostHint
        entries[id] = entry
        claimed.insert(id)
    }

    // MARK: - Hook events

    /// Update the matching session's `status` from a hook payload.
    /// Mapping:
    ///   - Stop          → `.idle`     (Claude finished a turn)
    ///   - Notification  → `.waiting`  (Claude is asking for input/permission)
    ///   - PreToolUse    → `.running`  (Claude just invoked a tool)
    ///   - PostToolUse   → `.running`  (still in the middle of a turn)
    ///   - SessionStart  → `.idle`     (newborn session, will likely flip soon)
    ///   - unknown       → no-op
    ///
    /// Matching: prefer `sessionID` if present and known; otherwise fall back to
    /// the most-recently-active session under the event's `cwd` (best effort —
    /// hooks usually carry the ID).
    public func applyHookEvent(_ event: HookEvent) {
        guard let id = resolveSessionID(for: event) else { return }
        guard var entry = entries[id] else { return }

        switch event.kind {
        case .stop, .sessionStart:
            entry.session.status = .idle
        case .notification:
            entry.session.status = .waiting
        case .preToolUse, .postToolUse:
            entry.session.status = .running
        case .unknown:
            return
        }

        // Remember this hook's TTY for the duration of the app — used by
        // refreshProcessInfo's Pass 0 to keep this session glued to its own
        // iTerm window across periodic refreshes. Also project it onto
        // hostHint immediately so the next focus tap goes to the right
        // place without waiting for the next refresh tick.
        if let tty = event.ttyPath, !tty.isEmpty {
            entry.hookProvidedTTY = tty
            switch entry.session.hostHint {
            case .iTerm2(let existing) where existing == tty:
                break // already correct
            case .terminal(let existing) where existing == tty:
                break
            case .unknown, .iTerm2, .terminal:
                entry.session.hostHint = .iTerm2(tty: tty)
            default:
                // .warp / .ghostty / .vscodeFork / .jetbrains stay as-is;
                // those host kinds don't model a TTY, and the hook is
                // really only useful for terminal-based hosts.
                break
            }
        }
        entries[id] = entry
    }

    private func resolveSessionID(for event: HookEvent) -> UUID? {
        if let id = event.sessionID, entries[id] != nil { return id }
        guard let cwd = event.cwd?.standardizedFileURL.path else { return nil }
        // Most recent session with matching cwd.
        return entries.values
            .sorted { $0.session.lastActivity > $1.session.lastActivity }
            .first { $0.session.cwd.standardizedFileURL.path == cwd }?
            .session.id
    }
}
