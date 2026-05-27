import Foundation

/// Lifecycle state of a Claude Code session, derived from process + hook signals.
public enum SessionStatus: String, Codable, Hashable, Sendable {
    /// `claude` process is running and currently producing output (between PreToolUse and Stop).
    case running
    /// `claude` is waiting for user input — usually a Notification hook fired.
    case waiting
    /// `claude` process is alive but quietly idle (after Stop, before next user message).
    case idle
    /// No `claude` process holds this session's JSONL file open. Historical session.
    case ended
}
