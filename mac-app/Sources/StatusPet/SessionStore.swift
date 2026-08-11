import Foundation

/// What the pet should be doing, collapsed from every session it knows about.
enum PetMood {
    case asleep   // nothing connected
    case idle     // sessions alive, none busy
    case busy     // thinking or running tools
    case waiting  // needs you — permission prompt or input
}

/// One line of the hover panel: what a single session is doing.
struct SessionRow {
    let place: String    // "devbox (ssh)" or "local"
    let project: String  // last path component of the session's cwd
    let detail: String   // "working · Bash"
    let age: String      // time in the current state
    let isWaiting: Bool
}

/// Everything the hover panel shows.
struct StatsReport {
    let headline: String
    let rows: [SessionRow]
    let footer: String
}

/// Tracks every Claude Code session reporting in, local and remote alike, and
/// collapses them into a single mood for the pet.
final class SessionStore {
    struct Session {
        var state: String
        var host: String
        var remote: Bool
        var tool: String
        var detail: String
        var cwd: String
        var seen: Date        // last ping of any kind
        var firstSeen: Date   // when this session first reported
        var stateSince: Date  // when it entered the state it's in now
    }

    private static let busyStates: Set<String> = ["thinking", "working", "running"]

    private(set) var sessions: [String: Session] = [:]
    var onChange: (() -> Void)?

    /// Session the pet is pinned to, or nil for "whatever needs you most".
    ///
    /// Collapsing every session into one mood is the right default — you want
    /// the pet to surface the thing that's blocked. But with several running at
    /// once, the answer to "what is *that* one doing" is otherwise only in the
    /// hover panel. Pinning makes the pet itself follow a single session.
    var focus: String? {
        didSet {
            guard focus != oldValue else { return }
            onChange?()
        }
    }

    /// The pinned session, if it still exists.
    private var focused: Session? {
        guard let focus else { return nil }
        return sessions[focus]
    }

    /// Pet lifetime and total traffic, for the hover panel's footer.
    private let startedAt = Date()
    private(set) var eventCount = 0

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
        eventCount += 1

        if event.state == "gone" {
            sessions.removeValue(forKey: event.sessionID)
            if focus == event.sessionID { focus = nil }
        } else {
            let now = Date()
            let previous = sessions[event.sessionID]
            sessions[event.sessionID] = Session(
                state: event.state,
                host: event.host,
                remote: event.remote,
                // Notification and Stop carry no tool, but what the session was
                // last doing is exactly what you want to know when it stops to
                // ask permission. Carry it forward rather than blanking it.
                tool: event.tool.isEmpty ? (previous?.tool ?? "") : event.tool,
                detail: event.tool.isEmpty ? (previous?.detail ?? "") : event.detail,
                cwd: event.cwd.isEmpty ? (previous?.cwd ?? "") : event.cwd,
                seen: now,
                firstSeen: previous?.firstSeen ?? now,
                // Only restart the clock on a real transition. Otherwise every
                // PostToolUse ping would reset it and "working 6m" could never
                // read higher than a few seconds.
                stateSince: previous?.state == event.state ? (previous?.stateSince ?? now) : now
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
        // Don't strand the pet on a session that no longer exists.
        if let focus, sessions[focus] == nil { self.focus = nil }
        if sessions.count != before { onChange?() }
    }

    /// Waiting outranks busy: a session blocked on you is the one thing you
    /// actually need to look up for.
    var mood: PetMood {
        if let focused { return Self.mood(of: focused.state) }
        if sessions.isEmpty { return .asleep }
        if sessions.values.contains(where: { $0.state == "waiting" }) { return .waiting }
        if sessions.values.contains(where: { Self.busyStates.contains($0.state) }) { return .busy }
        return .idle
    }

    private static func mood(of state: String) -> PetMood {
        if state == "waiting" { return .waiting }
        if busyStates.contains(state) { return .busy }
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
        // Pinned: say what that one session is doing, even when it's idle —
        // you asked about it specifically, so "nothing right now" is an answer.
        //
        // The carried-forward tool is only true while the session is working or
        // blocked. Once it goes idle the turn is over, and still reporting
        // "editing PetPack.swift" would be a stale claim about live work.
        if let focused {
            switch focused.state {
            case "waiting":
                return focused.tool.isEmpty ? "needs you" : "allow \(focused.tool)?"
            case let state where Self.busyStates.contains(state):
                return focused.tool.isEmpty
                    ? "thinking"
                    : Self.phrase(tool: focused.tool, detail: focused.detail)
            default:
                return "idle"
            }
        }

        switch mood {
        case .asleep, .idle:
            return nil
        case .waiting:
            // Name the tool it's blocked on, so you know whether it's worth
            // getting up for before you get up.
            let blocked = sessions.values.first { $0.state == "waiting" }
            if let tool = blocked?.tool, !tool.isEmpty { return "allow \(tool)?" }
            return "needs you"
        case .busy:
            let working = sessions.values
                .filter { Self.busyStates.contains($0.state) }
                .sorted { $0.seen > $1.seen }

            guard let latest = working.first, !latest.tool.isEmpty else { return "thinking" }
            return Self.phrase(tool: latest.tool, detail: latest.detail)
        }
    }

    /// Turn a tool call into something worth reading. "Bash" and "Edit" are true
    /// of half the session; "editing SessionStore.swift" actually tells you
    /// where Claude is.
    static func phrase(tool: String, detail: String) -> String {
        guard !detail.isEmpty else { return tool.lowercased() }

        switch tool {
        case "Read":
            return "reading \(detail)"
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return "editing \(detail)"
        case "Grep", "Glob":
            return "searching \(detail)"
        case "WebFetch", "WebSearch":
            return "looking up \(detail)"
        case "Bash", "BashOutput", "Task", "Agent":
            // These already arrive as a written description of the work.
            return detail
        default:
            return "\(tool.lowercased()) \(detail)"
        }
    }

    /// Sessions for the right-click menu, in the same order the hover panel uses
    /// so the two never disagree about which one is first.
    struct Choice {
        let id: String
        let label: String
        let isFocused: Bool
    }

    var choices: [Choice] {
        sorted.map { id, session in
            let place = session.remote ? "\(session.host) (ssh)" : "local"
            let project = Self.projectName(session.cwd)
            let detail = session.tool.isEmpty
                ? session.state
                : "\(session.state) · \(Self.phrase(tool: session.tool, detail: session.detail))"
            return Choice(
                id: id,
                label: project.isEmpty ? "\(place) — \(detail)" : "\(place) · \(project) — \(detail)",
                isFocused: id == focus
            )
        }
    }

    /// Whatever needs you first, then most recently active.
    private var sorted: [(key: String, value: Session)] {
        sessions.sorted { a, b in
            if (a.value.state == "waiting") != (b.value.state == "waiting") {
                return a.value.state == "waiting"
            }
            return a.value.seen > b.value.seen
        }
    }

    // MARK: - Hover panel

    /// The full picture, for when a glance at the pet isn't enough.
    var stats: StatsReport {
        let now = Date()

        let rows = sorted.map { $0.value }
            .map { session -> SessionRow in
                var detail = session.state
                if session.state == "waiting" {
                    detail = session.tool.isEmpty
                        ? "waiting for you"
                        : "waiting · allow \(session.tool)?"
                } else if !session.tool.isEmpty, Self.busyStates.contains(session.state) {
                    detail = "\(session.state) · \(Self.phrase(tool: session.tool, detail: session.detail))"
                }
                return SessionRow(
                    place: session.remote ? "\(session.host) (ssh)" : "local",
                    project: Self.projectName(session.cwd),
                    detail: detail,
                    age: Self.duration(now.timeIntervalSince(session.stateSince)),
                    isWaiting: session.state == "waiting"
                )
            }

        return StatsReport(
            headline: headline,
            rows: rows,
            footer: "up \(Self.duration(now.timeIntervalSince(startedAt))) · "
                + "\(eventCount) event\(eventCount == 1 ? "" : "s")"
        )
    }

    private var headline: String {
        if sessions.isEmpty { return "Nothing running" }

        let count = sessions.count
        var parts = ["\(count) session\(count == 1 ? "" : "s")"]

        let waiting = sessions.values.filter { $0.state == "waiting" }.count
        let busy = sessions.values.filter { Self.busyStates.contains($0.state) }.count

        if waiting > 0 {
            parts.append("\(waiting) needs you")
        } else if busy > 0 {
            parts.append("\(busy) working")
        } else {
            parts.append("all idle")
        }
        return parts.joined(separator: " · ")
    }

    private static func projectName(_ cwd: String) -> String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return (trimmed as NSString).lastPathComponent
    }

    /// Coarse on purpose — the panel wants "4m", not "4m 12s".
    private static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
}
