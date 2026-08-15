import XCTest
@testable import RemoteShortcutsCore

final class RouterTests: XCTestCase {
    private func request(_ method: String, _ path: String) -> HTTPRequest {
        HTTPRequest(
            method: method,
            path: path,
            query: [:],
            headers: [:],
            body: Data(),
            remoteAddress: "127.0.0.1",
            keepAlive: true
        )
    }

    func testMatchesStaticRoute() throws {
        let router = Router()
        router.get("/v1/health") { _ in .json(["ok": true]) }
        let response = try router.handle(request("GET", "/v1/health"), readOnly: false)
        XCTAssertEqual(response.status, .ok)
    }

    func testExtractsPathParameters() throws {
        let router = Router()
        router.get("/v1/notes/:id") { request in
            .json(["id": try request.parameter("id")])
        }
        let response = try router.handle(request("GET", "/v1/notes/abc-123"), readOnly: false)
        let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertEqual(payload?["id"] as? String, "abc-123")
    }

    /// Static routes are registered before parameterised ones, so
    /// `/v1/notes/folders` must not be swallowed by `/v1/notes/:id`.
    func testStaticRouteWinsOverParameter() throws {
        let router = Router()
        router.get("/v1/notes/folders") { _ in .json(["kind": "folders"]) }
        router.get("/v1/notes/:id") { _ in .json(["kind": "note"]) }
        let response = try router.handle(request("GET", "/v1/notes/folders"), readOnly: false)
        let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertEqual(payload?["kind"] as? String, "folders")
    }

    func testUnknownRouteIsNotFound() {
        let router = Router()
        router.get("/v1/health") { _ in .json(["ok": true]) }
        XCTAssertThrowsError(try router.handle(request("GET", "/v1/nope"), readOnly: false)) { error in
            XCTAssertEqual((error as? APIError)?.status, .notFound)
        }
    }

    func testWrongMethodReturns405WithAllowHeader() throws {
        let router = Router()
        router.get("/v1/notes") { _ in .json(["ok": true]) }
        router.post("/v1/notes") { _ in .json(["ok": true]) }
        let response = try router.handle(request("DELETE", "/v1/notes"), readOnly: false)
        XCTAssertEqual(response.status, .methodNotAllowed)
        XCTAssertEqual(response.headers["Allow"], "GET, HEAD, POST")
    }

    func testReadOnlyModeBlocksMutations() {
        let router = Router()
        router.post("/v1/notes") { _ in .json(["ok": true]) }
        XCTAssertThrowsError(try router.handle(request("POST", "/v1/notes"), readOnly: true)) { error in
            XCTAssertEqual((error as? APIError)?.status, .forbidden)
        }
    }

    func testReadOnlyModeAllowsReads() throws {
        let router = Router()
        router.get("/v1/notes") { _ in .json(["ok": true]) }
        XCTAssertEqual(try router.handle(request("GET", "/v1/notes"), readOnly: true).status, .ok)
    }

    func testHEADReturnsHeadersWithoutBody() throws {
        let router = Router()
        router.get("/v1/health") { _ in .json(["ok": true]) }
        let response = try router.handle(request("HEAD", "/v1/health"), readOnly: false)
        XCTAssertEqual(response.status, .ok)
        XCTAssertTrue(response.body.isEmpty)
    }
}

final class DateParsingTests: XCTestCase {
    func testParsesISO8601WithZone() {
        let date = DateParsing.parse("2026-08-15T09:30:00Z")
        XCTAssertNotNil(date)
        XCTAssertEqual(DateParsing.format(date!), "2026-08-15T09:30:00.000Z")
    }

    func testParsesFractionalSeconds() {
        XCTAssertNotNil(DateParsing.parse("2026-08-15T09:30:00.123Z"))
    }

    func testParsesOffsetZone() {
        XCTAssertNotNil(DateParsing.parse("2026-08-15T09:30:00-04:00"))
    }

    /// A human writing an n8n expression usually omits the zone; that must be
    /// read as local time, not silently as UTC.
    func testParsesLocalDateTimeWithoutZone() {
        let date = DateParsing.parse("2026-08-15T09:30:00")
        XCTAssertNotNil(date)
        let components = Calendar.current.dateComponents([.hour, .minute], from: date!)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 30)
    }

    func testParsesDateOnly() {
        let date = DateParsing.parse("2026-08-15")
        XCTAssertNotNil(date)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 15)
    }

    func testRejectsGarbage() {
        XCTAssertNil(DateParsing.parse("next tuesday"))
        XCTAssertNil(DateParsing.parse(""))
    }
}

final class JSONBodyTests: XCTestCase {
    func testTypedAccessors() throws {
        let body = JSONBody([
            "title": "Reunión",
            "count": 3,
            "flag": true,
            "tags": ["a", "b"],
            "when": "2026-08-15T09:00:00Z",
            "nothing": NSNull(),
        ])
        XCTAssertEqual(try body.string("title"), "Reunión")
        XCTAssertEqual(try body.optionalInt("count"), 3)
        XCTAssertEqual(try body.optionalBool("flag"), true)
        XCTAssertEqual(try body.optionalStringArray("tags"), ["a", "b"])
        XCTAssertNotNil(try body.optionalDate("when"))
        XCTAssertNil(try body.optionalString("nothing"))
        XCTAssertNil(try body.optionalString("absent"))
    }

    func testMissingRequiredFieldReportsFieldName() {
        let body = JSONBody([:])
        XCTAssertThrowsError(try body.string("title")) { error in
            XCTAssertTrue("\(error)".contains("title"))
        }
    }

    func testWrongTypeIsRejected() {
        let body = JSONBody(["title": 42])
        XCTAssertThrowsError(try body.string("title"))
    }

    func testEmptyStringRejectedByNonEmpty() {
        let body = JSONBody(["title": "   "])
        XCTAssertThrowsError(try body.nonEmptyString("title"))
    }
}

final class NotesConversionTests: XCTestCase {
    func testEscapesHTML() {
        XCTAssertEqual(
            NotesService.escapeHTML("<script>alert('x')</script>"),
            "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"
        )
    }

    func testPlainTextBecomesDivPerLine() {
        XCTAssertEqual(
            NotesService.plainTextToHTML("line 1\nline 2"),
            "<div>line 1</div><div>line 2</div>"
        )
    }

    func testPlainTextIsEscaped() {
        XCTAssertEqual(NotesService.plainTextToHTML("a & b"), "<div>a &amp; b</div>")
    }

    func testPermissionErrorIsRecognised() {
        let error = NotesService.translate(stderr: "execution error: Not authorized to send Apple events to Notes. (-1743)", exitCode: 1)
        XCTAssertEqual(error.status, .forbidden)
        XCTAssertNotNil(error.hint)
    }

    func testNotFoundSentinelIsRecognised() {
        let error = NotesService.translate(stderr: "execution error: REMOTE_SHORTCUTS_NOT_FOUND (-1728)", exitCode: 1)
        XCTAssertEqual(error.status, .notFound)
    }
}

final class ShortcutsServiceTests: XCTestCase {
    func testAllowListIsInactiveWhenEmpty() {
        let service = ShortcutsService(allowList: [])
        XCTAssertTrue(service.isAllowed("Anything"))
        XCTAssertFalse(service.allowListActive)
    }

    func testAllowListRestrictsToNamedShortcuts() {
        let service = ShortcutsService(allowList: ["Daily Briefing"])
        XCTAssertTrue(service.isAllowed("Daily Briefing"))
        XCTAssertTrue(service.isAllowed("daily briefing"))
        XCTAssertFalse(service.isAllowed("Delete Everything"))
    }

    func testBlockedShortcutIsRejectedBeforeExecution() {
        let service = ShortcutsService(allowList: ["Safe"])
        XCTAssertThrowsError(try service.run(name: "Unsafe", input: nil, timeout: 1)) { error in
            XCTAssertEqual((error as? APIError)?.status, .forbidden)
        }
    }

    func testControlCharactersInNameAreRejected() {
        let service = ShortcutsService()
        XCTAssertThrowsError(try service.run(name: "bad\u{0}name", input: nil, timeout: 1))
    }

    func testDetectsJSONOutput() {
        XCTAssertTrue(ShortcutsService.looksLikeJSON(#"{"a":1}"#))
        XCTAssertTrue(ShortcutsService.looksLikeJSON("[1,2,3]"))
        XCTAssertFalse(ShortcutsService.looksLikeJSON("plain text"))
    }
}
