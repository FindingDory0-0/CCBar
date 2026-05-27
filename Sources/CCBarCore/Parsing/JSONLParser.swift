import Foundation

/// Parses Claude Code session JSONL files into `Session` values.
///
/// Designed for tail-follow: `parse(...)` accepts a starting byte offset so callers
/// can resume from where the previous read ended, applying only the newly-appended
/// lines to a prior Session. It tolerates malformed lines (skip with debug log) and
/// partial trailing lines (the offset is rewound to the last newline).
public enum JSONLParser {
    public struct ParseResult: Sendable {
        public var session: Session
        /// Byte offset past the last complete line. Pass back as `fromOffset` next time.
        public var endOffset: Int64
        /// Lines that failed to JSON-decode (count only). Useful for diagnostics.
        public var malformedLineCount: Int
    }

    public enum ParseError: Error, Sendable {
        case missingFilename(URL)
        case unreadable(URL, underlying: Error)
    }

    /// Read `url` from `fromOffset` to EOF. If `prior` is nil, build a Session from
    /// scratch using the filename as the ID and the first record's `cwd`. Otherwise
    /// merge new records into `prior`.
    public static func parse(
        url: URL,
        fromOffset: Int64 = 0,
        prior: Session? = nil
    ) throws -> ParseResult {
        guard let sessionID = ProjectsRoot.sessionID(from: url) else {
            throw ParseError.missingFilename(url)
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(max(0, fromOffset)))
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw ParseError.unreadable(url, underlying: error)
        }

        // Trim a partial trailing line if the file is mid-write.
        let (completeData, consumed) = trimPartialTail(data)
        let newEndOffset = fromOffset + Int64(consumed)

        // Working session — start from prior or build a skeleton.
        var session: Session = prior ?? Session(
            id: sessionID,
            jsonlPath: url,
            cwd: ProjectsRoot.decodeFolderName(url.deletingLastPathComponent().lastPathComponent)
                ?? url.deletingLastPathComponent(),
            firstActivity: Date.distantPast,
            lastActivity: Date.distantPast
        )
        let priorHadData = prior != nil

        var malformedCount = 0
        var sawAny = false

        completeData.split(separator: 0x0A, omittingEmptySubsequences: true).forEach { lineBytes in
            let lineData = Data(lineBytes)
            guard let record = decodeRecord(lineData) else {
                malformedCount += 1
                return
            }
            sawAny = true
            apply(record: record, to: &session)
        }

        // For a fresh parse with no records (e.g. brand-new empty file), fall back to file timestamps.
        if !priorHadData, !sawAny {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            if let created = attrs[.creationDate] as? Date {
                session.firstActivity = created
            }
            if let modified = attrs[.modificationDate] as? Date {
                session.lastActivity = modified
            }
        }

        return ParseResult(
            session: session,
            endOffset: newEndOffset,
            malformedLineCount: malformedCount
        )
    }

    // MARK: - Internals

    /// Returns the prefix of `data` ending at the last `\n`, and how many bytes that is.
    /// If `data` has no newline, returns empty (offset doesn't advance — wait for more).
    private static func trimPartialTail(_ data: Data) -> (Data, Int) {
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return (Data(), 0)
        }
        let upTo = data.index(after: lastNewline)  // include the \n itself
        let consumed = data.distance(from: data.startIndex, to: upTo)
        return (data[..<upTo], consumed)
    }

    private static func decodeRecord(_ data: Data) -> JSONLRecord? {
        try? JSONLRecord.decoder.decode(JSONLRecord.self, from: data)
    }

    private static func apply(record: JSONLRecord, to session: inout Session) {
        // Authoritative cwd from any record that carries it (Claude Code repeats it per line).
        if session.cwd.path.isEmpty || session.cwd.path == "/", let cwd = record.cwd {
            session.cwd = URL(fileURLWithPath: cwd)
        } else if let cwd = record.cwd, session.cwd.path != cwd {
            // Trust the record over the (possibly lossy) folder-name decode.
            session.cwd = URL(fileURLWithPath: cwd)
        }

        if let ts = record.timestamp, let date = parseISO8601(ts) {
            if session.firstActivity == .distantPast || date < session.firstActivity {
                session.firstActivity = date
            }
            if date > session.lastActivity {
                session.lastActivity = date
            }
        }

        // Capture entrypoint the first time we see one. `cli` = interactive,
        // anything else (`sdk-cli`, `ide-extension`, …) is a one-shot / SDK
        // invocation we want to filter out of the default UI.
        if let ep = record.entrypoint, !ep.isEmpty {
            session.isInteractive = (ep == "cli")
        }

        switch record.type {
        case "ai-title":
            if let t = record.aiTitle, !t.isEmpty {
                session.aiTitle = t
            }
        case "user":
            session.messageCount += 1
            if let text = record.message?.content?.firstDisplayableText,
               !looksLikeSystemTag(text) {
                session.lastUserMessage = String(text.prefix(280))
            }
        case "assistant":
            session.messageCount += 1
            if let text = record.message?.content?.firstDisplayableText {
                session.lastAssistantMessage = String(text.prefix(280))
            }
            if let usage = record.message?.usage {
                session.usage += TokenUsage(
                    inputTokens: usage.inputTokens ?? 0,
                    outputTokens: usage.outputTokens ?? 0,
                    cacheReadTokens: usage.cacheReadInputTokens ?? 0,
                    cacheCreationTokens: usage.cacheCreationInputTokens ?? 0
                )
            }
        default:
            // system / permission-mode / attachment / last-prompt / file-history-snapshot …
            break
        }
    }

    /// True for messages that Claude Code itself synthesized as the "user role"
    /// to communicate with the assistant — e.g. `<task-notification>...`,
    /// `<command-name>/usage</command-name>`, `<local-command-stdout>...`,
    /// `<system-reminder>...`. These shouldn't be shown as the session's
    /// last "user input" since they aren't from the human.
    private static func looksLikeSystemTag(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<") else { return false }
        // Match `<some-tag>` or `<some_tag attr="...">` at the very start.
        // We don't need to validate XML; anything that looks tag-like is suspect enough
        // to skip from the user-message preview.
        let regex = try? NSRegularExpression(pattern: #"^<[A-Za-z][A-Za-z0-9_:-]*[\s>]"#)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return regex?.firstMatch(in: trimmed, range: range) != nil
    }

    // ISO8601 with fractional seconds. Claude Code emits e.g. `2026-05-26T02:59:59.998883+00:00`.
    // Date.ISO8601FormatStyle is Sendable; ISO8601DateFormatter (NSObject subclass) is not.
    private static let iso8601WithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso8601Basic = Date.ISO8601FormatStyle()

    private static func parseISO8601(_ s: String) -> Date? {
        if let d = try? iso8601WithFraction.parse(s) { return d }
        return try? iso8601Basic.parse(s)
    }
}
