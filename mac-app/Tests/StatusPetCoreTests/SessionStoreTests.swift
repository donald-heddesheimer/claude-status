import XCTest
@testable import StatusPetCore

/// A clock the test moves by hand.
///
/// Expiry is defined purely in terms of elapsed time, and a test that sleeps for
/// 90 seconds to check a 90-second TTL is a test nobody runs.
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

final class SessionStoreTests: XCTestCase {
    private var clock = Clock()

    private func store() -> SessionStore {
        clock = Clock()
        // autoSweep off: a timer firing underneath an assertion is a flake.
        return SessionStore(now: { [clock] in clock.now }, autoSweep: false)
    }

    private func event(_ id: String, _ state: String, tool: String = "", detail: String = "",
                       cwd: String = "", remote: Bool = false,
                       host: String = "mac") -> StateEvent {
        StateEvent(sessionID: id, state: state, user: "donald", host: host, remote: remote,
                   tool: tool, detail: detail, cwd: cwd, agentSource: "claude-code")
    }

    // MARK: - Collapsing several sessions into one mood

    func testNoSessionsMeansAsleep() {
        XCTAssertEqual(store().mood, .asleep)
    }

    func testWaitingOutranksBusy() {
        // The session blocked on you is the one thing you need to look up for.
        let store = store()
        store.apply(event("a", "working", tool: "Edit"))
        store.apply(event("b", "waiting", tool: "Bash"))
        XCTAssertEqual(store.mood, .waiting)
        XCTAssertEqual(store.caption, "allow Bash?")
    }

    func testBusyOutranksIdle() {
        let store = store()
        store.apply(event("a", "idle"))
        store.apply(event("b", "working", tool: "Read", detail: "README.md"))
        XCTAssertEqual(store.mood, .busy)
        XCTAssertEqual(store.caption, "reading README.md")
    }

    func testAllIdleIsIdleAndSaysNothing() {
        let store = store()
        store.apply(event("a", "idle"))
        XCTAssertEqual(store.mood, .idle)
        XCTAssertNil(store.caption, "an idle pet has nothing worth saying")
    }

    func testEveryBusyStateCountsAsBusy() {
        for state in ["thinking", "working", "running"] {
            let store = store()
            store.apply(event("a", state))
            XCTAssertEqual(store.mood, .busy, "\(state) should read as busy")
        }
    }

    func testSessionEndRemovesTheSession() {
        let store = store()
        store.apply(event("a", "working"))
        store.apply(event("a", "gone"))
        XCTAssertEqual(store.mood, .asleep)
    }

    // MARK: - Captions

    func testCaptionNamesTheBlockingTool() {
        let store = store()
        store.apply(event("a", "waiting", tool: "Bash"))
        XCTAssertEqual(store.caption, "allow Bash?", "worth knowing before you get up")
    }

    func testCaptionWithoutAToolStillAsks() {
        let store = store()
        store.apply(event("a", "waiting"))
        XCTAssertEqual(store.caption, "needs you")
    }

    /// Notification carries no tool name, so the pet keeps the one from the
    /// preceding PreToolUse. That is what turns a vague "needs you" into
    /// "allow Bash?".
    func testToolIsCarriedForwardIntoTheBlockedState() {
        let store = store()
        store.apply(event("a", "working", tool: "Bash", detail: "Run the tests"))
        store.apply(event("a", "waiting"))
        XCTAssertEqual(store.caption, "allow Bash?")
    }

    func testPhrasesReadAsSentencesNotToolNames() {
        XCTAssertEqual(SessionStore.phrase(tool: "Read", detail: "README.md"), "reading README.md")
        XCTAssertEqual(SessionStore.phrase(tool: "Edit", detail: "App.swift"), "editing App.swift")
        XCTAssertEqual(SessionStore.phrase(tool: "Grep", detail: "TODO"), "searching TODO")
        XCTAssertEqual(SessionStore.phrase(tool: "WebFetch", detail: "example.com"),
                       "looking up example.com")
        // Bash and Task already arrive as a written description of the work.
        XCTAssertEqual(SessionStore.phrase(tool: "Bash", detail: "Run the tests"), "Run the tests")
        // Nothing to add: fall back to the bare tool name.
        XCTAssertEqual(SessionStore.phrase(tool: "Read", detail: ""), "read")
    }

    // MARK: - Pinning

    func testPinnedSessionDrivesTheMood() {
        let store = store()
        store.apply(event("local", "working", tool: "Edit", detail: "App.swift"))
        store.apply(event("remote", "waiting", tool: "Bash", remote: true, host: "devbox"))

        XCTAssertEqual(store.mood, .waiting, "unpinned, the blocked one wins")

        store.focus = "local"
        XCTAssertEqual(store.mood, .busy)
        XCTAssertEqual(store.caption, "editing App.swift")
    }

    /// Pinned, the pet reports idle, which the collapsed view stays silent
    /// about — you asked after that session specifically, so "nothing right
    /// now" is an answer.
    func testPinnedIdleSessionSaysIdle() {
        let store = store()
        store.apply(event("a", "working", tool: "Edit", detail: "App.swift"))
        store.focus = "a"
        store.apply(event("a", "idle"))

        XCTAssertEqual(store.caption, "idle",
                       "still claiming 'editing App.swift' would be a lie about live work")
    }

    func testPinReleasesWhenThatSessionEnds() {
        let store = store()
        store.apply(event("a", "working"))
        store.focus = "a"
        store.apply(event("a", "gone"))
        XCTAssertNil(store.focus, "don't strand the pet on something that no longer exists")
    }

    func testPinReleasesWhenThatSessionExpires() {
        let store = store()
        store.apply(event("a", "working"))
        store.focus = "a"
        clock.advance(120)
        store.sweep()
        XCTAssertNil(store.focus)
    }

    func testChoicesPutWhatNeedsYouFirst() {
        let store = store()
        store.apply(event("a", "working", cwd: "/src/alpha"))
        clock.advance(1)
        store.apply(event("b", "waiting", tool: "Bash", cwd: "/src/beta", remote: true, host: "devbox"))

        let choices = store.choices
        XCTAssertEqual(choices.count, 2)
        XCTAssertTrue(choices[0].label.contains("devbox"), "the blocked session sorts first")
        XCTAssertTrue(choices[0].label.contains("beta"))
    }

    // MARK: - Expiry
    //
    // How long a silent session is held depends on what it was doing, and the
    // three deadlines are deliberately very different.

    func testWorkingSessionsExpireQuickly() {
        // A working session going quiet means something broke — most likely a
        // dropped tunnel — so don't strand the pet mid-thought.
        let store = store()
        store.apply(event("a", "working"))

        clock.advance(89)
        store.sweep()
        XCTAssertEqual(store.mood, .busy, "still inside the 90s window")

        clock.advance(2)
        store.sweep()
        XCTAssertEqual(store.mood, .asleep)
    }

    func testIdleSessionsAreHeldForAnHour() {
        // An idle session going quiet is just you not typing.
        let store = store()
        store.apply(event("a", "idle"))

        clock.advance(30 * 60)
        store.sweep()
        XCTAssertEqual(store.mood, .idle, "half an hour of not typing is normal")

        clock.advance(31 * 60)
        store.sweep()
        XCTAssertEqual(store.mood, .asleep)
    }

    /// A session blocked on a permission prompt is alive and stays that way
    /// until you walk back to it, so it must outlive the working TTL —
    /// otherwise the pet stops asking for help 90s in, while the prompt is
    /// still on screen.
    func testWaitingSessionsOutliveWorkingOnes() {
        let store = store()
        store.apply(event("a", "waiting", tool: "Bash"))

        clock.advance(20 * 60)
        store.sweep()
        XCTAssertEqual(store.mood, .waiting, "still blocked on you after 20 minutes")

        clock.advance(11 * 60)
        store.sweep()
        XCTAssertEqual(store.mood, .asleep)
    }

    // MARK: - Ages

    /// Every PostToolUse ping would otherwise reset the clock, and "working 6m"
    /// could never read higher than a few seconds.
    func testRepeatedPingsInTheSameStateDoNotResetTheAge() {
        let store = store()
        store.apply(event("a", "working", tool: "Edit"))
        clock.advance(200)
        store.apply(event("a", "working", tool: "Read"))

        XCTAssertEqual(store.stats.rows.first?.age, "3m")
    }

    func testChangingStateRestartsTheAge() {
        let store = store()
        store.apply(event("a", "working"))
        clock.advance(200)
        store.apply(event("a", "waiting"))

        XCTAssertEqual(store.stats.rows.first?.age, "0s")
    }

    func testStatsHeadlineCountsWhatMatters() {
        let store = store()
        store.apply(event("a", "working"))
        store.apply(event("b", "waiting"))
        XCTAssertEqual(store.stats.headline, "2 sessions · 1 needs you")

        let quiet = self.store()
        quiet.apply(event("a", "idle"))
        XCTAssertEqual(quiet.stats.headline, "1 session · all idle")
    }

    // MARK: - Hostile input

    /// Session ids come off the wire, so the dictionary they key would grow for
    /// as long as someone cared to keep posting.
    func testSessionCountIsCapped() {
        let store = store()
        for index in 0..<500 {
            store.apply(event("session-\(index)", "working"))
            clock.advance(1)
        }
        XCTAssertEqual(store.sessions.count, 200)
        XCTAssertNotNil(store.sessions["session-499"], "the newest survive")
        XCTAssertNil(store.sessions["session-0"], "the oldest are evicted")
    }
}
