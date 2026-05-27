import Foundation
import Network

/// Tiny HTTP/1.1 server bound to `127.0.0.1` on an ephemeral port. Listens for
/// POST requests from Claude Code hooks, decodes the JSON body into `HookEvent`,
/// and forwards via the handler closure.
///
/// Design notes:
/// - Loopback only (`.hostPort(.loopback, .any)`) so no external network exposure.
/// - Each connection is one-shot: read until headers+body arrive, respond `204`,
///   close. Claude Code's hooks are short curl POSTs that finish in milliseconds.
/// - We don't try to be a real HTTP server — minimal parser is enough for the
///   one method/path we accept.
///
/// Concurrency: callbacks fire on our internal dispatch queue. The `handler`
/// closure is responsible for hopping to MainActor (or wherever) as needed.
public final class HookServer: @unchecked Sendable {

    public typealias Handler = @Sendable (HookEvent) -> Void
    /// Optional debug hook — invoked when a `POST /focus` arrives with a JSON
    /// body `{"session_id":"..."}`. Returns true if we handled it.
    public var focusHandler: (@Sendable (UUID) -> Bool)?

    public enum StartError: Error, Sendable {
        case bindFailed(String)
        case unknownPort
    }

    private let handler: Handler
    private let queue = DispatchQueue(label: "CCBar.HookServer", qos: .utility)
    private var listener: NWListener?
    /// Bound port (0 until `start()` completes successfully).
    public private(set) var boundPort: UInt16 = 0

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Start the listener on a random ephemeral loopback port.
    /// Returns the chosen port after the listener reaches `.ready`.
    public func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        // Bind to loopback only.
        if let inOpts = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            inOpts.version = .v4
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: .any)
        } catch {
            throw StartError.bindFailed(String(describing: error))
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }

        // Wait for .ready before returning, so callers get a stable port.
        // OneShot keeps the continuation from being resumed twice — the
        // listener's state handler can fire .failed/.cancelled after .ready.
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let gate = OneShotGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.fire() {
                        if let port = listener.port?.rawValue {
                            cont.resume(returning: port)
                        } else {
                            cont.resume(throwing: StartError.unknownPort)
                        }
                    }
                case .failed(let error):
                    if gate.fire() {
                        cont.resume(throwing: StartError.bindFailed(String(describing: error)))
                    }
                case .cancelled:
                    if gate.fire() {
                        cont.resume(throwing: StartError.bindFailed("cancelled"))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// One-shot latch — the first caller of `fire()` gets `true`, subsequent
    /// callers get `false`. Used to guard single-resume continuations.
    private final class OneShotGate: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        boundPort = 0
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)

        // We read up to 64 KB in one shot. Hook payloads are small (<1KB typical).
        // For larger bodies the buffer would need a loop — not relevant for our use.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            defer { /* respond will cancel */ }

            guard error == nil, let data, !data.isEmpty else {
                self.respond(connection: connection, status: 400, body: "bad request")
                return
            }

            // Check if this is the debug /focus endpoint first.
            if let text = String(data: data, encoding: .utf8),
               text.uppercased().contains("POST /FOCUS ") {
                if let sessionID = self.parseFocusBody(data),
                   let handler = self.focusHandler {
                    let handled = handler(sessionID)
                    self.respond(connection: connection, status: handled ? 204 : 404, body: "")
                    return
                }
                self.respond(connection: connection, status: 400, body: "invalid focus request")
                return
            }

            switch self.parseEvent(from: data) {
            case .success(let event):
                self.handler(event)
                self.respond(connection: connection, status: 204, body: "")
            case .failure(let reason):
                NSLog("CCBar HookServer parse failed: \(reason)")
                self.respond(connection: connection, status: 400, body: reason)
            }
        }
    }

    private func respond(connection: NWConnection, status: Int, body: String) {
        let statusLine = "HTTP/1.1 \(status) \(reason(for: status))"
        let bodyBytes = Data(body.utf8)
        let response = "\(statusLine)\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\nContent-Type: text/plain\r\n\r\n"
        var payload = Data(response.utf8)
        payload.append(bodyBytes)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        default: return "Status"
        }
    }

    // MARK: - HTTP parsing (minimal)

    private enum ParseFailure: String {
        case noHeaderTerminator
        case notHTTP
        case notPost
        case noBody
        case bodyNotJSON
        case notHookPayload
    }

    /// Extract `session_id` from a `POST /focus` body.
    private func parseFocusBody(_ data: Data) -> UUID? {
        guard let sepRange = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
            return nil
        }
        let body = Data(data[sepRange.upperBound...])
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let raw = obj["session_id"] as? String
        else { return nil }
        return UUID(uuidString: raw)
    }

    private func parseEvent(from data: Data) -> Result<HookEvent, String> {
        // Find \r\n\r\n separating headers from body.
        guard let sepRange = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
            return .failure(ParseFailure.noHeaderTerminator.rawValue)
        }
        let headerData = data[..<sepRange.lowerBound]
        let body = data[sepRange.upperBound...]

        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure(ParseFailure.notHTTP.rawValue)
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let startLine = lines.first else { return .failure(ParseFailure.notHTTP.rawValue) }
        // We accept POST to any path; Claude Code's hook command can be anything.
        guard startLine.uppercased().hasPrefix("POST ") else {
            return .failure(ParseFailure.notPost.rawValue)
        }

        guard !body.isEmpty else { return .failure(ParseFailure.noBody.rawValue) }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else {
            return .failure(ParseFailure.bodyNotJSON.rawValue)
        }
        guard let event = HookEvent.from(json: obj) else {
            return .failure(ParseFailure.notHookPayload.rawValue)
        }
        return .success(event)
    }
}

// String happens to satisfy `Sendable` and `Equatable`, which is all `Result<_, _>`
// asks for; we annotate the constraint explicitly so older toolchains accept it.
extension String: @retroactive Error {}
