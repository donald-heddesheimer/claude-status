import Foundation

/// What the pet knows about its own plumbing.
///
/// When the pet sits there doing nothing, there are four different reasons and
/// they need completely different fixes: the listener never bound, the tunnel is
/// down, the hooks aren't installed, or events are arriving and being rejected.
/// From the outside all four look identical — a still critter — so the app has
/// to be able to say which one it is.
///
/// Main thread only. Every mutation is on the same hop that touches the UI.
public final class Health {
    public enum Listener: Equatable {
        case starting
        case listening(port: UInt16)
        case failed(String)

        public var isUp: Bool {
            if case .listening = self { return true }
            return false
        }
    }

    /// An event that reached the port and was turned away. Kept because "the
    /// pet does nothing" and "the pet is refusing your events" are the two
    /// failure modes that look the same and mean opposite things.
    public struct Rejection {
        public let at: Date
        public let reason: String
        /// Safe to display: a header name, an account, an agent — never a body.
        public let detail: String

        public var summary: String {
            detail.isEmpty ? reason : "\(reason) (\(detail))"
        }
    }

    /// Last time each host was heard from, for tunnel liveness.
    public struct Peer {
        public let host: String
        public let remote: Bool
        public var lastSeen: Date
        public var events: Int
    }

    public private(set) var listener: Listener = .starting
    public private(set) var lastEventAt: Date?
    public private(set) var lastEventSummary: String?
    public private(set) var lastRejection: Rejection?
    public private(set) var acceptedCount = 0
    public private(set) var rejectedCount = 0
    public private(set) var peers: [String: Peer] = [:]
    /// One-off things the app wants to tell you that aren't events — a token
    /// whose permissions we tightened, a login item that wouldn't register.
    public private(set) var notes: [String] = []
    public let startedAt = Date()

    /// Fires on any change, so the health view can be a plain observer rather
    /// than a polling timer.
    public var onChange: (() -> Void)?

    public init() {}

    public func listenerBound(port: UInt16) {
        listener = .listening(port: port)
        onChange?()
    }

    public func listenerFailed(_ message: String) {
        listener = .failed(message)
        onChange?()
    }

    public func accepted(_ event: StateEvent) {
        acceptedCount += 1
        lastEventAt = Date()
        lastEventSummary = "\(event.host) · \(event.state)"

        var peer = peers[event.host] ?? Peer(host: event.host, remote: event.remote,
                                             lastSeen: Date(), events: 0)
        peer.lastSeen = Date()
        peer.events += 1
        peers[event.host] = peer
        onChange?()
    }

    public func note(_ message: String) {
        guard !notes.contains(message) else { return }
        notes.append(message)
        onChange?()
    }

    public func rejected(reason: String, detail: String = "") {
        rejectedCount += 1
        lastRejection = Rejection(at: Date(), reason: reason, detail: detail)
        onChange?()
    }

    /// A remote host that has gone quiet for longer than this is reported as a
    /// probable dropped tunnel. Generous, because an idle session legitimately
    /// says nothing for a long time — this is about distinguishing "quiet" from
    /// "gone", and a false "tunnel down" is worse than a late one.
    private static let peerSilence: TimeInterval = 15 * 60

    public struct Line {
        public let label: String
        public let value: String
        public let ok: Bool?
    }

    /// The health view's whole content, as flat rows.
    public func report(now: Date = Date()) -> [Line] {
        var lines: [Line] = []

        switch listener {
        case .starting:
            lines.append(Line(label: "Listener", value: "starting…", ok: nil))
        case .listening(let port):
            lines.append(Line(label: "Listener", value: "127.0.0.1:\(port)", ok: true))
        case .failed(let message):
            lines.append(Line(label: "Listener", value: message, ok: false))
        }

        if let lastEventAt {
            lines.append(Line(label: "Last event",
                              value: "\(Self.ago(now.timeIntervalSince(lastEventAt))) — \(lastEventSummary ?? "")",
                              ok: true))
        } else {
            lines.append(Line(label: "Last event",
                              value: "none yet — is the plugin installed?", ok: false))
        }

        for peer in peers.values.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            let silence = now.timeIntervalSince(peer.lastSeen)
            let stale = peer.remote && silence > Self.peerSilence
            let label = peer.remote ? "Tunnel · \(peer.host)" : "Local · \(peer.host)"
            lines.append(Line(
                label: label,
                value: stale
                    ? "silent \(Self.ago(silence)) — tunnel may be down"
                    : "\(peer.events) events, last \(Self.ago(silence))",
                ok: !stale))
        }

        if let rejection = lastRejection {
            lines.append(Line(
                label: "Rejected",
                value: "\(rejectedCount) total · \(rejection.summary) \(Self.ago(now.timeIntervalSince(rejection.at)))",
                ok: false))
        }

        for note in notes {
            lines.append(Line(label: "Note", value: note, ok: nil))
        }

        return lines
    }

    static func ago(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}
