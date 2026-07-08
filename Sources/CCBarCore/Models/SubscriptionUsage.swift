import Foundation

/// Snapshot of the user's Claude Code subscription usage at a point in time.
/// Populated by UsageApiClient from the Anthropic OAuth `/api/oauth/usage` endpoint.
///
/// `utilization` values are 0.0~100.0 percentages (verified empirically against
/// the live endpoint on 2026-05-26 — the OMC source comment of "0.0~1.0" was wrong).
public struct SubscriptionUsage: Sendable, Hashable, Codable {
    /// Five-hour rolling window — the short-window subscription cap.
    public var fiveHour: Window
    /// Weekly window (renamed `seven_day` in the API).
    public var sevenDay: Window
    /// Opus-only weekly window. Nil if the user's tier doesn't have a separate Opus cap.
    public var sevenDayOpus: Window?
    /// Sonnet-only weekly window. Nil if not applicable.
    public var sevenDaySonnet: Window?
    /// Per-model weekly caps the API now reports via its `limits` array as
    /// `weekly_scoped` entries (e.g. Fable). Ordered as returned. Optional so
    /// older cached snapshots still decode.
    public var scopedModels: [ScopedWindow]?
    /// Pay-as-you-go credit usage. Often `is_enabled == false`.
    public var extraUsage: ExtraUsage?
    /// When this snapshot was fetched from the server. Drives the local 30s cache.
    public var fetchedAt: Date

    public struct Window: Sendable, Hashable, Codable {
        /// 0~100 percentage of the window consumed.
        public var utilization: Double
        /// Timestamp when this window resets and `utilization` returns to 0.
        public var resetsAt: Date

        public init(utilization: Double, resetsAt: Date) {
            self.utilization = utilization
            self.resetsAt = resetsAt
        }
    }

    /// A weekly cap scoped to a single model (from the API's `limits` array).
    public struct ScopedWindow: Sendable, Hashable, Codable {
        /// Model display name, e.g. "Fable", "Sonnet", "Opus".
        public var modelName: String
        public var window: Window

        public init(modelName: String, window: Window) {
            self.modelName = modelName
            self.window = window
        }
    }

    public struct ExtraUsage: Sendable, Hashable, Codable {
        public var isEnabled: Bool
        public var monthlyLimit: Double?
        public var usedCredits: Double?
        public var utilization: Double?
        public var currency: String?
    }

    public init(
        fiveHour: Window,
        sevenDay: Window,
        sevenDayOpus: Window? = nil,
        sevenDaySonnet: Window? = nil,
        scopedModels: [ScopedWindow]? = nil,
        extraUsage: ExtraUsage? = nil,
        fetchedAt: Date = Date()
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.scopedModels = scopedModels
        self.extraUsage = extraUsage
        self.fetchedAt = fetchedAt
    }
}
