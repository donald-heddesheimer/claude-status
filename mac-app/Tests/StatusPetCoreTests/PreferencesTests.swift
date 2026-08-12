import XCTest
@testable import StatusPetCore

final class PreferencesTests: XCTestCase {

    /// An in-memory store per test, so nothing here can touch the settings of a
    /// pet actually running on this machine — or leave a plist behind.
    private func scratch(_ environment: [String: String] = [:]) -> (Preferences, KeyValueStore) {
        let defaults = MemoryStore()
        // No legacy users file in the scratch environment, so migration is a
        // no-op unless a test asks for it.
        var environment = environment
        environment["CLAUDE_STATUS_USERS_FILE"] = "/nonexistent/claude-status/users"
        return (Preferences(defaults: defaults, environment: environment), defaults)
    }

    // MARK: - Account list parsing

    /// Regression: the users file ships with explanatory `#` lines at the top.
    /// Splitting the whole text on whitespace enrolled every word of them as an
    /// allowed account, which silently turned the filter off.
    func testCommentsDoNotBecomeAccounts() {
        let file = """
        # Accounts allowed to drive the pet. One per line.
        # Your own Mac account is always allowed.
        donald
        """
        XCTAssertEqual(Preferences.parseUsers(file), ["donald"])
    }

    func testStripsTrailingCommentsOnAValueLine() {
        XCTAssertEqual(Preferences.parseUsers("donald  # my laptop account"), ["donald"])
    }

    func testAcceptsCommasNewlinesAndSpaces() {
        XCTAssertEqual(Preferences.parseUsers("donald, ci\nbuild  deploy"),
                       ["donald", "ci", "build", "deploy"])
    }

    func testLowercasesAndDeduplicates() {
        XCTAssertEqual(Preferences.parseUsers("Donald, donald, DONALD"), ["donald"])
    }

    func testEmptyAndCommentOnlyInputYieldsNoAccounts() {
        XCTAssertTrue(Preferences.parseUsers("").isEmpty)
        XCTAssertTrue(Preferences.parseUsers("# nothing but a comment\n\n   ").isEmpty)
    }

    /// An empty list means "accept everyone" — the right default on a machine
    /// only you use. Getting this backwards would silence the pet completely.
    func testNoAccountsConfiguredAcceptsEveryone() {
        let (preferences, _) = scratch()
        let filter = UserFilter.from(preferences, localAccount: "donald")
        XCTAssertNil(filter.describe)
        XCTAssertTrue(filter.accepts(event(user: "someone-else", remote: true)))
    }

    // MARK: - Layering

    func testEnvironmentWinsOverStoredValue() {
        let (preferences, defaults) = scratch(["CLAUDE_STATUS_PORT": "9001"])
        defaults.set("7777", forKey: "port")

        XCTAssertEqual(preferences.port, 9001)
        XCTAssertEqual(preferences.override(Preferences.Keys.port), "9001",
                       "the window needs to know a field is overridden so it can say so")
    }

    func testStoredValueUsedWhenEnvironmentIsAbsent() {
        let (preferences, _) = scratch()
        XCTAssertEqual(preferences.port, 7777, "default")
        preferences.port = 8123
        XCTAssertEqual(preferences.port, 8123)
    }

    func testBlankEnvironmentValueIsNotAnOverride() {
        let (preferences, _) = scratch(["CLAUDE_STATUS_PORT": "   "])
        XCTAssertNil(preferences.override(Preferences.Keys.port))
        XCTAssertEqual(preferences.port, 7777)
    }

    func testRoundTripsAccountsThroughStorage() {
        let (preferences, _) = scratch()
        preferences.allowedUsers = ["donald", "ci"]
        XCTAssertEqual(preferences.allowedUsers, ["donald", "ci"])
    }

    // MARK: - Flags
    //
    // `UserDefaults.bool(forKey:)` reads an unset key and a key set to false
    // identically, so a flag that defaults to true has to go through
    // `object(forKey:)` first. Getting that wrong turns colour coding off for
    // everyone who has never opened Settings.

    func testColourCodingIsOnUntilYouTurnItOff() {
        let (preferences, _) = scratch()
        XCTAssertTrue(preferences.colorCodedBubbles, "unset means on")

        preferences.colorCodedBubbles = false
        XCTAssertFalse(preferences.colorCodedBubbles, "and off has to survive being stored")

        preferences.colorCodedBubbles = true
        XCTAssertTrue(preferences.colorCodedBubbles)
    }

    func testFollowingOneSessionIsOffUntilYouAskForIt() {
        let (preferences, _) = scratch()
        XCTAssertFalse(preferences.followOneSession)

        preferences.followOneSession = true
        XCTAssertTrue(preferences.followOneSession)
    }

    func testTheEnvironmentCanForceEitherFlag() {
        let (preferences, defaults) = scratch(["CLAUDE_STATUS_BUBBLE_COLORS": "0",
                                               "CLAUDE_STATUS_FOLLOW_ONE": "1"])
        defaults.set(true, forKey: "colorCodedBubbles")
        defaults.set(false, forKey: "followOneSession")

        XCTAssertFalse(preferences.colorCodedBubbles)
        XCTAssertTrue(preferences.followOneSession)
    }

    // MARK: - Migration

    func testMigratesTheLegacyUsersFileOnce() throws {
        let path = NSTemporaryDirectory() + "claude-status-users-\(UUID().uuidString)"
        try "# comment\ndonald\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = MemoryStore()
        let preferences = Preferences(defaults: defaults,
                                      environment: ["CLAUDE_STATUS_USERS_FILE": path])
        XCTAssertEqual(preferences.allowedUsers, ["donald"])

        // Editing in Settings must not be undone by the file on next launch.
        preferences.allowedUsers = ["ci"]
        let reopened = Preferences(defaults: defaults,
                                   environment: ["CLAUDE_STATUS_USERS_FILE": path])
        XCTAssertEqual(reopened.allowedUsers, ["ci"])
    }

    // MARK: -

    private func event(user: String, remote: Bool) -> StateEvent {
        StateEvent(sessionID: "s", state: "working", user: user, host: "h", remote: remote,
                   tool: "", detail: "", cwd: "", agentSource: "claude-code")
    }
}

final class UserFilterTests: XCTestCase {

    private func event(user: String, remote: Bool = false) -> StateEvent {
        StateEvent(sessionID: "s", state: "working", user: user, host: "h", remote: remote,
                   tool: "", detail: "", cwd: "", agentSource: "claude-code")
    }

    func testAlwaysAllowsYourOwnAccount() {
        // Filtering exists to keep other people's remote sessions out; silently
        // dropping your own local ones would be a nasty surprise.
        let filter = UserFilter(allowed: ["ci"])
        XCTAssertFalse(filter.accepts(event(user: "donald")),
                       "a bare filter has no notion of a local account")

        let preferences = Preferences(defaults: MemoryStore(),
                                      environment: ["CLAUDE_STATUS_USERS": "ci",
                                                    "CLAUDE_STATUS_USERS_FILE": "/nonexistent"])
        XCTAssertTrue(UserFilter.from(preferences, localAccount: "donald")
            .accepts(event(user: "donald")))
    }

    func testRejectsUnlistedAccountsWithAReason() {
        let filter = UserFilter(allowed: ["donald"])
        guard case .reject(let reason, let detail) = filter.decide(event(user: "srikant", remote: true)) else {
            return XCTFail("an unlisted account should be refused")
        }
        XCTAssertEqual(reason, "account not allowed")
        XCTAssertEqual(detail, "srikant")
    }

    func testCaseInsensitive() {
        XCTAssertTrue(UserFilter(allowed: ["donald"]).accepts(event(user: "Donald")))
    }

    /// Events with no account come from a plugin older than 0.1.3. A local one
    /// reached the port from a process on this Mac, so it is kept; a remote one
    /// came down a tunnel from a machine you may share, so it is not.
    func testUnstampedLocalEventsSurviveButRemoteOnesDoNot() {
        let filter = UserFilter(allowed: ["donald"])
        XCTAssertTrue(filter.accepts(event(user: "", remote: false)))
        XCTAssertFalse(filter.accepts(event(user: "", remote: true)))
    }
}
