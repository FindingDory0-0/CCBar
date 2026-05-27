import Foundation

/// Cumulative token usage across all assistant turns in a session.
public struct TokenUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    public static let zero = TokenUsage()

    /// Sum of all four counters. Mainly useful for diagnostics; for UI use
    /// `newTokens` (input+output, what you "spent" this turn) or `cacheTokens`
    /// (read+creation, mostly opaque overhead) separately.
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    /// New tokens processed: user input + assistant output. This is what most
    /// users actually want to see — cache hits don't represent fresh work.
    public var newTokens: Int { inputTokens + outputTokens }

    /// Cache-related tokens. Accumulates massively across long sessions because
    /// the same system prompt is re-read every turn — should NOT be shown as a
    /// total without context.
    public var cacheTokens: Int { cacheReadTokens + cacheCreationTokens }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens
        )
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }
}
