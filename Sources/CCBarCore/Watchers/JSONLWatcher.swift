import Foundation
import CoreServices

/// Watches `~/.claude/projects/` recursively for `.jsonl` file events using FSEvents.
///
/// Emits raw file-level events; callers (typically SessionStore) decide whether each
/// event triggers a parse, an incremental tail-follow, or a session removal.
public final class JSONLWatcher: @unchecked Sendable {
    public struct Event: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case created, modified, removed, renamed
        }
        public let kind: Kind
        public let url: URL
    }

    private let root: URL
    private let queue = DispatchQueue(label: "CCBar.JSONLWatcher", qos: .utility)
    private var stream: FSEventStreamRef?

    public init(root: URL = ProjectsRoot.defaultURL) {
        self.root = root
    }

    /// Returns an AsyncStream of file events. The underlying FSEventStream is started
    /// on first iteration and stopped when the stream is cancelled or deallocated.
    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            queue.async { [weak self] in
                self?.startStream(yield: { continuation.yield($0) })
            }
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { [weak self] in
                    self?.stopStream()
                }
            }
        }
    }

    // MARK: - FSEventStream lifecycle (called on `queue`)

    private func startStream(yield: @escaping @Sendable (Event) -> Void) {
        guard stream == nil else { return }

        // Box the closure so we can recover it inside the C callback via Unmanaged.
        let box = YieldBox(yield: yield, rootPath: root.path)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<YieldBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let paths: CFArray = [root.path] as CFArray
        // UseCFTypes makes `eventPaths` arrive as CFArrayRef of CFStringRef (vs. a C string array).
        // FileEvents enables per-file granularity. NoDefer dispatches the first batch without delay.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            JSONLWatcher.callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else {
            // Context retained the box; release it so we don't leak when creation fails.
            Unmanaged<YieldBox>.fromOpaque(context.info!).release()
            return
        }

        FSEventStreamSetDispatchQueue(s, queue)
        let started = FSEventStreamStart(s)
        if ProcessInfo.processInfo.environment["CCBAR_WATCH_DEBUG"] != nil {
            let msg = "FSEv: started=\(started) latest=\(FSEventStreamGetLatestEventId(s)) root=\(root.path)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
        stream = s
    }

    private func stopStream() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit {
        // FSEventStream APIs are thread-safe to call from deinit.
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    // MARK: - C callback

    private final class YieldBox: @unchecked Sendable {
        let yield: @Sendable (Event) -> Void
        let rootPath: String
        init(yield: @escaping @Sendable (Event) -> Void, rootPath: String) {
            self.yield = yield
            self.rootPath = rootPath
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flagsPtr, _ in
        guard let info else { return }
        let box = Unmanaged<YieldBox>.fromOpaque(info).takeUnretainedValue()
        let debug = ProcessInfo.processInfo.environment["CCBAR_WATCH_DEBUG"] != nil

        let cfPaths = unsafeBitCast(paths, to: CFArray.self)
        guard let pathStrings = cfPaths as? [String] else {
            if debug { FileHandle.standardError.write(Data("FSEv: cast failed\n".utf8)) }
            return
        }
        let flagsBuf = UnsafeBufferPointer(start: flagsPtr, count: count)

        if debug {
            let msg = "FSEv: \(count) paths\n"
            FileHandle.standardError.write(Data(msg.utf8))
            for i in 0..<count {
                let detail = "  [\(i)] flags=\(String(flagsBuf[i], radix: 16)) path=\(pathStrings[i])\n"
                FileHandle.standardError.write(Data(detail.utf8))
            }
        }

        for i in 0..<count {
            let path = pathStrings[i]
            guard path.hasSuffix(".jsonl"), path.hasPrefix(box.rootPath) else { continue }
            let f = flagsBuf[i]
            let url = URL(fileURLWithPath: path)
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
                box.yield(Event(kind: .created, url: url))
            }
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0 {
                box.yield(Event(kind: .modified, url: url))
            }
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 {
                box.yield(Event(kind: .renamed, url: url))
            }
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
                box.yield(Event(kind: .removed, url: url))
            }
        }
    }
}
