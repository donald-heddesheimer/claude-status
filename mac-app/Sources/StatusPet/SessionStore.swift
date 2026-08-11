import Foundation

/// What the pet should be doing, collapsed from every session it knows about.
enum PetMood {
    case asleep   // nothing connected
    case idle     // sessions alive, none busy
    case busy     // thinking or running tools
    case waiting  // needs you — permission prompt or input
}

/// Tracks every Claude Code session reporting in, local and remote alike, and
/// collapses them into a single mood for the pet.
final class SessionStore {
    struct Session {
        var state: String
        var host: String
        var remote: Bool
        var tool: String
        var seen: Date
    }

    private(set) var sessions: [String: Session] = [:]
    var onChange: (() -> Void)?

    /// A session that stops reporting is presumed gone, but how long we wait
    /// depends on what it was doing.
    ///
    /// A *working* session going quiet means something broke — most likely a
    /// dropped SSH tunnel — so give up quickly rather than strand the pet
    /// mid-thought. An *idle* session going quiet is just you not typing, which
    /// is normal and can last hours, so hold it far longer. `SessionEnd`
    /// removes sessions cleanly either way; these are only the fallbacks.
    private let activeTTL: TimeInterval = 90
    private let idleTTL: TimeInterval = 60 * 60
    /// A session blocked on a permission prompt is alive and will stay that way
    /// until you walk back to it, so it must outlive `activeTTL` — otherwise the
    /// pet stops asking for help 90s in, while the prompt is still on screen.
    private let waitingTTL: TimeInterval = 30 * 60
    private var sweepTimer: Timer?

    private func ttl(for state: String) -> TimeInterval {
        switch state {
        case "idle":    return idleTTL
        case "waiting": return waitingTTL
        default:        return activeTTL
        }
    }

    init() {
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.sweep()
        }
    }

    func apply(_ event: StateEvent) {
        if event.state == "gone" {
            sessions.removeValue(forKey: event.sessionID)
        } else {
            sessions[event.sessionID] = Session(
                state: event.state,
                host: event.host,
                remote: event.remote,
                tool: event.tool,
                seen: Date()
            )
        }
        onChange?()
    }

    private func sweep() {
        let now = Date()
        let before = sessions.count
        sessions = sessions.filter { _, session in
            now.timeIntervalSince(session.seen) < ttl(for: session.state)
        }
        if sessions.count != before { onChange?() }
    }

    /// Waiting outranks busy: a session blocked on you is the one thing you
    /// actually need to look up for.
    var mood: PetMood {
        if sessions.isEmpty { return .asleep }
        if sessions.values.contains(where: { $0.state == "waiting" }) { return .waiting }
        let busyStates: Set<String> = ["thinking", "working", "running"]
        if sessions.values.contains(where: { busyStates.contains($0.state) }) { return .busy }
        return .idle
    }

    var hasRemoteSession: Bool {
        sessions.values.contains { $0.remote }
    }

    /// Host initial for the remote badge, e.g. "d" for devbox.
    var remoteBadge: String? {
        guard let remote = sessions.values.first(where: { $0.remote }) else { return nil }
        return remote.host.first.map { String($0).uppercased() }
    }

    /// Short text for the thought bubble, or nil when the pet has nothing to
    /// say. Kept to a couple of words — it's a glance, not a status report.
    var caption: String? {
        switch mood {
        case .asleep, .idle:
            return nil
        case .waiting:
            return "needs you"
        case .busy:
            let busyStates: Set<String> = ["thinking", "working", "running"]
            let working = sessions.values
                .filter { busyStates.contains($0.state) }
                .sorted { $0.seen > $1.seen }

            guard let latest = working.first else { return "thinking" }
            return latest.tool.isEmpty ? "thinking" : latest.tool
        }
    }

    /// Human-readable lines for the right-click menu.
    var summaryLines: [String] {
        if sessions.isEmpty { return ["No active sessions"] }
        return sessions.values
            .sorted { $0.seen > $1.seen }
            .map { session in
                let where_ = session.remote ? "\(session.host) (ssh)" : "local"
                let detail = session.tool.isEmpty ? session.state : "\(session.state) · \(session.tool)"
                return "\(where_) — \(detail)"
            }
    }
}
