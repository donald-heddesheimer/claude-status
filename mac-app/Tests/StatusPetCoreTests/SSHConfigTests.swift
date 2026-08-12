import XCTest
@testable import StatusPetCore

/// The wizard edits a file people care about, so what it reads and what it
/// writes both need to be exactly predictable.
final class SSHConfigTests: XCTestCase {

    private let sample = """
    # personal
    Host devbox
        HostName devbox.example.com
        User donald
        RemoteForward 7777 127.0.0.1:7777

    Host build-server
      HostName build.example.com
      User ci

    Host old-box
        RemoteForward 9999 127.0.0.1:9999
    """

    func testReadsAliasesHostnamesAndUsers() {
        let hosts = SSHConfig.parse(sample, port: 7777)
        XCTAssertEqual(hosts.map(\.alias), ["devbox", "build-server", "old-box"])
        XCTAssertEqual(hosts[0].hostName, "devbox.example.com")
        XCTAssertEqual(hosts[1].user, "ci")
    }

    func testDetectsForwardOnlyForTheMatchingPort() {
        let hosts = SSHConfig.parse(sample, port: 7777)
        XCTAssertTrue(hosts[0].hasForward, "devbox forwards 7777")
        XCTAssertFalse(hosts[1].hasForward)
        XCTAssertFalse(hosts[2].hasForward, "9999 is a different tunnel entirely")
    }

    func testHandlesEqualsAndTabSeparators() {
        let hosts = SSHConfig.parse("Host=devbox\n\tHostName\t=\tdevbox.example.com", port: 7777)
        XCTAssertEqual(hosts.first?.alias, "devbox")
        XCTAssertEqual(hosts.first?.hostName, "devbox.example.com")
    }

    func testIgnoresCommentsAndCasing() {
        let hosts = SSHConfig.parse("# Host commented\nHOST devbox\n  remoteforward 7777 127.0.0.1:7777",
                                    port: 7777)
        XCTAssertEqual(hosts.map(\.alias), ["devbox"])
        XCTAssertTrue(hosts[0].hasForward)
    }

    /// A wildcard block configures other hosts rather than being one you connect
    /// to, so it should never appear in a "pick your host" list — but a forward
    /// declared there really does cover everyone.
    func testWildcardBlocksConfigureButAreNotOffered() {
        let hosts = SSHConfig.parse("""
        Host *
            RemoteForward 7777 127.0.0.1:7777

        Host devbox
            HostName devbox.example.com
        """, port: 7777)

        XCTAssertEqual(hosts.map(\.alias), ["devbox"])
        XCTAssertTrue(hosts[0].hasForward, "the wildcard forward already covers devbox")
    }

    func testForwardBeforeAnyHostLineIsGlobal() {
        let hosts = SSHConfig.parse("RemoteForward 7777 127.0.0.1:7777\n\nHost devbox\n", port: 7777)
        XCTAssertTrue(hosts[0].hasForward)
    }

    // MARK: - Writing

    func testAddsForwardInsideAnExistingBlock() {
        let updated = SSHConfig.adding(alias: "build-server", port: 7777, to: sample)
        let lines = updated.components(separatedBy: "\n")
        let hostIndex = lines.firstIndex(of: "Host build-server")!

        XCTAssertEqual(lines[hostIndex + 1], "    RemoteForward 7777 127.0.0.1:7777")
        XCTAssertTrue(SSHConfig.parse(updated, port: 7777)
            .first { $0.alias == "build-server" }!.hasForward)
    }

    func testAppendsANewBlockForAnUnknownAlias() {
        let updated = SSHConfig.adding(alias: "brand-new", port: 7777, to: sample)
        XCTAssertTrue(updated.contains("Host brand-new"))
        XCTAssertTrue(SSHConfig.parse(updated, port: 7777)
            .first { $0.alias == "brand-new" }!.hasForward)
    }

    func testAddingLeavesEveryOtherHostAlone() {
        let updated = SSHConfig.adding(alias: "build-server", port: 7777, to: sample)
        let before = SSHConfig.parse(sample, port: 7777)
        let after = SSHConfig.parse(updated, port: 7777)

        XCTAssertEqual(before.map(\.alias), after.map(\.alias))
        XCTAssertEqual(after.first { $0.alias == "old-box" }?.hasForward, false)
        XCTAssertTrue(updated.contains("# personal"), "comments survive the edit")
    }

    func testAddingToAnEmptyConfigProducesAUsableBlock() {
        let updated = SSHConfig.adding(alias: "devbox", port: 7777, to: "")
        let hosts = SSHConfig.parse(updated, port: 7777)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertTrue(hosts[0].hasForward)
    }

    func testUsesTheConfiguredPort() {
        let updated = SSHConfig.adding(alias: "devbox", port: 8123, to: "")
        XCTAssertTrue(updated.contains("RemoteForward 8123 127.0.0.1:8123"))
    }
}
