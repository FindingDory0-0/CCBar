import Foundation

/// User-set metadata that lives alongside the JSONL data: session aliases,
/// favorite sessions, prompt templates, and any manual host bindings.
///
/// Persisted as a single JSON file under `~/Library/Application Support/CCBar/`.
///
/// Favoriting model: **per session UUID, not per cwd**. Earlier iterations keyed
/// favorites on the project cwd, but that caused unrelated sessions in the same
/// directory to all show the star, which surprised users. Per-session keying
/// matches "this specific conversation is important to me." A future "pin
/// project" feature can be added separately if needed.
public struct Sidecar: Codable, Sendable, Hashable {
    public var aliases: [UUID: String]
    public var favoriteSessions: Set<UUID>
    public var manualHostBinding: [UUID: HostHint]
    /// Per-cwd alias. When the user names a session, we also remember its cwd
    /// here. Future sessions started in the same directory inherit the name —
    /// users that work in the same project across many sessions ("Claude 상태바"
    /// in `~/Documents/AI/etc`) don't have to re-name every fresh `claude` run.
    /// Cleared when the user explicitly resets a session's alias.
    public var cwdAliases: [URL: String]

    public init(
        aliases: [UUID: String] = [:],
        favoriteSessions: Set<UUID> = [],
        manualHostBinding: [UUID: HostHint] = [:],
        cwdAliases: [URL: String] = [:]
    ) {
        self.aliases = aliases
        self.favoriteSessions = favoriteSessions
        self.manualHostBinding = manualHostBinding
        self.cwdAliases = cwdAliases
    }

    /// Decode with backwards compatibility — `cwdAliases` is new, older sidecar
    /// files predate it; older files that still carry `favoriteProjects: [URL]`
    /// are silently dropped (user can re-favorite if needed).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aliases = (try? c.decode([UUID: String].self, forKey: .aliases)) ?? [:]
        favoriteSessions = (try? c.decode(Set<UUID>.self, forKey: .favoriteSessions)) ?? []
        manualHostBinding = (try? c.decode([UUID: HostHint].self, forKey: .manualHostBinding)) ?? [:]
        cwdAliases = (try? c.decode([URL: String].self, forKey: .cwdAliases)) ?? [:]
    }

    public static let empty = Sidecar()
}

/// Loads and saves `Sidecar` to disk. All disk writes go through this actor so
/// SessionStore (and later the UI) never touch the filesystem directly.
public actor SidecarStore {
    private let url: URL
    private var cache: Sidecar

    public init(url: URL = SidecarStore.defaultURL) {
        self.url = url
        self.cache = SidecarStore.loadSync(from: url) ?? .empty
    }

    public static var defaultURL: URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("CCBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sidecar.json")
    }

    public func current() -> Sidecar { cache }

    /// Set or clear a session's alias.
    ///
    /// When `cwd` is provided and a non-empty alias is set, we also remember
    /// the alias under that cwd so future sessions in the same directory
    /// inherit the name. Clearing an alias only drops the per-session mapping
    /// — the cwd mapping survives so other sessions in the directory keep
    /// using it. Use `clearCwdAlias(_:)` to drop the project-wide name.
    public func setAlias(_ alias: String?, for sessionID: UUID, cwd: URL? = nil) throws {
        if let alias, !alias.isEmpty {
            cache.aliases[sessionID] = alias
            if let cwd {
                cache.cwdAliases[cwd.standardizedFileURL] = alias
            }
        } else {
            cache.aliases.removeValue(forKey: sessionID)
        }
        try save()
    }

    /// Forget the per-cwd alias entirely (e.g. user explicitly wants a clean
    /// slate for that project).
    public func clearCwdAlias(_ cwd: URL) throws {
        cache.cwdAliases.removeValue(forKey: cwd.standardizedFileURL)
        try save()
    }

    public func toggleFavorite(sessionID: UUID) throws {
        if cache.favoriteSessions.contains(sessionID) {
            cache.favoriteSessions.remove(sessionID)
        } else {
            cache.favoriteSessions.insert(sessionID)
        }
        try save()
    }

    public func setManualHost(_ hint: HostHint?, for sessionID: UUID) throws {
        if let hint {
            cache.manualHostBinding[sessionID] = hint
        } else {
            cache.manualHostBinding.removeValue(forKey: sessionID)
        }
        try save()
    }

    // MARK: - I/O

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)
        // Atomic write so a crash mid-save doesn't truncate.
        try data.write(to: url, options: .atomic)
    }

    private static func loadSync(from url: URL) -> Sidecar? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }
}
