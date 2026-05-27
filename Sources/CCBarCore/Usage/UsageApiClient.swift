import Foundation
import Security

/// Fetches Claude Code subscription usage (`5h` and `7d` windows) from the
/// Anthropic OAuth API.
///
/// Trigger model: caller invokes `fetch()` when the popover opens. No background
/// polling. A 30-second in-memory cache absorbs rapid re-opens.
///
/// Auth flow:
///   1. Read `Claude Code-credentials` from macOS Keychain → JSON with
///      `claudeAiOauth.{accessToken, refreshToken, expiresAt, …}`.
///   2. If `expiresAt - now < 60s` → refresh via `platform.claude.com/v1/oauth/token`
///      using the refresh token and Claude Code's public OAuth client ID. Write the
///      new token back into Keychain so Claude Code itself sees it too.
///   3. GET `api.anthropic.com/api/oauth/usage` with `Bearer <accessToken>` and the
///      `anthropic-beta: oauth-2025-04-20` header. Decode the response.
///
/// Implementation closely follows the open-source OMC plugin
/// (`src/hud/usage-api.ts` v4.13.7), which proved the protocol in practice.
public actor UsageApiClient {

    // MARK: - Configuration

    /// OAuth client ID for Claude Code (public, hard-coded into the CLI binary).
    private let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Beta header required by the usage endpoint.
    private let betaHeader = "oauth-2025-04-20"
    /// Cache time-to-live for successful responses.
    private let cacheTTL: TimeInterval = 30
    /// Refresh tokens that are within this window of expiry before calling.
    private let refreshLeeway: TimeInterval = 60
    /// Exponential backoff caps for 429 responses (matches OMC's pattern).
    private let initialBackoff: TimeInterval = 15
    private let maxBackoff: TimeInterval = 300

    private let urlSession: URLSession

    /// Persistent on-disk cache so the bars survive app restarts and 429
    /// cooldown periods. Loaded lazily on first `fetch()` call.
    private var diskCacheLoaded: Bool = false
    private static var diskCacheURL: URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("CCBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-cache.json", isDirectory: false)
    }

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    // MARK: - Public API

    public enum Failure: Error, Sendable, Equatable {
        case keychainUnavailable
        case credentialsMalformed
        case tokenRefreshFailed
        case http(Int)
        case decoding
        case network(String)
    }

    private var cachedUsage: SubscriptionUsage?
    /// Consecutive 429 count; resets on the next successful fetch.
    private var rateLimitStreak: Int = 0
    /// Absolute time until which we shouldn't even try to call again.
    private var rateLimitedUntil: Date?

    /// Returns either a fresh-or-cached `SubscriptionUsage` snapshot, or a failure.
    /// The cache is bypassed when `force == true`.
    ///
    /// 429 handling: a single 429 enters an exponential-backoff window. While we're
    /// backed off, fetch() returns the last good cached value (if any) so the UI
    /// keeps showing real numbers; callers see success even though we didn't go to
    /// the network. The `cached.fetchedAt` will still be older than `cacheTTL` so
    /// views can decide to indicate "stale" if they want.
    public func fetch(force: Bool = false) async -> Result<SubscriptionUsage, Failure> {
        // Hydrate from disk on first call so we can serve a value immediately
        // (even if it's hours old) while the live fetch is in flight or backing
        // off after a 429.
        if !diskCacheLoaded {
            diskCacheLoaded = true
            if let onDisk = loadDiskCache() {
                cachedUsage = onDisk
            }
        }

        // Honor in-memory cache (unless explicitly forced).
        if !force, let cached = cachedUsage,
           Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return .success(cached)
        }

        // Honor backoff — don't even hit the network. `force` bypasses backoff
        // too, since the user explicitly asked to retry.
        if !force, let until = rateLimitedUntil, Date() < until {
            if let cached = cachedUsage {
                return .success(cached)
            }
            return .failure(.http(429))
        }

        // 1. Credentials
        let creds: Credentials
        do {
            creds = try loadCredentials()
        } catch let f as Failure {
            return .failure(f)
        } catch {
            return .failure(.keychainUnavailable)
        }

        // 2. Refresh if near expiry
        let token: String
        if creds.isExpiringSoon(leeway: refreshLeeway) {
            do {
                token = try await refresh(creds: creds)
            } catch {
                return .failure(.tokenRefreshFailed)
            }
        } else {
            token = creds.accessToken
        }

        // 3. Fetch usage
        do {
            var usage = try await callUsage(token: token)
            usage.fetchedAt = Date()
            cachedUsage = usage
            saveDiskCache(usage)
            rateLimitStreak = 0
            rateLimitedUntil = nil
            return .success(usage)
        } catch let Failure.http(429) {
            rateLimitStreak += 1
            let delay = min(initialBackoff * pow(2, Double(rateLimitStreak - 1)), maxBackoff)
            rateLimitedUntil = Date().addingTimeInterval(delay)
            // Prefer to keep showing the last good value over a hard error.
            if let cached = cachedUsage {
                return .success(cached)
            }
            return .failure(.http(429))
        } catch let f as Failure {
            return .failure(f)
        } catch {
            return .failure(.network(String(describing: error)))
        }
    }

    // MARK: - Keychain

    private struct Credentials: Sendable {
        var accessToken: String
        var refreshToken: String?
        /// Milliseconds since epoch (Claude Code's storage convention).
        var expiresAtMs: Double?

        func isExpiringSoon(leeway: TimeInterval) -> Bool {
            guard let ms = expiresAtMs else { return false }
            let expiry = Date(timeIntervalSince1970: ms / 1000)
            return expiry.timeIntervalSinceNow < leeway
        }
    }

    /// Reads the `Claude Code-credentials` keychain entry and decodes the wrapped
    /// `claudeAiOauth` JSON object. Mirrors the shape verified on 2026-05-26.
    private func loadCredentials() throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw Failure.keychainUnavailable
        }

        guard let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = outer["claudeAiOauth"] as? [String: Any],
              let access = inner["accessToken"] as? String, !access.isEmpty
        else {
            throw Failure.credentialsMalformed
        }
        return Credentials(
            accessToken: access,
            refreshToken: inner["refreshToken"] as? String,
            expiresAtMs: (inner["expiresAt"] as? Double)
                ?? (inner["expiresAt"] as? Int).map(Double.init)
        )
    }

    // MARK: - Token refresh

    /// POST `platform.claude.com/v1/oauth/token` with grant_type=refresh_token.
    /// On success, returns the new access token (and quietly persists it back to Keychain).
    private func refresh(creds: Credentials) async throws -> String {
        guard let refreshToken = creds.refreshToken else {
            throw Failure.tokenRefreshFailed
        }
        var req = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.tokenRefreshFailed
        }
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let newAccess = obj["access_token"] as? String
        else { throw Failure.tokenRefreshFailed }

        // Best-effort write-back so Claude Code (and we) reuse the fresh token.
        let newRefresh = (obj["refresh_token"] as? String) ?? refreshToken
        let expiresIn = (obj["expires_in"] as? Double) ?? (obj["expires_in"] as? Int).map(Double.init) ?? 0
        let newExpiresAtMs = (Date().timeIntervalSince1970 + expiresIn) * 1000
        try? writeBackCredentials(access: newAccess, refresh: newRefresh, expiresAtMs: newExpiresAtMs)

        return newAccess
    }

    /// Updates the Keychain item in place. Failure is non-fatal — we'll just
    /// refresh again next time.
    private func writeBackCredentials(access: String, refresh: String, expiresAtMs: Double) throws {
        // Read current outer JSON so we don't lose unknown fields.
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              var outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var inner = outer["claudeAiOauth"] as? [String: Any]
        else { return }

        inner["accessToken"] = access
        inner["refreshToken"] = refresh
        inner["expiresAt"] = expiresAtMs
        outer["claudeAiOauth"] = inner
        let newData = try JSONSerialization.data(withJSONObject: outer, options: [])

        let updateQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
        ]
        let attrs: [String: Any] = [kSecValueData as String: newData]
        _ = SecItemUpdate(updateQuery as CFDictionary, attrs as CFDictionary)
    }

    // MARK: - Usage endpoint

    /// Calls `GET api.anthropic.com/api/oauth/usage` and decodes the response.
    private func callUsage(token: String) async throws -> SubscriptionUsage {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.network("no HTTPURLResponse")
        }

        if http.statusCode == 429 {
            // Adopt server-provided Retry-After if present.
            if let raStr = http.value(forHTTPHeaderField: "Retry-After"),
               let seconds = Double(raStr) {
                self.rateLimitedUntil = Date().addingTimeInterval(seconds)
            }
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            NSLog("CCBar usage 429  retry-after=\(http.value(forHTTPHeaderField: "Retry-After") ?? "nil") body=\(snippet)")
            throw Failure.http(429)
        }
        guard http.statusCode == 200 else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            NSLog("CCBar usage HTTP \(http.statusCode)  body=\(snippet)")
            throw Failure.http(http.statusCode)
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.decoding
        }

        // Decode each window. Server uses utilization 0~100, ISO8601 resets_at.
        func window(_ key: String) -> SubscriptionUsage.Window? {
            guard let dict = obj[key] as? [String: Any],
                  let util = dict["utilization"] as? Double,
                  let resetsRaw = dict["resets_at"] as? String,
                  let resetsAt = Self.parseISO8601(resetsRaw)
            else { return nil }
            return SubscriptionUsage.Window(utilization: util, resetsAt: resetsAt)
        }

        guard let five = window("five_hour"), let seven = window("seven_day") else {
            throw Failure.decoding
        }

        let extra: SubscriptionUsage.ExtraUsage? = (obj["extra_usage"] as? [String: Any]).map {
            SubscriptionUsage.ExtraUsage(
                isEnabled: ($0["is_enabled"] as? Bool) ?? false,
                monthlyLimit: $0["monthly_limit"] as? Double,
                usedCredits: $0["used_credits"] as? Double,
                utilization: $0["utilization"] as? Double,
                currency: $0["currency"] as? String
            )
        }

        return SubscriptionUsage(
            fiveHour: five,
            sevenDay: seven,
            sevenDayOpus: window("seven_day_opus"),
            sevenDaySonnet: window("seven_day_sonnet"),
            extraUsage: extra,
            fetchedAt: Date()
        )
    }

    // Date.ISO8601FormatStyle is Sendable, unlike ISO8601DateFormatter.
    private static let iso8601WithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso8601Basic = Date.ISO8601FormatStyle()
    private static func parseISO8601(_ s: String) -> Date? {
        if let d = try? iso8601WithFraction.parse(s) { return d }
        return try? iso8601Basic.parse(s)
    }

    // MARK: - Disk cache

    /// Read the last persisted usage snapshot, if any. Returns nil for missing
    /// or malformed cache files — we never throw, since stale numbers are
    /// better than no UI but a broken cache shouldn't break the live fetch.
    private func loadDiskCache() -> SubscriptionUsage? {
        let url = Self.diskCacheURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SubscriptionUsage.self, from: data)
    }

    /// Persist the snapshot atomically. Best-effort — write failures are
    /// logged but never surface to the caller.
    private func saveDiskCache(_ usage: SubscriptionUsage) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(usage)
            try data.write(to: Self.diskCacheURL, options: .atomic)
        } catch {
            NSLog("CCBar usage-cache write failed: \(error)")
        }
    }
}
