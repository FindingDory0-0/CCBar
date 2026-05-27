import Foundation
import Testing
@testable import CCBarCore

@Suite("JSONLParser")
struct JSONLParserTests {

    /// Copies the fixture to a fresh temp path named with the UUID we want to parse.
    /// Returns the URL of the prepared file. Caller is responsible for cleanup.
    private func prepareFixture(uuid: String = "550e8400-e29b-41d4-a716-446655440000") throws -> URL {
        let fixture = Bundle.module.url(
            forResource: "session-fixture",
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        )!
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dest = tempDir.appendingPathComponent("\(uuid).jsonl")
        try FileManager.default.copyItem(at: fixture, to: dest)
        return dest
    }

    @Test func fullParseExtractsAllFields() throws {
        let url = try prepareFixture()
        let result = try JSONLParser.parse(url: url)

        #expect(result.session.id == UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        #expect(result.session.cwd.path == "/tmp/ccbar-test")
        #expect(result.session.messageCount == 4)
        #expect(result.session.aiTitle == "Greeting smoke test")
        #expect(result.session.lastUserMessage == "What is 2+2?")
        #expect(result.session.lastAssistantMessage == "Four.")
        #expect(result.malformedLineCount == 0)
    }

    @Test func tokenUsageAccumulates() throws {
        let url = try prepareFixture()
        let result = try JSONLParser.parse(url: url)
        // 10+3 input, 5+2 output, 100+120 cache_read, 50+0 cache_creation
        #expect(result.session.usage.inputTokens == 13)
        #expect(result.session.usage.outputTokens == 7)
        #expect(result.session.usage.cacheReadTokens == 220)
        #expect(result.session.usage.cacheCreationTokens == 50)
    }

    @Test func incrementalParseMergesIntoPrior() throws {
        let url = try prepareFixture()

        // Read first 2 lines only by truncating manually.
        let full = try String(contentsOf: url, encoding: .utf8)
        let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
        let head = lines.prefix(3).joined(separator: "\n") + "\n"   // summary + user + assistant
        let truncated = url.deletingLastPathComponent().appendingPathComponent("truncated.jsonl")
        try head.write(to: truncated, atomically: true, encoding: .utf8)

        // Rename to use the session UUID as filename, so parser picks the ID.
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        let renamed = truncated.deletingLastPathComponent().appendingPathComponent("\(uuid).jsonl")
        try? FileManager.default.removeItem(at: renamed)
        try FileManager.default.moveItem(at: truncated, to: renamed)

        let partial = try JSONLParser.parse(url: renamed)
        #expect(partial.session.messageCount == 2)
        #expect(partial.session.lastAssistantMessage == "Of course! What do you need?")

        // Now write the rest and resume from the saved offset.
        let rest = lines.dropFirst(3).joined(separator: "\n")
        let handle = try FileHandle(forWritingTo: renamed)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(rest.utf8))
        try handle.close()

        let resumed = try JSONLParser.parse(
            url: renamed,
            fromOffset: partial.endOffset,
            prior: partial.session
        )
        #expect(resumed.session.messageCount == 4)
        #expect(resumed.session.lastUserMessage == "What is 2+2?")
        #expect(resumed.session.usage.totalTokens == 13 + 7 + 220 + 50)
    }

    @Test func partialTrailingLineDoesNotAdvanceOffset() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbar-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("550e8400-e29b-41d4-a716-446655440000.jsonl")

        // Write one complete line and one partial (no trailing newline).
        let complete = #"{"type":"user","timestamp":"2026-05-26T10:00:00Z","cwd":"/x","sessionId":"550e8400-e29b-41d4-a716-446655440000","message":{"role":"user","content":"hi"}}"# + "\n"
        let partial = #"{"type":"assistant","timestamp":"2026"#  // truncated mid-write
        try (complete + partial).write(to: url, atomically: true, encoding: .utf8)

        let result = try JSONLParser.parse(url: url)
        #expect(result.session.messageCount == 1)
        // Offset should point past the newline of the complete line, before the partial.
        #expect(result.endOffset == Int64(complete.utf8.count))
    }
}
