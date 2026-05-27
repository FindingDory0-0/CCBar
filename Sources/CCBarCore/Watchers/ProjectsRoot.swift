import Foundation

/// Locating and decoding the `~/.claude/projects/` hierarchy.
///
/// Claude Code stores each session as `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`,
/// where `encoded-cwd` is the absolute path with every `/` replaced by `-`.
/// The encoding is lossy (real `-` in the path becomes indistinguishable), so we
/// only use it as a folder discovery hint — the authoritative `cwd` comes from the
/// JSONL content itself.
public enum ProjectsRoot {
    /// Default location: `~/.claude/projects/`.
    public static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Best-effort decode of an encoded folder name back to a filesystem URL.
    /// Returns nil for names that don't start with `-` (i.e., not absolute paths).
    /// Callers should prefer the `cwd` field from the JSONL header when available.
    public static func decodeFolderName(_ name: String) -> URL? {
        guard name.hasPrefix("-") else { return nil }
        let path = name.replacingOccurrences(of: "-", with: "/")
        return URL(fileURLWithPath: path)
    }

    /// List all `*.jsonl` session files under the projects root.
    public static func discoverJSONLFiles(under root: URL = defaultURL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "jsonl" {
                files.append(url)
            }
        }
        return files
    }

    /// Extract a session UUID from a path like `.../1999ca31-58dd-....jsonl`.
    public static func sessionID(from url: URL) -> UUID? {
        let stem = url.deletingPathExtension().lastPathComponent
        return UUID(uuidString: stem)
    }
}
