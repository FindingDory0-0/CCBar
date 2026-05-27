import Foundation

/// Subset of a single Claude Code JSONL line that we care about.
///
/// The file contains many record types (`user`, `assistant`, `system`, `ai-title`,
/// `attachment`, `permission-mode`, `file-history-snapshot`, `last-prompt`, …).
/// We only decode the fields needed for the session model — everything else is ignored.
struct JSONLRecord: Decodable {
    let type: String
    let timestamp: String?      // ISO8601, present on most content records
    let cwd: String?
    let sessionId: String?
    let message: Message?
    let aiTitle: String?        // present when type == "ai-title"
    /// `"cli"` for interactive `claude`, `"sdk-cli"` for `claude -p`,
    /// `"ide-extension"`, etc. Present on user/assistant/attachment lines.
    let entrypoint: String?

    struct Message: Decodable {
        let role: String?       // "user" | "assistant"
        let model: String?      // assistant only
        let content: Content?
        let usage: Usage?
    }

    /// Content can be a plain string (user) or an array of blocks (assistant, tool turns).
    enum Content: Decodable {
        case text(String)
        case blocks([Block])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) {
                self = .text(s)
            } else if let blocks = try? container.decode([Block].self) {
                self = .blocks(blocks)
            } else {
                self = .text("")
            }
        }

        /// First user-visible text payload across the content.
        /// Skips `thinking`, `tool_use`, `tool_result` blocks.
        var firstDisplayableText: String? {
            switch self {
            case .text(let s):
                return s.isEmpty ? nil : s
            case .blocks(let blocks):
                for block in blocks {
                    if block.type == "text", let t = block.text, !t.isEmpty {
                        return t
                    }
                }
                return nil
            }
        }
    }

    struct Block: Decodable {
        let type: String
        let text: String?
        // thinking blocks, tool_use, tool_result, etc — their fields are decoded only on demand
    }

    /// Mirrors the Anthropic Messages API usage object.
    /// Stored under `.convertFromSnakeCase`, so snake_case keys map to camelCase here.
    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
    }
}

extension JSONLRecord {
    /// Decoder configured for Claude Code JSONL records.
    /// `convertFromSnakeCase` handles `input_tokens` etc; explicit camelCase fields
    /// (e.g. `aiTitle`, `sessionId`) round-trip unchanged.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
