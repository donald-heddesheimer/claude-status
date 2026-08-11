import XCTest
@testable import StatusPetCore

/// The listener is the only part of this app that a hostile process can reach,
/// so its refusals are the behaviour most worth pinning down.
final class StateServerTests: XCTestCase {

    private func request(method: String = "POST",
                         path: String = "/state",
                         headers: [String: String] = ["Content-Type": "application/json"],
                         body: String = #"{"state":"working"}"#) -> HTTPRequest {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "Content-Length: \(body.utf8.count)\r\n\r\n"
        return HTTPRequest(Data((head + body).utf8))!
    }

    private func rejection(_ verdict: Verdict) -> (status: Int, reason: String)? {
        guard case .reject(let status, let reason, _) = verdict else { return nil }
        return (status, reason)
    }

    // MARK: - Routing

    func testAcceptsAWellFormedPost() {
        guard case .accept(let event) = StateServer.judge(request(), token: nil) else {
            return XCTFail("a plain POST /state with JSON should be accepted")
        }
        XCTAssertEqual(event.state, "working")
    }

    func testRejectsNonPostMethods() {
        for method in ["GET", "PUT", "DELETE", "OPTIONS"] {
            let verdict = StateServer.judge(request(method: method), token: nil)
            XCTAssertEqual(rejection(verdict)?.status, 405, "\(method) should not be allowed")
        }
    }

    func testRejectsUnknownRoutes() {
        XCTAssertEqual(rejection(StateServer.judge(request(path: "/"), token: nil))?.status, 404)
        XCTAssertEqual(rejection(StateServer.judge(request(path: "/admin"), token: nil))?.status, 404)
    }

    func testIgnoresQueryStringOnTheRoute() {
        guard case .accept = StateServer.judge(request(path: "/state?t=1"), token: nil) else {
            return XCTFail("a harmless query string should not 404")
        }
    }

    // MARK: - Browser defence

    /// Loopback is reachable from any page the user visits. A form post with a
    /// text/plain body needs no CORS preflight, so the content-type check is
    /// what stops a web page inventing sessions on someone's desktop.
    func testRejectsBrowserOriginedRequests() {
        let verdict = StateServer.judge(
            request(headers: ["Content-Type": "application/json",
                              "Origin": "https://evil.example"]),
            token: nil)
        XCTAssertEqual(rejection(verdict)?.status, 403)
    }

    func testRejectsFormContentTypes() {
        for type in ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data"] {
            let verdict = StateServer.judge(request(headers: ["Content-Type": type]), token: nil)
            XCTAssertEqual(rejection(verdict)?.status, 415, "\(type) should be refused")
        }
    }

    func testAcceptsJSONContentTypeWithCharset() {
        guard case .accept = StateServer.judge(
            request(headers: ["Content-Type": "application/json; charset=utf-8"]), token: nil) else {
            return XCTFail("a charset parameter is legal on the JSON content type")
        }
    }

    // MARK: - Token

    func testRejectsMissingAndWrongTokens() {
        XCTAssertEqual(rejection(StateServer.judge(request(), token: "secret"))?.reason, "no token")

        let wrong = request(headers: ["Content-Type": "application/json",
                                      "X-Petdex-Update-Token": "nope"])
        XCTAssertEqual(rejection(StateServer.judge(wrong, token: "secret"))?.status, 401)
    }

    func testAcceptsEitherTokenHeaderName() {
        for header in ["X-Petdex-Update-Token", "X-Claude-Status-Token"] {
            let signed = request(headers: ["Content-Type": "application/json", header: "secret"])
            guard case .accept = StateServer.judge(signed, token: "secret") else {
                return XCTFail("\(header) should authenticate")
            }
        }
    }

    func testConstantTimeCompareStillCompares() {
        XCTAssertTrue(StateServer.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(StateServer.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(StateServer.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(StateServer.constantTimeEquals("", "a"))
    }

    // MARK: - Malformed input

    func testIncompleteRequestsParseAsNil() {
        XCTAssertNil(HTTPRequest(Data("POST /state HTTP/1.1\r\n".utf8)),
                     "headers not terminated yet — keep reading")
        XCTAssertNil(HTTPRequest(Data("POST /state HTTP/1.1\r\nContent-Length: 50\r\n\r\nshort".utf8)),
                     "body still arriving — keep reading")
        XCTAssertNil(HTTPRequest(Data("\r\n\r\n".utf8)), "no request line at all")
    }

    /// `Int("-1")` parses happily and `prefix(-1)` traps, so a negative length
    /// has to be rejected before it reaches the slice.
    func testNegativeContentLengthIsRefused() {
        XCTAssertNil(HTTPRequest(Data("POST /state HTTP/1.1\r\nContent-Length: -1\r\n\r\nxx".utf8)))
    }

    func testOversizedContentLengthIsRefused() {
        let raw = "POST /state HTTP/1.1\r\nContent-Length: \(HTTPRequest.maxBody + 1)\r\n\r\n"
        XCTAssertNil(HTTPRequest(Data(raw.utf8)))
    }

    func testNonJSONBodyIsRejected() {
        let verdict = StateServer.judge(request(body: "not json at all"), token: nil)
        XCTAssertEqual(rejection(verdict)?.status, 400)
    }

    func testJSONArrayBodyIsRejected() {
        XCTAssertNil(StateEvent.parse(Data("[1,2,3]".utf8)),
                     "a top-level array is valid JSON but not an event")
    }
}

/// Parsing is where attacker-controlled text becomes something the app draws on
/// screen and uses as a dictionary key.
final class StateEventParsingTests: XCTestCase {

    private func parse(_ json: String) -> StateEvent? {
        StateEvent.parse(Data(json.utf8))
    }

    func testFillsSensibleDefaults() {
        let event = parse("{}")
        XCTAssertEqual(event?.sessionID, "unknown")
        XCTAssertEqual(event?.state, "idle")
        XCTAssertEqual(event?.host, "local")
        XCTAssertEqual(event?.agentSource, "claude-code")
        XCTAssertEqual(event?.remote, false)
    }

    func testNormalisesStateAndAgentCase() {
        let event = parse(#"{"state":"WORKING","agent_source":"  Codex  "}"#)
        XCTAssertEqual(event?.state, "working")
        XCTAssertEqual(event?.agentSource, "codex")
    }

    /// A newline in a field would let a caller forge extra lines in the debug
    /// log, and the text renderer has no business seeing a bell character.
    func testStripsControlCharacters() {
        // Built with a real serialiser so the control characters under test
        // are unambiguously present, rather than depending on how this source
        // file is itself escaped.
        let body = try! JSONSerialization.data(withJSONObject: [
            "tool": "Bash",
            "detail": "one\ntwo\r\nthree\u{7}"
        ])
        let event = StateEvent.parse(body)
        XCTAssertEqual(event?.tool, "Bash")
        XCTAssertEqual(event?.detail, "onetwothree")
    }

    func testTruncatesOverlongFields() {
        let long = String(repeating: "x", count: 5_000)
        let event = parse(#"{"detail":"\#(long)","session_id":"\#(long)","cwd":"\#(long)"}"#)
        XCTAssertEqual(event?.detail.count, StateEvent.Limit.detail)
        XCTAssertEqual(event?.sessionID.count, StateEvent.Limit.sessionID)
        XCTAssertEqual(event?.cwd.count, StateEvent.Limit.cwd)
    }

    func testWronglyTypedFieldsFallBackRatherThanCrash() {
        let event = parse(#"{"state":42,"remote":"yes","tool":{"a":1},"session_id":[1]}"#)
        XCTAssertEqual(event?.state, "idle")
        XCTAssertEqual(event?.remote, false, "a string is not a bool; don't coerce it")
        XCTAssertEqual(event?.tool, "")
        XCTAssertEqual(event?.sessionID, "unknown")
    }

    func testBlankFieldsCollapseToDefaults() {
        let event = parse(#"{"state":"   ","host":"","agent_source":"  "}"#)
        XCTAssertEqual(event?.state, "idle")
        XCTAssertEqual(event?.host, "local")
        XCTAssertEqual(event?.agentSource, "claude-code")
    }
}
