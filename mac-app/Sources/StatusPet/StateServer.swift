import Foundation
import Network

/// One lifecycle event from a Claude Code session, local or remote.
struct StateEvent {
    let sessionID: String
    let state: String
    /// The account the session runs under. Empty from hooks older than 0.1.3.
    /// On a shared host this is the only thing separating your sessions from
    /// everyone else's — loopback isn't per-user, so the pet hears them all.
    let user: String
    let host: String
    let remote: Bool
    let tool: String
    /// What this tool call is about — a filename, a Bash description, a search
    /// pattern. Empty when the hook had nothing worth reporting.
    let detail: String
    let cwd: String
}

/// Minimal HTTP request parser. We only ever serve one route from loopback,
/// so a full HTTP stack would be dead weight.
private struct HTTPRequest {
    /// Matches the caller's read cap. A declared length past this is malformed,
    /// not merely large.
    static let maxBody = 256 * 1024

    let headers: [String: String]
    let body: Data

    /// Returns nil while the request is still incomplete, so the caller keeps reading.
    init?(_ raw: Data) {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: raw.subdata(in: raw.startIndex..<split.lowerBound),
                                encoding: .utf8) else { return nil }

        var parsed: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            parsed[key] = value
        }

        // `Int` happily parses a negative, and `prefix(-1)` traps. Anything out
        // of range is treated as never-complete, so the caller's own cap closes
        // the connection.
        let expected = Int(parsed["content-length"] ?? "0") ?? 0
        guard expected >= 0, expected <= Self.maxBody else { return nil }

        let received = raw.subdata(in: split.upperBound..<raw.endIndex)
        guard received.count >= expected else { return nil }

        headers = parsed
        body = received.prefix(expected)
    }
}

/// Listens on 127.0.0.1 for state pings.
///
/// Binding to loopback is what makes the SSH case work: on a remote host the
/// same address is an SSH RemoteForward, so hooks need no idea where they run.
final class StateServer {
    private let port: UInt16
    private let token: String?
    private let onEvent: (StateEvent) -> Void
    private var listener: NWListener?

    init(port: UInt16, token: String?, onEvent: @escaping (StateEvent) -> Void) {
        self.port = port
        self.token = token
        self.onEvent = onEvent
    }

    /// Starts listening. `onReady` fires once the port is genuinely bound.
    ///
    /// The bind happens asynchronously, so a port collision never surfaces as a
    /// thrown error — it arrives on `stateUpdateHandler`. Without handling that,
    /// a second pet launches, silently fails to bind, and sits there as a window
    /// that receives nothing. So a failure here is fatal and loud.
    func start(onReady: @escaping () -> Void) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "StatusPet", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"])
        }

        let params = NWParameters.tcp
        // Loopback only. Never reachable from another machine directly.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener = try NWListener(using: params)
        let port = self.port

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                onReady()
            case .failed(let error), .waiting(let error):
                // `.waiting` is how "address already in use" arrives: the
                // listener would otherwise retry forever in silence.
                Self.abort(port: port, error: error)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
    }

    private static func abort(port: UInt16, error: NWError) -> Never {
        let message = """
        claude-status: could not listen on 127.0.0.1:\(port) — \(error)

        A pet is most likely already running. Check and clear it with:
            pgrep -fl StatusPet
            pkill -f StatusPet

        """
        FileHandle.standardError.write(Data(message.utf8))
        exit(1)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            if error != nil { connection.cancel(); return }

            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if let request = HTTPRequest(buffer) {
                self.handle(request)
                self.reply(connection)
                return
            }
            // Guard against a peer that opens a socket and dribbles forever.
            if isComplete || buffer.count > 256 * 1024 {
                connection.cancel()
                return
            }
            self.read(connection, buffer: buffer)
        }
    }

    private func handle(_ request: HTTPRequest) {
        // Loopback is reachable from the browser. Any page the user visits can
        // POST here — write-only, since the reply carries no CORS headers, but
        // enough to inject a session that sits on screen for the waiting TTL.
        //
        // Two checks close it. An `Origin` header means a browser sent it, and
        // nothing legitimate here has one. Requiring a JSON content type forces
        // a CORS preflight for anything that isn't a plain form post, and the
        // preflight is an OPTIONS we never answer.
        guard request.headers["origin"] == nil else { return }
        guard (request.headers["content-type"] ?? "")
            .lowercased()
            .hasPrefix("application/json") else { return }

        if let token, !token.isEmpty {
            let offered = request.headers["x-petdex-update-token"]
                ?? request.headers["x-claude-status-token"]
            guard let offered, Self.constantTimeEquals(offered, token) else { return }
        }

        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return
        }

        onEvent(StateEvent(
            sessionID: json["session_id"] as? String ?? "unknown",
            state: (json["state"] as? String ?? "idle").lowercased(),
            user: json["user"] as? String ?? "",
            host: json["host"] as? String ?? "local",
            remote: json["remote"] as? Bool ?? false,
            tool: json["tool"] as? String ?? "",
            detail: json["detail"] as? String ?? "",
            cwd: json["cwd"] as? String ?? ""
        ))
    }

    /// Takes time proportional to the token's length rather than to how much of
    /// it matched. The attacker here is a local process with unlimited attempts
    /// and no network jitter to hide the signal — the most favourable setting a
    /// timing attack gets. Length is still observable, which is fine.
    private static func constantTimeEquals(_ offered: String, _ expected: String) -> Bool {
        let lhs = Array(offered.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == rhs.count else { return false }

        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private func reply(_ connection: NWConnection) {
        let body = Data("{\"ok\":true}".utf8)
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
