import Foundation

/// Adds / removes CCBar's hook entries in the user's `~/.claude/settings.json`.
///
/// We preserve everything else in the file untouched — only our own entries
/// (identified by the `command` field pointing at our send-hook.sh) are
/// touched. The first install copies the original settings to
/// `~/.claude/settings.json.ccbar-backup` so the user can roll back if needed.
///
/// JSON shape we emit:
/// ```json
/// {
///   "hooks": {
///     "Stop":         [ { "hooks": [ { "type": "command", "command": "<send-hook.sh>" } ] } ],
///     "Notification": [ { "hooks": [ { "type": "command", "command": "<send-hook.sh>" } ] } ],
///     "SessionStart": [ { "hooks": [ { "type": "command", "command": "<send-hook.sh>" } ] } ],
///     "PreToolUse":   [ { "hooks": [ { "type": "command", "command": "<send-hook.sh>" } ] } ],
///     "PostToolUse":  [ { "hooks": [ { "type": "command", "command": "<send-hook.sh>" } ] } ]
///   }
/// }
/// ```
public actor SettingsInjector {

    /// Hook event names we register for. Stop and Notification drive toasts;
    /// SessionStart / PreToolUse / PostToolUse improve the live status accuracy.
    public static let supportedEvents: [String] = [
        "Stop", "Notification", "SessionStart", "PreToolUse", "PostToolUse"
    ]

    /// Default location of Claude Code's user-level settings file.
    public static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Where our send-hook.sh helper lives. We embed this absolute path into
    /// settings.json so Claude Code can invoke it without env-var lookups.
    ///
    /// IMPORTANT: this path must contain NO spaces. Claude Code passes the
    /// `command` string to `/bin/sh`, which word-splits on whitespace — a path
    /// like `~/Library/Application Support/...` breaks at "Application".
    /// `~/.claude/ccbar/` sits right next to Claude Code's own config and is
    /// always safe to write.
    public static var sendHookScriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ccbar/send-hook.sh", isDirectory: false)
    }

    public enum InjectError: Error, Sendable {
        case writeFailed(String)
        case readFailed(String)
        case malformed
    }

    private let settingsURL: URL
    private let scriptPath: String

    public init(settingsURL: URL = SettingsInjector.defaultSettingsURL) {
        self.settingsURL = settingsURL
        self.scriptPath = SettingsInjector.sendHookScriptURL.path
    }

    // MARK: - Public

    /// True if at least one of our entries is present in any supported event.
    public func isInstalled() -> Bool {
        let json = loadSettings() ?? [:]
        guard let hooks = json["hooks"] as? [String: Any] else { return false }
        return Self.supportedEvents.contains(where: { hasOurEntry(in: hooks[$0]) })
    }

    /// Add our hook entries to every supported event. Idempotent — calling it
    /// repeatedly doesn't create duplicates. Makes a one-time backup the first
    /// time the file is modified, and sweeps out any stale CCBar entries that
    /// point at a previous (e.g. space-containing) script path.
    public func install() throws {
        try backupOnce()
        var json = loadSettings() ?? [:]
        var hooks = (json["hooks"] as? [String: Any]) ?? [:]
        for event in Self.supportedEvents {
            let cleaned = removeStaleCCBarEntries(from: hooks[event])
            hooks[event] = addOurEntry(to: cleaned)
        }
        json["hooks"] = hooks
        try save(json)
    }

    /// Remove only our own entries; leave any user-authored hooks alone.
    /// Empty arrays (events where we were the only handler) are pruned.
    /// Also sweeps stale CCBar entries from previous installs.
    public func uninstall() throws {
        guard var json = loadSettings() else { return }
        guard var hooks = json["hooks"] as? [String: Any] else { return }
        for event in Self.supportedEvents {
            // First sweep stale CCBar paths, then remove the current one.
            var arr = removeStaleCCBarEntries(from: hooks[event])
            arr = removeOurEntry(from: arr)
            if arr.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = arr
            }
        }
        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }
        try save(json)
    }

    /// Migrate hook entries from any old CCBar script path to the current one.
    /// Safe to call at app start whether the user is installed or not — only
    /// touches entries whose command matches a CCBar shape and isn't already
    /// pointing at the current `scriptPath`.
    public func sweepStalePaths() throws {
        guard var json = loadSettings(),
              var hooks = json["hooks"] as? [String: Any]
        else { return }
        var changed = false
        for event in Self.supportedEvents {
            guard let array = hooks[event] as? [Any] else { continue }
            let cleaned = removeStaleCCBarEntries(from: array)
            // Cheap comparison: only update + flag changed when count differs
            // or representative entries differ.
            if (cleaned as [Any]).count != array.count {
                if cleaned.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = cleaned
                }
                changed = true
            }
        }
        if changed {
            if hooks.isEmpty {
                json.removeValue(forKey: "hooks")
            } else {
                json["hooks"] = hooks
            }
            try save(json)
        }
    }

    // MARK: - Backup

    /// One-time backup of the user's pre-CCBar settings.
    /// We don't overwrite an existing `.ccbar-backup` — that would clobber the
    /// original snapshot if the user uninstalls and re-installs.
    public func backupOnce() throws {
        let backup = settingsURL.appendingPathExtension("ccbar-backup")
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path),
              !fm.fileExists(atPath: backup.path)
        else { return }
        do {
            try fm.copyItem(at: settingsURL, to: backup)
        } catch {
            throw InjectError.writeFailed("backup: \(error)")
        }
    }

    // MARK: - Internal JSON manipulation

    private func loadSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private func save(_ json: [String: Any]) throws {
        // Ensure the .claude directory exists. (It almost always does, but for
        // a fresh machine the install step could be the first thing to write it.)
        let fm = FileManager.default
        let parent = settingsURL.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            let data = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            throw InjectError.writeFailed(String(describing: error))
        }
    }

    /// Does this event-array contain at least one of our entries?
    private func hasOurEntry(in raw: Any?) -> Bool {
        guard let array = raw as? [[String: Any]] else { return false }
        return array.contains { outer in
            (outer["hooks"] as? [[String: Any]])?.contains { h in
                (h["command"] as? String) == scriptPath
            } ?? false
        }
    }

    /// Append our entry to the event array (no-op if already present).
    private func addOurEntry(to raw: Any?) -> [[String: Any]] {
        var array = (raw as? [[String: Any]]) ?? []
        if hasOurEntry(in: array) { return array }
        let entry: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": scriptPath,
                ]
            ]
        ]
        array.append(entry)
        return array
    }

    /// Remove our entries from the event array. Outer entries whose inner
    /// `hooks` array becomes empty get dropped wholesale.
    private func removeOurEntry(from raw: Any?) -> [[String: Any]] {
        guard let array = raw as? [[String: Any]] else {
            // Wasn't a recognized array — leave it as best we can.
            return []
        }
        return array.compactMap { outer -> [String: Any]? in
            guard var inner = outer["hooks"] as? [[String: Any]] else { return outer }
            inner.removeAll { ($0["command"] as? String) == scriptPath }
            if inner.isEmpty { return nil }
            var rewritten = outer
            rewritten["hooks"] = inner
            return rewritten
        }
    }

    /// Strip out any CCBar entries that point at a path other than our current one.
    /// Matches by command path containing both "CCBar" or "ccbar" segments and
    /// ending in `send-hook.sh`. Lets us silently retire the old space-containing
    /// path without asking the user to re-toggle.
    private func removeStaleCCBarEntries(from raw: Any?) -> [[String: Any]] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { outer -> [String: Any]? in
            guard var inner = outer["hooks"] as? [[String: Any]] else { return outer }
            inner.removeAll { entry in
                guard let cmd = entry["command"] as? String else { return false }
                // Keep entries that exactly match our current path.
                if cmd == scriptPath { return false }
                // Strip anything that looks like a CCBar helper from an older install.
                let looksLikeCCBarPath = (cmd.contains("/CCBar/") || cmd.contains("/ccbar/"))
                    && cmd.hasSuffix("send-hook.sh")
                return looksLikeCCBarPath
            }
            if inner.isEmpty { return nil }
            var rewritten = outer
            rewritten["hooks"] = inner
            return rewritten
        }
    }
}
