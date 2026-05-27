import Foundation
import Testing
@testable import CCBarCore

@Suite("Models")
struct ModelsTests {

    @Test func tokenUsageAdditionIsAssociative() {
        let a = TokenUsage(inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheCreationTokens: 4)
        let b = TokenUsage(inputTokens: 10, outputTokens: 20, cacheReadTokens: 30, cacheCreationTokens: 40)
        let sum = a + b
        #expect(sum.inputTokens == 11)
        #expect(sum.outputTokens == 22)
        #expect(sum.cacheReadTokens == 33)
        #expect(sum.cacheCreationTokens == 44)
        #expect(sum.totalTokens == 110)
    }

    @Test func tokenUsageZeroIsIdentity() {
        let a = TokenUsage(inputTokens: 5, outputTokens: 6, cacheReadTokens: 7, cacheCreationTokens: 8)
        #expect((a + .zero) == a)
        #expect((.zero + a) == a)
    }

    @Test func hostHintDisplayNameMapsKnownBundles() {
        #expect(HostHint.iTerm2(tty: "/dev/ttys001").displayName == "iTerm2")
        #expect(HostHint.terminal(tty: "/dev/ttys002").displayName == "Terminal")
        #expect(HostHint.warp.displayName == "Warp")
        #expect(HostHint.ghostty.displayName == "Ghostty")
        #expect(HostHint.vscodeFork(bundleID: "com.microsoft.VSCode", scheme: "vscode").displayName == "VS Code")
        #expect(HostHint.vscodeFork(bundleID: "com.google.antigravity", scheme: "antigravity").displayName == "Antigravity")
        #expect(HostHint.unknown.displayName == "Unknown")
    }

    @Test func projectsRootDecodesFolderName() {
        let url = ProjectsRoot.decodeFolderName("-Users-haninkyu-Documents-AI-etc")
        #expect(url?.path == "/Users/haninkyu/Documents/AI/etc")
        #expect(ProjectsRoot.decodeFolderName("no-leading-dash") == nil)
    }

    @Test func projectsRootExtractsSessionID() {
        let url = URL(fileURLWithPath: "/x/y/550e8400-e29b-41d4-a716-446655440000.jsonl")
        #expect(ProjectsRoot.sessionID(from: url) == UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        let bad = URL(fileURLWithPath: "/x/y/not-a-uuid.jsonl")
        #expect(ProjectsRoot.sessionID(from: bad) == nil)
    }
}
