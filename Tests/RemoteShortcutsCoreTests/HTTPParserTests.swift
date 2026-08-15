import XCTest
@testable import RemoteShortcutsCore

final class HTTPParserTests: XCTestCase {
    private func parser(maxBody: Int = 1024) -> HTTPParser {
        HTTPParser(maxBodyBytes: maxBody, remoteAddress: "127.0.0.1")
    }

    private func data(_ string: String) -> Data { Data(string.utf8) }

    func testParsesSimpleGET() throws {
        let raw = "GET /v1/health HTTP/1.1\r\nHost: localhost:8787\r\n\r\n"
        guard case let .complete(request, consumed) = try parser().parse(data(raw)) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/v1/health")
        XCTAssertEqual(request.headers["host"], "localhost:8787")
        XCTAssertTrue(request.keepAlive)
        XCTAssertEqual(consumed, raw.utf8.count)
    }

    func testParsesBodyWithContentLength() throws {
        let body = #"{"title":"Hola"}"#
        let raw = "POST /v1/notes HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case let .complete(request, _) = try parser().parse(data(raw)) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
        XCTAssertEqual(try request.jsonBody().string("title"), "Hola")
    }

    func testWaitsForIncompleteBody() throws {
        let raw = "POST /v1/notes HTTP/1.1\r\nContent-Length: 20\r\n\r\nshort"
        guard case .needMoreData = try parser().parse(data(raw)) else {
            return XCTFail("Expected to need more data")
        }
    }

    func testWaitsForIncompleteHeaders() throws {
        guard case .needMoreData = try parser().parse(data("GET /v1 HTTP/1.1\r\nHost: local")) else {
            return XCTFail("Expected to need more data")
        }
    }

    /// Chunked encoding plus Content-Length is the classic request-smuggling
    /// primitive; we refuse Transfer-Encoding outright.
    func testRejectsTransferEncoding() {
        let raw = "POST /v1/notes HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n"
        XCTAssertThrowsError(try parser().parse(data(raw))) { error in
            guard case .unsupported = error as? HTTPParser.ParseError else {
                return XCTFail("Expected .unsupported, got \(error)")
            }
        }
    }

    func testRejectsDuplicateContentLength() {
        let raw = "POST /v1/notes HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello"
        XCTAssertThrowsError(try parser().parse(data(raw))) { error in
            guard case .malformed = error as? HTTPParser.ParseError else {
                return XCTFail("Expected .malformed, got \(error)")
            }
        }
    }

    func testRejectsOversizedBody() {
        let raw = "POST /v1/notes HTTP/1.1\r\nContent-Length: 99999\r\n\r\n"
        XCTAssertThrowsError(try parser(maxBody: 64).parse(data(raw))) { error in
            guard case .tooLarge = error as? HTTPParser.ParseError else {
                return XCTFail("Expected .tooLarge, got \(error)")
            }
        }
    }

    func testRejectsHeaderFolding() {
        let raw = "GET /v1 HTTP/1.1\r\nX-Test: a\r\n  continued\r\n\r\n"
        XCTAssertThrowsError(try parser().parse(data(raw)))
    }

    func testRejectsPathTraversal() {
        let raw = "GET /v1/../../etc/passwd HTTP/1.1\r\n\r\n"
        XCTAssertThrowsError(try parser().parse(data(raw)))
    }

    func testRejectsEncodedPathTraversal() {
        let raw = "GET /v1/%2e%2e/%2e%2e/etc/passwd HTTP/1.1\r\n\r\n"
        XCTAssertThrowsError(try parser().parse(data(raw)))
    }

    func testParsesQueryString() throws {
        let raw = "GET /v1/calendars/events?start=2026-08-15&q=team+sync&limit=10 HTTP/1.1\r\n\r\n"
        guard case let .complete(request, _) = try parser().parse(data(raw)) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(request.query["start"], "2026-08-15")
        XCTAssertEqual(request.query["q"], "team sync")
        XCTAssertEqual(try request.queryInt("limit"), 10)
    }

    func testDecodesPercentEncodedPath() throws {
        let raw = "POST /v1/shortcuts/Daily%20Briefing/run HTTP/1.1\r\n\r\n"
        guard case let .complete(request, _) = try parser().parse(data(raw)) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(request.path, "/v1/shortcuts/Daily Briefing/run")
    }

    func testNormalisesTrailingAndDuplicateSlashes() {
        XCTAssertEqual(HTTPParser.normalisePath("/v1/notes/"), "/v1/notes")
        XCTAssertEqual(HTTPParser.normalisePath("//v1//notes//"), "/v1/notes")
        XCTAssertEqual(HTTPParser.normalisePath("/"), "/")
    }

    func testPipelinedRequestsAreConsumedOneAtATime() throws {
        let first = "GET /v1/health HTTP/1.1\r\n\r\n"
        let second = "GET /v1 HTTP/1.1\r\n\r\n"
        guard case let .complete(request, consumed) = try parser().parse(data(first + second)) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(request.path, "/v1/health")
        XCTAssertEqual(consumed, first.utf8.count)
    }

    func testHTTP10DefaultsToClose() throws {
        let raw = "GET /v1/health HTTP/1.0\r\n\r\n"
        guard case let .complete(request, _) = try parser().parse(data(raw)) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertFalse(request.keepAlive)
    }

    func testConnectionCloseIsHonoured() throws {
        let raw = "GET /v1/health HTTP/1.1\r\nConnection: close\r\n\r\n"
        guard case let .complete(request, _) = try parser().parse(data(raw)) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertFalse(request.keepAlive)
    }
}
