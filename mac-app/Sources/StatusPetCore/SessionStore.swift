import AppKit

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
    /// Matches this session's thought bubble, which is the whole point of the
    /// panel: it is where you learn what the colour on screen means. Nil when
    /// there is nothing to tell apart.
    let color: NSColor?
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

    /// Ceiling on tracked sessions.
    ///
    /// The session id is attacker-chosen — anything that can reach loopback
    /// picks it — so without a cap this dictionary grows for as long as someone
    /// cares to keep posting. Nobody has 200 real sessions; past that the oldest
    /// is evicted, which keeps the pet honest about the ones you actually have.
    private static let maxSessions = 200

    private(set) var sessions: [String: Session] = [:]
    var onChange: (() -> Void)?

    /// Injectable clock. Expiry is the one behaviour here that is defined purely
    /// in terms of elapsed time, and a test that has to sleep for 90 seconds to
    /// check a 90-second TTL is a test nobody runs.
    private let now: () -> Date

    /// Whether the pet follows one session instead of collapsing all of them.
    ///
    /// Collapsing is the right default — you want the pet to surface whatever is
    /// blocked, wherever it is. But with four sessions running, the caption
    /// belongs to whichever one spoke last, and "what is *that* one doing" is
    /// otherwise only answerable from the hover panel. Single-session mode
    /// points the whole pet — mood, bubble, animation, celebration — at one.
    private(set) var followsOneSession = false

    /// The session being followed. Read-only: it moves through `follow` and
    /// `followOne` so the mode and the selection can never disagree.
    private(set) var focus: String?

    /// The followed session, if it still exists.
    private var focused: Session? {
        guard let focus else { return nil }
        return sessions[focus]
    }

    /// Follow one named session. Turns the mode on if it wasn't already, since
    /// naming a session is the clearest possible statement that you want one.
    func follow(_ id: String) {
        guard !followsOneSession || focus != id else { return }
        followsOneSession = true
        focus = id
        onChange?()
    }

    /// Turn single-session mode on or off, without naming a session — the pet
    /// adopts one itself.
    ///
    /// That is also what happens at every launch: session ids are minted afresh
    /// each time Claude Code starts, so an id saved yesterday names nothing
    /// today. What persists is the *mode*, and the pet picks up whatever turns
    /// up first.
    func followOne(_ on: Bool) {
        guard on != followsOneSession else { return }
        followsOneSession = on
        focus = nil
        reconcileFocus()
        onChange?()
    }

    /// Keeps single-session mode pointed at a session that exists.
    ///
    /// Called after anything that can remove sessions. When the followed one
    /// ends, the pet adopts the next rather than going blank — a mode you have
    /// to re-arm by hand every time a session ends is not a mode. Silent by
    /// design: every caller fires `onChange` once the whole mutation is done.
    private func reconcileFocus() {
        guard followsOneSession else {
            focus = nil
            return
        }
        if let focus, sessions[focus] != nil { return }
        focus = sorted.first?.key
    }

    // MARK: - Colour

    /// Whether sessions get distinct bubble colours. Off falls everything back
    /// to the ink the pet has always used.
    var colorCoding = true {
        didSet {
            guard colorCoding != oldValue else { return }
            onChange?()
        }
    }

    /// Palette slot per session, handed out on arrival and released when the
    /// session goes.
    ///
    /// Keyed to arrival rather than to position in any list, because every list
    /// here moves: the hover panel sorts whatever needs you to the top, so a
    /// colour taken from position would change the moment a session got
    /// blocked — which is exactly the moment you need it to hold still. The
    /// lowest free slot is reused, so the palette stays at the tight end of
    /// itself rather than drifting through all six over an afternoon.
    private var slots: [String: Int] = [:]

    private func assignSlot(to id: String) {
        guard slots[id] == nil else { return }
        let taken = Set(slots.values)
        var slot = 0
        while taken.contains(slot) { slot += 1 }
        slots[id] = slot
    }

    private func releaseSlots() {
        guard slots.count != sessions.count else { return }
        slots = slots.filter { sessions[$0.key] != nil }
    }

    /// A session's colour, or nil when there is nothing to tell apart.
    ///
    /// One session is always drawn in the default ink: colour answers "which of
    /// these is talking", and with one session there is no question to answer.
    func color(for id: String) -> NSColor? {
        guard colorCoding, sessions.count > 1, let slot = slots[id] else { return nil }
        return SessionPalette.color(slot: slot)
    }

    /// Pet lifetime and total traffic, for the hover panel's footer.
    private let startedAt: Date
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

    /// `autoSweep: false` leaves expiry entirely to `sweep()`, which is what a
    /// test wants — a timer firing underneath an assertion is a flake.
    init(now: @escaping () -> Date = Date.init, autoSweep: Bool = true) {
        self.now = now
        self.startedAt = now()
        guard autoSweep else { return }
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.sweep()
        }
    }

    func apply(_ event: StateEvent) {
        eventCount += 1

        if event.state == "gone" {
            sessions.removeValue(forKey: event.sessionID)
            releaseSlots()
            reconcileFocus()
        } else {
            let now = self.now()
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
            assignSlot(to: event.sessionID)
            evictOverflow()
            // A first session arriving is what arms single-session mode after a
            // launch, since the id it was following yesterday no longer exists.
            reconcileFocus()
        }
        onChange?()
    }

    /// Drops the least recently seen sessions once past the cap. Ordinary use
    /// never reaches this; a flood of invented session ids does.
    private func evictOverflow() {
        guard sessions.count > Self.maxSessions else { return }
        let doomed = sessions
            .sorted { $0.value.seen < $1.value.seen }
            .prefix(sessions.count - Self.maxSessions)
            .map(\.key)
        for key in doomed {
            sessions.removeValue(forKey: key)
        }
        releaseSlots()
    }

    func sweep() {
        let now = self.now()
        let before = sessions.count
        sessions = sessions.filter { _, session in
            now.timeIntervalSince(session.seen) < ttl(for: session.state)
        }
        guard sessions.count != before else { return }
        // Don't strand the pet on a session that no longer exists.
        releaseSlots()
        reconcileFocus()
        onChange?()
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

    /// What the bubble says, and which session is saying it.
    ///
    /// The two travel together because the colour is only meaningful attached to
    /// the words it came with — deriving the text in one place and the speaker
    /// in another is how a bubble ends up wearing the wrong session's colour.
    struct Thought {
        let text: String
        let sessionID: String
    }

    /// Short text for the thought bubble, or nil when the pet has nothing to
    /// say. Kept to a couple of words — it's a glance, not a status report.
    var thought: Thought? {
        // Following one: say what that session is doing, even when it's idle —
        // you asked about it specifically, so "nothing right now" is an answer.
        //
        // The carried-forward tool is only true while the session is working or
        // blocked. Once it goes idle the turn is over, and still reporting
        // "editing PetPack.swift" would be a stale claim about live work.
        if let focus, let focused {
            let text: String
            switch focused.state {
            case "waiting":
                text = focused.tool.isEmpty ? "needs you" : "allow \(focused.tool)?"
            case let state where Self.busyStates.contains(state):
                text = focused.tool.isEmpty
                    ? "thinking"
                    : Self.phrase(tool: focused.tool, detail: focused.detail)
            default:
                text = "idle"
            }
            return Thought(text: text, sessionID: focus)
        }

        // Picked off `sorted` rather than out of the dictionary, whose order is
        // arbitrary and unstable. With two sessions blocked at once that used to
        // be invisible — the two captions read the same — but it would now flip
        // the bubble's colour back and forth between them on every redraw.
        switch mood {
        case .asleep, .idle:
            return nil
        case .waiting:
            // Name the tool it's blocked on, so you know whether it's worth
            // getting up for before you get up.
            guard let blocked = sorted.first(where: { $0.value.state == "waiting" }) else {
                return nil
            }
            let tool = blocked.value.tool
            return Thought(text: tool.isEmpty ? "needs you" : "allow \(tool)?",
                           sessionID: blocked.key)
        case .busy:
            guard let latest = sorted.first(where: { Self.busyStates.contains($0.value.state) })
            else { return nil }
            let text = latest.value.tool.isEmpty
                ? "thinking"
                : Self.phrase(tool: latest.value.tool, detail: latest.value.detail)
            return Thought(text: text, sessionID: latest.key)
        }
    }

    var caption: String? { thought?.text }

    /// The bubble's fill, or nil for the default ink.
    var captionColor: NSColor? { thought.flatMap { color(for: $0.sessionID) } }

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

    /// Sessions for the right-click menu and the Settings picker, in the same
    /// order the hover panel uses so the three never disagree about which one is
    /// first.
    var choices: [SessionChoice] {
        sorted.map { id, session in
            let place = session.remote ? "\(session.host) (ssh)" : "local"
            let project = Self.projectName(session.cwd)
            let detail = session.tool.isEmpty
                ? session.state
                : "\(session.state) · \(Self.phrase(tool: session.tool, detail: session.detail))"
            return SessionChoice(
                id: id,
                label: project.isEmpty ? "\(place) — \(detail)" : "\(place) · \(project) — \(detail)",
                color: color(for: id),
                isFollowed: id == focus
            )
        }
    }

    /// Whatever needs you first, then most recently active.
    ///
    /// The final tiebreak on id is not decoration. Swift's sort is not stable,
    /// so two sessions seen in the same instant could otherwise swap places
    /// between one redraw and the next — and this order now decides which
    /// session the pet speaks for, and therefore what colour it speaks in.
    private var sorted: [(key: String, value: Session)] {
        sessions.sorted { a, b in
            if (a.value.state == "waiting") != (b.value.state == "waiting") {
                return a.value.state == "waiting"
            }
            if a.value.seen != b.value.seen { return a.value.seen > b.value.seen }
            return a.key < b.key
        }
    }

    // MARK: - Hover panel

    /// The full picture, for when a glance at the pet isn't enough.
    var stats: StatsReport {
        let now = self.now()

        // Following one session means the panel lists that one. Leaving the rest
        // in would make the mode a half-measure: the pet claims to be showing
        // you one session while its own panel shows you four.
        let listed = followsOneSession ? sorted.filter { $0.key == focus } : sorted

        let rows = listed.map { id, session -> SessionRow in
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
                isWaiting: session.state == "waiting",
                color: color(for: id)
            )
        }

        // The hidden count is the escape hatch: without it, a pet quietly
        // following one session looks identical to a pet that has lost the
        // other three.
        var footer = "up \(Self.duration(now.timeIntervalSince(startedAt))) · "
            + "\(eventCount) event\(eventCount == 1 ? "" : "s")"
        let hidden = sorted.count - listed.count
        if hidden > 0 { footer += " · \(hidden) hidden" }

        return StatsReport(headline: headline, rows: rows, footer: footer)
    }

    private var headline: String {
        if sessions.isEmpty { return "Nothing running" }

        let count = sessions.count
        if followsOneSession, count > 1 { return "Following 1 of \(count)" }
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
