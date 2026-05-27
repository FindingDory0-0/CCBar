import Foundation
import CCBarCore

@main
struct CCBarCLI {
    static func main() async {
        // Unbuffer stdout so `watch` output streams immediately even when piped.
        setvbuf(stdout, nil, _IONBF, 0)

        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "list"

        switch command {
        case "list":
            await runList()
        case "watch":
            await runWatch()
        case "probe":
            runProbe()
        case "help", "--help", "-h":
            printUsage()
        default:
            FileHandle.standardError.write(Data("unknown command: \(command)\n".utf8))
            printUsage()
            exit(2)
        }
    }

    // MARK: - probe

    static func runProbe() {
        let processes: [ClaudeProcess]
        do {
            processes = try ProcessProbe.snapshot()
        } catch {
            FileHandle.standardError.write(Data("probe failed: \(error)\n".utf8))
            exit(1)
        }
        print("Found \(processes.count) running `claude` process(es)")
        for p in processes {
            print("")
            print("  PID:       \(p.pid)")
            print("  TTY:       \(p.tty ?? "(none)")")
            print("  CWD:       \(p.cwd?.path ?? "(unknown)")")
            print("  OpenJSONL: \(p.openJSONLPath?.lastPathComponent ?? "(none — Claude Code closes per write)")")
            print("  Host:      \(p.hostHint.displayName)  [\(p.hostHint)]")
        }
    }

    // MARK: - list

    static func runList() async {
        // Parse optional flags after the subcommand.
        let args = Array(CommandLine.arguments.dropFirst(2))
        let showAll = args.contains("--all")
        let recentCount: Int = {
            if let i = args.firstIndex(of: "--recent"),
               i + 1 < args.count,
               let n = Int(args[i + 1]) {
                return n
            }
            return 10   // default: 10 most-recent ended sessions
        }()

        let store = SessionStore()
        do {
            try await store.bootstrap()
        } catch {
            FileHandle.standardError.write(Data("bootstrap failed: \(error)\n".utf8))
            exit(1)
        }
        await store.refreshProcessInfo()

        let all = await store.sessions
        let active = all.filter { $0.status != .ended }
        let ended = all.filter { $0.status == .ended }

        let displayed: [Session]
        let summaryLine: String
        if showAll {
            displayed = all
            summaryLine = "All sessions: \(all.count) (\(active.count) active, \(ended.count) ended)"
        } else {
            displayed = active + ended.prefix(recentCount)
            summaryLine = "Active: \(active.count) · Recent ended (top \(min(recentCount, ended.count))/\(ended.count)) shown. Use --all to see everything."
        }

        print(summaryLine)
        print("")
        printTable(displayed)
    }

    // MARK: - watch

    static func runWatch() async {
        let store = SessionStore()
        do {
            try await store.bootstrap()
        } catch {
            FileHandle.standardError.write(Data("bootstrap failed: \(error)\n".utf8))
            exit(1)
        }
        await store.refreshProcessInfo()

        let initial = await store.sessions
        print("Bootstrapped \(initial.count) sessions. Watching \(ProjectsRoot.defaultURL.path) …")
        print("(Ctrl-C to exit)\n")

        let watcher = JSONLWatcher()

        // Periodic process info refresh — every 5s while watching.
        let refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await store.refreshProcessInfo()
            }
        }
        defer { refreshTask.cancel() }

        for await event in watcher.events() {
            await store.ingest(event: event)
            let shortName = event.url.lastPathComponent
            let ts = Self.timestamp()
            print("[\(ts)] \(emoji(for: event.kind)) \(event.kind) \(shortName)")
            if let id = ProjectsRoot.sessionID(from: event.url),
               let session = await store.session(id: id) {
                let preview = session.lastAssistantMessage ?? session.lastUserMessage ?? ""
                let trimmedPreview = String(preview.prefix(80))
                    .replacingOccurrences(of: "\n", with: " ⏎ ")
                print("           \(session.defaultDisplayName)  ·  \(session.messageCount) msgs  ·  \(formatTokens(session.usage.totalTokens))")
                if !trimmedPreview.isEmpty {
                    print("           “\(trimmedPreview)”")
                }
            }
        }
    }

    // MARK: - Formatting

    static func printTable(_ sessions: [Session]) {
        guard !sessions.isEmpty else {
            print("(no sessions found under \(ProjectsRoot.defaultURL.path))")
            return
        }

        // Column widths
        let idW = 8
        let actW = 10
        let statW = 8
        let hostW = 14
        let msgW = 6
        let tokW = 10

        let header = pad("ID", idW)
            + "  " + pad("ACTIVITY", actW)
            + "  " + pad("STATUS", statW)
            + "  " + pad("HOST", hostW)
            + "  " + pad("MSGS", msgW, alignRight: true)
            + "  " + pad("TOKENS", tokW, alignRight: true)
            + "  TITLE / CWD"
        print(header)
        print(String(repeating: "─", count: header.count))

        let now = Date()
        for s in sessions {
            let row = pad(String(s.id.uuidString.prefix(8)), idW)
                + "  " + pad(relativeTime(from: s.lastActivity, to: now), actW)
                + "  " + pad(s.status.rawValue, statW)
                + "  " + pad(s.hostHint.displayName, hostW)
                + "  " + pad(String(s.messageCount), msgW, alignRight: true)
                + "  " + pad(formatTokens(s.usage.totalTokens), tokW, alignRight: true)
                + "  " + s.defaultDisplayName
                + "  ·  " + abbreviateHome(s.cwd.path)
            print(row)
        }
    }

    static func pad(_ s: String, _ width: Int, alignRight: Bool = false) -> String {
        if s.count >= width { return String(s.prefix(width)) }
        let padding = String(repeating: " ", count: width - s.count)
        return alignRight ? padding + s : s + padding
    }

    static func relativeTime(from date: Date, to now: Date) -> String {
        let dt = now.timeIntervalSince(date)
        switch dt {
        case ..<60: return "\(Int(dt))s ago"
        case ..<3600: return "\(Int(dt / 60))m ago"
        case ..<86400: return "\(Int(dt / 3600))h ago"
        case ..<(86400 * 30): return "\(Int(dt / 86400))d ago"
        default:
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: date)
        }
    }

    static func formatTokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000:
            return String(format: "%.1fK", Double(n) / 1_000)
        default:
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func emoji(for kind: JSONLWatcher.Event.Kind) -> String {
        switch kind {
        case .created: "🆕"
        case .modified: "✏️"
        case .removed: "🗑"
        case .renamed: "🔀"
        }
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    static func printUsage() {
        print("""
        ccbar-cli — verification CLI for CCBar M1 data pipeline

        Usage:
          ccbar-cli list                Active sessions + 10 most-recent ended
          ccbar-cli list --recent N     Active + N most-recent ended
          ccbar-cli list --all          Everything (verification dump)
          ccbar-cli watch               Live tail JSONL events under ~/.claude/projects/
          ccbar-cli probe               Dump live `claude` process info (pid, cwd, host)
          ccbar-cli help                Show this message
        """)
    }
}
