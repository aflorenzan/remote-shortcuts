import XCTest
@testable import RemoteShortcutsCore

final class TokenAuthenticatorTests: XCTestCase {
    private let token = "s3cret-token-value-1234567890"

    func testAcceptsBearerToken() throws {
        let auth = TokenAuthenticator(token: token)
        XCTAssertNoThrow(try auth.authenticate(headers: ["authorization": "Bearer \(token)"]))
    }

    func testBearerKeywordIsCaseInsensitive() throws {
        let auth = TokenAuthenticator(token: token)
        XCTAssertNoThrow(try auth.authenticate(headers: ["authorization": "bearer \(token)"]))
    }

    func testAcceptsAPIKeyHeader() throws {
        let auth = TokenAuthenticator(token: token)
        XCTAssertNoThrow(try auth.authenticate(headers: ["x-api-key": token]))
    }

    func testRejectsWrongToken() {
        let auth = TokenAuthenticator(token: token)
        XCTAssertThrowsError(try auth.authenticate(headers: ["authorization": "Bearer wrong"]))
    }

    func testRejectsMissingCredentials() {
        let auth = TokenAuthenticator(token: token)
        XCTAssertThrowsError(try auth.authenticate(headers: [:]))
    }

    func testRejectsPrefixOfToken() {
        let auth = TokenAuthenticator(token: token)
        XCTAssertFalse(auth.verify(String(token.dropLast())))
    }

    /// A token in the query string ends up in proxy logs and browser history,
    /// so it must never be accepted as credentials.
    func testDoesNotReadTokenFromQueryString() {
        XCTAssertNil(TokenAuthenticator.extractToken(from: [:]))
        XCTAssertNil(TokenAuthenticator.extractToken(from: ["authorization": "Basic abc"]))
    }

    func testConstantTimeComparison() {
        XCTAssertTrue(TokenAuthenticator.constantTimeEquals([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(TokenAuthenticator.constantTimeEquals([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(TokenAuthenticator.constantTimeEquals([1, 2, 3], [1, 2]))
    }

    func testGeneratedTokensAreStrongAndUnique() {
        let first = TokenGenerator.generate()
        let second = TokenGenerator.generate()
        XCTAssertNotEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.count, 43)
        XCTAssertFalse(first.contains("+"))
        XCTAssertFalse(first.contains("/"))
        XCTAssertFalse(first.contains("="))
    }
}

final class CIDRTests: XCTestCase {
    func testMatchesIPv4Host() {
        let cidr = CIDR("192.168.1.10")
        XCTAssertNotNil(cidr)
        XCTAssertTrue(cidr!.contains("192.168.1.10"))
        XCTAssertFalse(cidr!.contains("192.168.1.11"))
    }

    func testMatchesIPv4Range() {
        let cidr = CIDR("192.168.1.0/24")!
        XCTAssertTrue(cidr.contains("192.168.1.1"))
        XCTAssertTrue(cidr.contains("192.168.1.254"))
        XCTAssertFalse(cidr.contains("192.168.2.1"))
    }

    func testMatchesNonByteAlignedPrefix() {
        let cidr = CIDR("10.0.0.0/12")!
        XCTAssertTrue(cidr.contains("10.15.255.255"))
        XCTAssertFalse(cidr.contains("10.16.0.1"))
    }

    func testMatchesIPv6() {
        let cidr = CIDR("fd00::/8")!
        XCTAssertTrue(cidr.contains("fd00::1"))
        XCTAssertFalse(cidr.contains("2001:db8::1"))
    }

    /// A dual-stack listener reports IPv4 peers as `::ffff:a.b.c.d`; an
    /// allow-list written in plain IPv4 has to match those.
    func testHandlesIPv4MappedIPv6() {
        let cidr = CIDR("192.168.1.0/24")!
        XCTAssertTrue(cidr.contains("::ffff:192.168.1.7"))
    }

    func testStripsZoneIdentifier() {
        XCTAssertTrue(CIDR("fe80::/10")!.contains("fe80::1%en0"))
    }

    func testRejectsGarbage() {
        XCTAssertNil(CIDR("not-an-ip"))
        XCTAssertNil(CIDR("192.168.1.0/33"))
        XCTAssertNil(CIDR("999.1.1.1"))
    }

    func testLoopbackDetection() {
        XCTAssertTrue(CIDR.isLoopback("127.0.0.1"))
        XCTAssertTrue(CIDR.isLoopback("127.1.2.3"))
        XCTAssertTrue(CIDR.isLoopback("::1"))
        XCTAssertFalse(CIDR.isLoopback("192.168.1.4"))
    }
}

final class RateLimiterTests: XCTestCase {
    func testAllowsUpToTheLimit() {
        let limiter = RateLimiter(limitPerMinute: 3)
        let now = Date()
        XCTAssertNil(limiter.consume(key: "a", now: now))
        XCTAssertNil(limiter.consume(key: "a", now: now))
        XCTAssertNil(limiter.consume(key: "a", now: now))
        XCTAssertNotNil(limiter.consume(key: "a", now: now))
    }

    func testKeysAreIndependent() {
        let limiter = RateLimiter(limitPerMinute: 1)
        let now = Date()
        XCTAssertNil(limiter.consume(key: "a", now: now))
        XCTAssertNil(limiter.consume(key: "b", now: now))
        XCTAssertNotNil(limiter.consume(key: "a", now: now))
    }

    func testWindowSlides() {
        let limiter = RateLimiter(limitPerMinute: 1, interval: 60)
        let start = Date()
        XCTAssertNil(limiter.consume(key: "a", now: start))
        XCTAssertNotNil(limiter.consume(key: "a", now: start.addingTimeInterval(30)))
        XCTAssertNil(limiter.consume(key: "a", now: start.addingTimeInterval(61)))
    }

    func testZeroLimitDisablesLimiting() {
        let limiter = RateLimiter(limitPerMinute: 0)
        for _ in 0..<50 {
            XCTAssertNil(limiter.consume(key: "a"))
        }
    }
}

final class LogRedactionTests: XCTestCase {
    func testRedactsBearerTokens() {
        XCTAssertEqual(Log.redact("auth Bearer abc123 done"), "auth <redacted> done")
        XCTAssertEqual(Log.redact("?token=secret&x=1"), "?<redacted>&x=1")
    }

    func testLeavesOrdinaryTextAlone() {
        XCTAssertEqual(Log.redact("GET /v1/health → 200"), "GET /v1/health → 200")
    }
}

final class HeaderSanitisationTests: XCTestCase {
    /// A value carrying CRLF could otherwise inject headers or split the
    /// response.
    func testStripsCRLFFromHeaderValues() {
        XCTAssertEqual(
            HTTPResponse.sanitiseHeaderValue("value\r\nX-Injected: evil"),
            "valueX-Injected: evil"
        )
    }

    func testHostHeaderParsing() {
        XCTAssertEqual(App.hostname(from: "localhost:8787"), "localhost")
        XCTAssertEqual(App.hostname(from: "192.168.1.4:8787"), "192.168.1.4")
        XCTAssertEqual(App.hostname(from: "[::1]:8787"), "::1")
        XCTAssertEqual(App.hostname(from: "example.com"), "example.com")
    }
}
