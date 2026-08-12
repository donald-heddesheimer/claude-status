import Foundation
import Network

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// One lifecycle event from a Claude Code session, local or remote.
public struct StateEvent: Equatable {
    public let sessionID: String
    public let state: String
    /// The account the session runs under. Empty from hooks older than 0.1.3.
    /// On a shared host this is the only thing separating your sessions from
    /// everyone else's — loopback isn't per-user, so the pet hears them all.
    public let user: String
    public let host: String
    public let remote: Bool
    public let tool: String
    /// What this tool call is about — a filename, a Bash description, a search
    /// pattern. Empty when the hook had nothing worth reporting.
    public let detail: String
    public let cwd: String
    /// Which agent produced this — "claude-code", "codex", "opencode".
    public let agentSource: String

    public init(sessionID: String, state: String, user: String, host: String, remote: Bool,
                tool: String, detail: String, cwd: String, agentSource: String) {
        self.sessionID = sessionID
        self.state = state
        self.user = user
        self.host = host
        self.remote = remote
        self.tool = tool
        self.detail = detail
        self.cwd = cwd
        self.agentSource = agentSource
    }

    /// Longest each field may be once parsed.
    ///
    /// Every one of these is drawn on screen or used as a dictionary key, and
    /// the sender is not necessarily the hook — anything that can reach loopback
    /// can post here. Truncating at the boundary means nothing downstream has to
    /// wonder how long a "tool name" can get.
    enum Limit {
        static let sessionID = 128
        static let state = 32
        static let user = 64
        static let host = 64
        static let tool = 64
        static let detail = 200
        static let cwd = 512
        static let agent = 32
    }

    /// Reads one field: trimmed, stripped of control characters, length capped.
    ///
    /// Control characters matter beyond tidiness — a newline in `detail` would
    /// let a caller forge extra lines in the debug log, and the text renderer
    /// has no business being handed a `\u{7}` either.
    static func field(_ json: [String: Any], _ key: String, limit: Int) -> String {
        guard let raw = json[key] as? String else { return "" }
        let cleaned = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(limit))
    }

    /// Builds an event from a decoded JSON body, or nil if it isn't an object.
    public static func parse(_ body: Data) -> StateEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return StateEvent(
            sessionID: field(json, "session_id", limit: Limit.sessionID).nonEmpty ?? "unknown",
            state: field(json, "state", limit: Limit.state).lowercased().nonEmpty ?? "idle",
            user: field(json, "user", limit: Limit.user),
            host: field(json, "host", limit: Limit.host).nonEmpty ?? "local",
            remote: json["remote"] as? Bool ?? false,
            tool: field(json, "tool", limit: Limit.tool),
            detail: field(json, "detail", limit: Limit.detail),
            cwd: field(json, "cwd", limit: Limit.cwd),
            agentSource: field(json, "agent_source", limit: Limit.agent)
                .lowercased().nonEmpty ?? "claude-code"
        )
    }
}

/// Minimal HTTP request parser. We only ever serve one route from loopback,
/// so a full HTTP stack would be dead weight.
public struct HTTPRequest {
    /// A real event is a few hundred bytes. This is generous by two orders of
    /// magnitude and still small enough that a declared length past it is
    /// obviously not one of ours.
    public static let maxBody = 16 * 1024
    /// Headers alone should never approach this. Capping them separately stops a
    /// peer from parking on the socket dribbling header bytes forever.
    public static let maxHead = 16 * 1024

    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    /// Returns nil while the request is still incomplete, so the caller keeps
    /// reading. A request that can never become valid also returns nil — the
    /// caller's byte cap then closes the connection.
    public init?(_ raw: Data) {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headData = raw.subdata(in: raw.startIndex..<split.lowerBound)
        guard headData.count <= Self.maxHead,
              let head = String(data: headData, encoding: .utf8) else { return nil }

        let lines = head.components(separatedBy: "\r\n")
        // "POST /state HTTP/1.1" — anything that isn't three words isn't HTTP.
        let requestLine = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }
        method = requestLine[0].uppercased()
        // Query strings are not part of any route we serve, but a client may
        // still append one; compare against the path alone rather than 404ing
        // on a harmless `?t=1`.
        path = String(requestLine[1].split(separator: "?", maxSplits: 1).first ?? "")

        var parsed: [String: String] = [:]
        for line in lines.dropFirst() {
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

/// What the listener decided about one request, and why.
///
/// Separated from the socket so the whole decision is a pure function of the
/// request — that is what makes it testable, and what lets the health view
/// report a reason instead of a shrug.
public enum Verdict: Equatable {
    case accept(StateEvent)
    case reject(status: Int, reason: String, detail: String)

    public static func reject(_ status: Int, _ reason: String, _ detail: String = "") -> Verdict {
        .reject(status: status, reason: reason, detail: detail)
    }
}

/// Listens on 127.0.0.1 for state pings.
///
/// Binding to loopback is what makes the SSH case work: on a remote host the
/// same address is an SSH RemoteForward, so hooks need no idea where they run.
public final class StateServer {
    public static let route = "/state"

    private let port: UInt16
    private let token: String?
    private let onVerdict: (Verdict) -> Void
    private var listener: NWListener?

    public init(port: UInt16, token: String?, onVerdict: @escaping (Verdict) -> Void) {
        self.port = port
        self.token = token
        self.onVerdict = onVerdict
    }

    /// The whole access-control decision, as a pure function.
    public static func judge(_ request: HTTPRequest, token: String?) -> Verdict {
        // Loopback is reachable from the browser. Any page the user visits can
        // POST here — write-only, since the reply carries no CORS headers, but
        // enough to inject a session that sits on screen for the waiting TTL.
        //
        // An `Origin` header means a browser sent it, and nothing legitimate
        // here has one. Requiring a JSON content type forces a CORS preflight
        // for anything that isn't a plain form post, and the preflight is an
        // OPTIONS we never answer.
        if let origin = request.headers["origin"] {
            return .reject(403, "browser origin", String(origin.prefix(64)))
        }
        guard request.method == "POST" else {
            return .reject(405, "method not allowed", request.method)
        }
        guard request.path == route else {
            return .reject(404, "unknown route", String(request.path.prefix(64)))
        }
        guard (request.headers["content-type"] ?? "")
            .lowercased()
            .hasPrefix("application/json") else {
            return .reject(415, "content type not JSON",
                           String((request.headers["content-type"] ?? "none").prefix(64)))
        }

        if let token, !token.isEmpty {
            let offered = request.headers["x-petdex-update-token"]
                ?? request.headers["x-claude-status-token"]
            guard let offered, Self.constantTimeEquals(offered, token) else {
                return .reject(401, offered == nil ? "no token" : "token mismatch")
            }
        }

        guard let event = StateEvent.parse(request.body) else {
            return .reject(400, "body is not JSON")
        }
        return .accept(event)
    }

    /// Starts listening. `onReady` fires once the port is genuinely bound.
    ///
    /// The bind happens asynchronously, so a port collision never surfaces as a
    /// thrown error — it arrives on `stateUpdateHandler`. Without handling that,
    /// a second pet launches, silently fails to bind, and sits there as a window
    /// that receives nothing. So a failure here is loud.
    public func start(onReady: @escaping () -> Void,
                      onFailure: @escaping (String) -> Void) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "StatusPet", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"])
        }

        let params = NWParameters.tcp
        // Loopback only. Never reachable from another machine directly.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener = try NWListener(using: params)

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                onReady()
            case .failed(let error), .waiting(let error):
                // `.waiting` is how "address already in use" arrives: the
                // listener would otherwise retry forever in silence.
                onFailure("\(error)")
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

    public func stop() {
        listener?.cancel()
        listener = nil
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
                let verdict = Self.judge(request, token: self.token)
                self.onVerdict(verdict)
                self.reply(connection, verdict: verdict)
                return
            }
            // Guard against a peer that opens a socket and dribbles forever.
            if isComplete || buffer.count > HTTPRequest.maxHead + HTTPRequest.maxBody {
                connection.cancel()
                return
            }
            self.read(connection, buffer: buffer)
        }
    }

    /// Takes time proportional to the token's length rather than to how much of
    /// it matched. The attacker here is a local process with unlimited attempts
    /// and no network jitter to hide the signal — the most favourable setting a
    /// timing attack gets. Length is still observable, which is fine.
    static func constantTimeEquals(_ offered: String, _ expected: String) -> Bool {
        let lhs = Array(offered.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == rhs.count else { return false }

        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    /// Answers with the real status code.
    ///
    /// The reply is unreadable to a browser — no CORS headers — so the only
    /// thing distinct codes tell apart is `curl` from the remote host, which is
    /// exactly who needs them. "Connection refused" versus 401 versus 404 is the
    /// difference between a dead tunnel, a token mismatch and a wrong port, and
    /// making someone guess between those is the tunnel-debugging experience
    /// this project exists to avoid.
    private func reply(_ connection: NWConnection, verdict: Verdict) {
        let status: Int
        let payload: String
        switch verdict {
        case .accept:
            status = 200
            payload = "{\"ok\":true}"
        case .reject(let code, let reason, _):
            status = code
            payload = "{\"ok\":false,\"error\":\"\(reason)\"}"
        }

        let body = Data(payload.utf8)
        let head = "HTTP/1.1 \(status) \(Self.phrase(status))\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func phrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 415: return "Unsupported Media Type"
        default:  return "Error"
        }
    }
}
