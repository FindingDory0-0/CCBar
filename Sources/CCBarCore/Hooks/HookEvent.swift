import Foundation

/// One Claude Code hook firing, decoded from the JSON payload it posts to us.
///
/// Hook payloads always carry `hook_event_name`; everything else is optional and
/// varies by event type. We keep this struct minimal — only the fields we actually
/// react to. Unknown fields are silently ignored so we don't break on new ones.
public struct HookEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// Claude finished a response and is back to user-input wait.
        case stop = "Stop"
        /// Claude is asking the user something (e.g. permission prompt).
        case notification = "Notification"
        /// Brand-new session started (or resumed).
        case sessionStart = "SessionStart"
        /// Claude is about to invoke a tool — useful as a "running" signal.
        case preToolUse = "PreToolUse"
        /// Claude finished a tool — back to "thinking".
        case postToolUse = "PostToolUse"
        /// Anything we don't explicitly model yet.
        case unknown
    }

    public let kind: Kind
    public let rawEventName: String
    public let sessionID: UUID?
    public let cwd: URL?
    public let transcriptPath: URL?
    /// Free text Claude wants to surface (used by Notification).
    public let message: String?
    /// Short label (used by Notification — usually app name or category).
    public let title: String?
    /// TTY path of the `claude` process that emitted this hook, as captured
    /// by `send-hook.sh` via `ps -p $PPID -o tty=`. Lets us pin the session's
    /// `hostHint` exactly even when multiple claude processes share a cwd —
    /// without this the cwd-only fallback in `SessionStore.refreshProcessInfo`
    /// can route the toast click to the wrong iTerm window.
    public let ttyPath: String?
    public let receivedAt: Date

    public init(
        kind: Kind,
        rawEventName: String,
        sessionID: UUID? = nil,
        cwd: URL? = nil,
        transcriptPath: URL? = nil,
        message: String? = nil,
        title: String? = nil,
        ttyPath: String? = nil,
        receivedAt: Date = Date()
    ) {
        self.kind = kind
        self.rawEventName = rawEventName
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.message = message
        self.title = title
        self.ttyPath = ttyPath
        self.receivedAt = receivedAt
    }

    /// Decode from a Claude Code hook JSON object. Returns nil if it doesn't
    /// look like a hook payload (no `hook_event_name`).
    public static func from(json: [String: Any], receivedAt: Date = Date()) -> HookEvent? {
        guard let raw = json["hook_event_name"] as? String else { return nil }
        let kind = Kind(rawValue: raw) ?? .unknown
        // `_ccbar_tty` is injected by send-hook.sh; older scripts won't have it.
        let tty = json["_ccbar_tty"] as? String
        return HookEvent(
            kind: kind,
            rawEventName: raw,
            sessionID: (json["session_id"] as? String).flatMap(UUID.init(uuidString:)),
            cwd: (json["cwd"] as? String).map { URL(fileURLWithPath: $0) },
            transcriptPath: (json["transcript_path"] as? String).map { URL(fileURLWithPath: $0) },
            message: json["message"] as? String,
            title: json["title"] as? String,
            ttyPath: tty?.isEmpty == false ? tty : nil,
            receivedAt: receivedAt
        )
    }
}
