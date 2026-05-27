import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Live information about a running `claude` process: working directory,
/// which TTY it sits on, and what GUI app hosts the terminal/IDE above it.
///
/// Note: Claude Code opens its session JSONL only briefly per append, so `lsof`
/// rarely catches it — we rely on `cwd` matching to associate processes with
/// sessions instead. `openJSONLPath` is set on the rare occasion lsof does see it.
public struct ClaudeProcess: Sendable, Hashable {
    public let pid: Int32
    /// `/dev/ttysNNN` or nil (e.g. headless `claude -p` invocations).
    public let tty: String?
    /// Current working directory of the process (the project the user `cd`'d into).
    public let cwd: URL?
    /// Session JSONL caught open by lsof, when it happens. Often nil.
    public let openJSONLPath: URL?
    /// First GUI ancestor of the process, mapped to a HostHint.
    public let hostHint: HostHint
}

/// Inspects the live process table to discover Claude Code sessions.
///
/// Everything goes through standard macOS CLI utilities (`pgrep`, `ps`, `lsof`)
/// and `NSWorkspace.runningApplications`. No special entitlements required.
public enum ProcessProbe {
    public enum ProbeError: Error, Sendable {
        case shellFailed(String, Int32)
    }

    /// One-shot snapshot of all live `claude` processes with host + open-file info.
    /// Safe to call repeatedly — there's no caching. Each call shells out a few times.
    public static func snapshot() throws -> [ClaudeProcess] {
        let pids = try findClaudePIDs()
        guard !pids.isEmpty else { return [] }

        let guiApps = runningGUIApps()
        var results: [ClaudeProcess] = []
        results.reserveCapacity(pids.count)

        for pid in pids {
            let tty = ttyOf(pid: pid)
            let cwd = cwdOf(pid: pid)
            let openPath = openJSONL(pid: pid)
            let host = resolveHost(claudePID: pid, tty: tty, guiApps: guiApps)
            results.append(ClaudeProcess(
                pid: pid,
                tty: tty,
                cwd: cwd,
                openJSONLPath: openPath,
                hostHint: host
            ))
        }
        return results
    }

    /// `lsof -a -d cwd -p <pid> -Fn` → just the working directory.
    static func cwdOf(pid: Int32) -> URL? {
        let r = runShell("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", String(pid), "-Fn"])
        for line in r.stdout.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("n") {
                return URL(fileURLWithPath: String(line.dropFirst()))
            }
        }
        return nil
    }

    // MARK: - Steps

    /// Enumerate live `claude` processes.
    ///
    /// We use `ps -axc -o pid=,comm=` rather than `pgrep -x claude` because
    /// macOS's pgrep occasionally hides processes from the current session's
    /// own ancestor chain — exact reason unclear, but reproducible. `ps -axc`
    /// is consistent.
    static func findClaudePIDs() throws -> [Int32] {
        let r = runShell("/bin/ps", ["-axc", "-o", "pid=,comm="])
        guard r.exitCode == 0 else {
            throw ProbeError.shellFailed("ps", r.exitCode)
        }
        var pids: [Int32] = []
        for line in r.stdout.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
            let pidPart = trimmed[..<spaceIdx]
            let commPart = trimmed[trimmed.index(after: spaceIdx)...]
                .trimmingCharacters(in: .whitespaces)
            if commPart == "claude", let pid = Int32(pidPart) {
                pids.append(pid)
            }
        }
        return pids
    }

    /// `ps -o tty= -p <pid>` returns either `ttys003` (modern) or `s003` (legacy),
    /// or `??` for headless processes. Normalize to `/dev/ttysNNN`.
    static func ttyOf(pid: Int32) -> String? {
        let r = runShell("/bin/ps", ["-o", "tty=", "-p", String(pid)])
        let raw = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != "??", raw != "?" else { return nil }
        if raw.hasPrefix("/") { return raw }
        if raw.hasPrefix("tty") { return "/dev/" + raw }
        return "/dev/tty" + raw
    }

    /// `lsof -p <pid> -Fn` lists open file paths one per line prefixed with `n`.
    /// We pick the first one ending in `.jsonl` that lives under `~/.claude/projects/`.
    static func openJSONL(pid: Int32) -> URL? {
        let r = runShell("/usr/sbin/lsof", ["-p", String(pid), "-Fn"])
        // lsof returns non-zero when some FDs are unreadable, but the readable ones still print.
        // So we ignore exit code and just scan stdout.
        let projectsPrefix = ProjectsRoot.defaultURL.path
        for line in r.stdout.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("n") else { continue }
            let path = String(line.dropFirst())
            if path.hasSuffix(".jsonl"), path.hasPrefix(projectsPrefix) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Walk the parent chain from `claudePID` toward PID 1; the first PID that matches
    /// a known GUI app gives us the host. Falls back to `.unknown` if we never find one.
    static func resolveHost(
        claudePID: Int32,
        tty: String?,
        guiApps: [pid_t: String]
    ) -> HostHint {
        var current = claudePID
        // Cap depth — pathological loops shouldn't happen but bound it anyway.
        for _ in 0..<32 {
            if let bundleID = guiApps[current] {
                return mapBundleID(bundleID, tty: tty)
            }
            let next = parentPID(of: current)
            guard next > 1, next != current else { return .unknown }
            current = next
        }
        return .unknown
    }

    /// `ps -o ppid= -p <pid>` → parent PID.
    private static func parentPID(of pid: Int32) -> Int32 {
        let r = runShell("/bin/ps", ["-o", "ppid=", "-p", String(pid)])
        return Int32(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// NSWorkspace's running-app table mapped by PID → bundle identifier.
    private static func runningGUIApps() -> [pid_t: String] {
        #if canImport(AppKit)
        var map: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier else { continue }
            map[app.processIdentifier] = bundleID
        }
        return map
        #else
        return [:]
        #endif
    }

    /// Bundle ID → HostHint. Covers the apps named in DESIGN.md §4.3.
    private static func mapBundleID(_ bundleID: String, tty: String?) -> HostHint {
        switch bundleID {
        case "com.googlecode.iterm2":
            return .iTerm2(tty: tty ?? "")
        case "com.apple.Terminal":
            return .terminal(tty: tty ?? "")
        case "dev.warp.Warp-Stable", "dev.warp.Warp":
            return .warp
        case "com.mitchellh.ghostty":
            return .ghostty
        case "com.microsoft.VSCode":
            return .vscodeFork(bundleID: bundleID, scheme: "vscode")
        case "com.google.antigravity":
            return .vscodeFork(bundleID: bundleID, scheme: "antigravity")
        default:
            // Cursor / Windsurf use ToDesktop bundle IDs that aren't stable across versions.
            let lower = bundleID.lowercased()
            if lower.contains("cursor") { return .vscodeFork(bundleID: bundleID, scheme: "cursor") }
            if lower.contains("windsurf") { return .vscodeFork(bundleID: bundleID, scheme: "windsurf") }
            // JetBrains family: com.jetbrains.intellij, com.jetbrains.pycharm, …
            if lower.hasPrefix("com.jetbrains.") {
                return .jetbrains(bundleID: bundleID)
            }
            return .unknown
        }
    }
}

// MARK: - Shell helper

private struct ShellResult {
    let exitCode: Int32
    let stdout: String
}

private func runShell(_ executable: String, _ args: [String]) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do {
        try p.run()
    } catch {
        return ShellResult(exitCode: -1, stdout: "")
    }
    let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
    p.waitUntilExit()
    return ShellResult(
        exitCode: p.terminationStatus,
        stdout: String(data: data, encoding: .utf8) ?? ""
    )
}
