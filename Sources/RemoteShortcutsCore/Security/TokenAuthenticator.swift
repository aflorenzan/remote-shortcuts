import CryptoKit
import Foundation
import Security

/// Bearer-token authentication with constant-time comparison.
///
/// The naive `==` on Swift strings short-circuits on the first differing byte,
/// which leaks the token one character at a time to anyone who can measure
/// response latency. We compare fixed-size SHA-256 digests instead: equal
/// length regardless of input, and the OR-accumulator below never branches on
/// the data.
public struct TokenAuthenticator {
    private let expectedDigest: [UInt8]

    public init(token: String) {
        self.expectedDigest = Array(SHA256.hash(data: Data(token.utf8)))
    }

    /// Extracts and validates credentials from the request headers.
    /// Accepts `Authorization: Bearer <token>` and `X-API-Key: <token>`.
    /// Tokens are never accepted from the query string — those land in proxy
    /// logs and browser history.
    public func authenticate(headers: [String: String]) throws {
        guard let presented = Self.extractToken(from: headers) else {
            throw APIError.unauthorized("Missing credentials. Send 'Authorization: Bearer <token>' or 'X-API-Key: <token>'.")
        }
        guard verify(presented) else {
            throw APIError.unauthorized("Invalid token.")
        }
    }

    public func verify(_ presented: String) -> Bool {
        let presentedDigest = Array(SHA256.hash(data: Data(presented.utf8)))
        return Self.constantTimeEquals(presentedDigest, expectedDigest)
    }

    static func extractToken(from headers: [String: String]) -> String? {
        if let authorization = headers["authorization"] {
            let parts = authorization.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                let token = parts[1].trimmingCharacters(in: .whitespaces)
                return token.isEmpty ? nil : token
            }
            return nil
        }
        if let apiKey = headers["x-api-key"]?.trimmingCharacters(in: .whitespaces), !apiKey.isEmpty {
            return apiKey
        }
        return nil
    }

    static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

/// Cryptographically secure token generation, straight from the system CSPRNG.
public enum TokenGenerator {
    /// 32 bytes of entropy rendered as URL-safe base64 (43 characters).
    public static func generate(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "The system CSPRNG failed; refusing to generate a weak token.")
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
