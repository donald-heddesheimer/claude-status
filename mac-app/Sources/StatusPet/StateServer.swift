import Foundation
import Network

/// One lifecycle event from a Claude Code session, local or remote.
struct StateEvent {
    let sessionID: String
    let state: String
    let host: String
    let remote: Bool
    let tool: String
    let cwd: String
}

/// Minimal HTTP request parser. We only ever serve one route from loopback,
/// so a full HTTP stack would be dead weight.
private struct HTTPRequest {
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

        let expected = Int(parsed["content-length"] ?? "0") ?? 0
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

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "StatusPet", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"])
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only. Never reachable from another machine directly.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
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
        if let token, !token.isEmpty {
            let offered = request.headers["x-petdex-update-token"]
                ?? request.headers["x-claude-status-token"]
            guard offered == token else { return }
        }

        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return
        }

        onEvent(StateEvent(
            sessionID: json["session_id"] as? String ?? "unknown",
            state: (json["state"] as? String ?? "idle").lowercased(),
            host: json["host"] as? String ?? "local",
            remote: json["remote"] as? Bool ?? false,
            tool: json["tool"] as? String ?? "",
            cwd: json["cwd"] as? String ?? ""
        ))
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
