import Foundation

/// A Claude Code session — one JSONL file under `~/.claude/projects/<encoded-cwd>/<id>.jsonl`.
///
/// Built incrementally by JSONLParser, decorated with live process info by ProcessProbe,
/// and aggregated by SessionStore.
public struct Session: Identifiable, Hashable, Sendable {
    /// Stable UUID extracted from the JSONL filename.
    public let id: UUID
    /// Absolute path to the session's JSONL file.
    public let jsonlPath: URL
    /// Working directory at session start (the decoded form of the parent folder name).
    /// Mutable because the authoritative value comes from JSONL content, not the folder name.
    public var cwd: URL

    /// Earliest message timestamp seen (or file ctime if no messages yet).
    public var firstActivity: Date
    /// Latest message timestamp seen (or file mtime).
    public var lastActivity: Date
    /// Number of user+assistant messages parsed so far.
    public var messageCount: Int
    /// Auto-generated session title (from `type:"ai-title"` records), if Claude Code emitted one.
    public var aiTitle: String?
    /// Most recent user message text (truncated when stored), nil if none.
    public var lastUserMessage: String?
    /// Most recent assistant message preview (first text content block, truncated).
    public var lastAssistantMessage: String?
    /// Live lifecycle state. Defaults to `.ended` until ProcessProbe says otherwise.
    public var status: SessionStatus
    /// What's hosting this session. `.unknown` until ProcessProbe resolves it.
    public var hostHint: HostHint
    /// Accumulated token counts across all assistant turns.
    public var usage: TokenUsage
    /// True for sessions started with the interactive `claude` CLI; false for
    /// one-shot `claude -p` (sdk-cli) invocations. Derived from the JSONL's
    /// `entrypoint` field — `"cli"` = interactive, anything else (`"sdk-cli"`
    /// for `-p`, `"ide-extension"` etc) is treated as non-interactive.
    public var isInteractive: Bool

    public init(
        id: UUID,
        jsonlPath: URL,
        cwd: URL,
        firstActivity: Date,
        lastActivity: Date,
        messageCount: Int = 0,
        aiTitle: String? = nil,
        lastUserMessage: String? = nil,
        lastAssistantMessage: String? = nil,
        status: SessionStatus = .ended,
        hostHint: HostHint = .unknown,
        usage: TokenUsage = .zero,
        isInteractive: Bool = true
    ) {
        self.id = id
        self.jsonlPath = jsonlPath
        self.cwd = cwd
        self.firstActivity = firstActivity
        self.lastActivity = lastActivity
        self.messageCount = messageCount
        self.aiTitle = aiTitle
        self.lastUserMessage = lastUserMessage
        self.lastAssistantMessage = lastAssistantMessage
        self.status = status
        self.hostHint = hostHint
        self.usage = usage
        self.isInteractive = isInteractive
    }

    /// Display label: alias > aiTitle > truncated last user message > "untitled".
    /// SidecarStore alias is applied at the view layer, not here.
    public var defaultDisplayName: String {
        if let aiTitle, !aiTitle.isEmpty { return aiTitle }
        if let lastUserMessage, !lastUserMessage.isEmpty {
            let trimmed = lastUserMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(40))
        }
        return "untitled"
    }
}
