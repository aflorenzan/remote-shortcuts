import Foundation

/// Incremental HTTP/1.1 request parser.
///
/// Deliberately strict. It only supports what an automation client actually
/// sends, and rejects everything ambiguous:
///
/// * `Transfer-Encoding` in any form is refused (501). Chunked bodies plus
///   `Content-Length` are the classic request-smuggling primitive, and we have
///   no reason to support streaming uploads.
/// * A request carrying more than one `Content-Length` is refused.
/// * Request line, header block and body all have hard size caps, so a
///   malicious peer cannot make the process allocate without bound.
struct HTTPParser {
    enum ParseResult {
        case needMoreData
        case complete(HTTPRequest, consumedBytes: Int)
    }

    enum ParseError: Error {
        case malformed(String)
        case tooLarge(APIError)
        case unsupported(String)
    }

    static let maxRequestLineBytes = 8 * 1024
    static let maxHeaderBlockBytes = 32 * 1024
    static let maxHeaderCount = 100

    let maxBodyBytes: Int
    let remoteAddress: String

    func parse(_ buffer: Data) throws -> ParseResult {
        guard let headerEnd = HTTPParser.findHeaderTerminator(in: buffer) else {
            if buffer.count > HTTPParser.maxHeaderBlockBytes {
                throw ParseError.tooLarge(.payloadTooLarge("Header block exceeds \(HTTPParser.maxHeaderBlockBytes) bytes"))
            }
            return .needMoreData
        }

        let headerData = buffer.prefix(headerEnd)
        if headerData.count > HTTPParser.maxHeaderBlockBytes {
            throw ParseError.tooLarge(.payloadTooLarge("Header block exceeds \(HTTPParser.maxHeaderBlockBytes) bytes"))
        }

        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw ParseError.malformed("Headers are not valid UTF-8")
        }

        var lines = headerText.components(separatedBy: "\r\n")
        // Tolerate a leading blank line, which RFC 9112 allows clients to send.
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        guard let requestLine = lines.first else {
            throw ParseError.malformed("Empty request")
        }
        if requestLine.utf8.count > HTTPParser.maxRequestLineBytes {
            throw ParseError.tooLarge(.badRequest("Request line exceeds \(HTTPParser.maxRequestLineBytes) bytes"))
        }

        let (method, target, version) = try HTTPParser.parseRequestLine(requestLine)
        let headers = try HTTPParser.parseHeaders(Array(lines.dropFirst()))

        if headers["transfer-encoding"] != nil {
            throw ParseError.unsupported("Transfer-Encoding is not supported; send a request with Content-Length")
        }

        var contentLength = 0
        if let rawLength = headers["content-length"] {
            // A folded duplicate arrives as "12, 34" — reject it outright.
            guard !rawLength.contains(","), let parsed = Int(rawLength.trimmingCharacters(in: .whitespaces)), parsed >= 0 else {
                throw ParseError.malformed("Invalid Content-Length")
            }
            contentLength = parsed
        }

        if contentLength > maxBodyBytes {
            throw ParseError.tooLarge(.payloadTooLarge("Request body exceeds the \(maxBodyBytes) byte limit"))
        }

        let bodyStart = headerEnd + 4
        let totalNeeded = bodyStart + contentLength
        guard buffer.count >= totalNeeded else { return .needMoreData }

        let body = buffer.subdata(in: buffer.startIndex.advanced(by: bodyStart)..<buffer.startIndex.advanced(by: totalNeeded))
        let (segments, query) = try HTTPParser.splitTarget(target)

        let keepAlive = HTTPParser.resolveKeepAlive(version: version, connectionHeader: headers["connection"])

        let request = HTTPRequest(
            method: method,
            segments: segments,
            query: query,
            headers: headers,
            body: body,
            remoteAddress: remoteAddress,
            keepAlive: keepAlive
        )
        return .complete(request, consumedBytes: totalNeeded)
    }

    // MARK: - Pieces

    static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

    /// Finds the end of the header block.
    ///
    /// This runs on every `receive()`, before authentication, so its cost is
    /// something an anonymous client controls. `Data.range(of:)` searches in
    /// place; the hand-rolled loop it replaced copied the whole buffer and
    /// allocated a four-byte array per byte scanned, which made a body
    /// delivered in small chunks quadratic and trivially CPU-exhausting.
    ///
    /// No incremental scan offset is needed on top of that. Once the headers
    /// are complete the search stops at the terminator near the front of the
    /// buffer regardless of how much body has arrived behind it, and while the
    /// headers are still incomplete the scan is bounded by the 32 KB header cap
    /// enforced immediately below.
    static func findHeaderTerminator(in buffer: Data) -> Int? {
        guard buffer.count >= headerTerminator.count else { return nil }
        guard let found = buffer.range(of: headerTerminator) else { return nil }
        return buffer.distance(from: buffer.startIndex, to: found.lowerBound)
    }

    static func parseRequestLine(_ line: String) throws -> (method: String, target: String, version: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3 else {
            throw ParseError.malformed("Malformed request line")
        }
        let method = parts[0].uppercased()
        guard method.allSatisfy({ $0.isLetter }) else {
            throw ParseError.malformed("Malformed HTTP method")
        }
        guard parts[2].hasPrefix("HTTP/1.") else {
            throw ParseError.unsupported("Only HTTP/1.x is supported")
        }
        guard parts[1].utf8.count <= 4096 else {
            throw ParseError.tooLarge(.badRequest("Request URI is too long"))
        }
        return (method, parts[1], parts[2])
    }

    static func parseHeaders(_ lines: [String]) throws -> [String: String] {
        var headers: [String: String] = [:]
        var count = 0
        for line in lines where !line.isEmpty {
            count += 1
            guard count <= maxHeaderCount else {
                throw ParseError.tooLarge(.badRequest("Too many headers"))
            }
            // Obsolete line folding: a header continuation line. Reject rather
            // than guess, since parsers disagree on how to reassemble it.
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                throw ParseError.malformed("Obsolete header line folding is not supported")
            }
            guard let separator = line.firstIndex(of: ":") else {
                throw ParseError.malformed("Malformed header line")
            }
            let name = String(line[line.startIndex..<separator]).lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
                throw ParseError.malformed("Malformed header name")
            }
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        return headers
    }

    static func splitTarget(_ target: String) throws -> (segments: [String], query: [String: String]) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts[0])
        guard rawPath.hasPrefix("/") else {
            throw ParseError.malformed("Request path must start with '/'")
        }

        let segments = try HTTPParser.pathSegments(of: rawPath)

        var query: [String: String] = [:]
        if parts.count == 2, !parts[1].isEmpty {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = HTTPParser.percentDecodePlus(String(kv[0]))
                guard !key.isEmpty else { continue }
                let value = kv.count == 2 ? HTTPParser.percentDecodePlus(String(kv[1])) : ""
                query[key] = value
            }
        }
        return (segments, query)
    }

    /// Splits the path into segments and decodes each one **separately**.
    ///
    /// Decoding the whole path first — which is what this used to do — turns a
    /// `%2F` inside a segment into a real separator, so a client has no way to
    /// put a slash in a path parameter. That made every Apple Notes id
    /// (`x-coredata://…/ICNote/p123`) unaddressable, since those ids are minted
    /// by this very API and contain both `//` and `/`.
    ///
    /// Empty segments are preserved, apart from the leading one produced by the
    /// opening `/` and a single trailing one from a trailing `/`. Preserving
    /// them is what lets the router rebuild `x-coredata://…` with its double
    /// slash intact; collapsing them silently yields `x-coredata:/…`, which
    /// looks routable and then fails deeper in.
    static func pathSegments(of rawPath: String) throws -> [String] {
        var raw = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        // Drop the empty piece before the leading slash.
        if raw.first == "" { raw.removeFirst() }
        // Drop one trailing empty piece so `/v1/notes/` routes like `/v1/notes`.
        if raw.count > 1, raw.last == "" { raw.removeLast() }
        if raw == [""] { return [] }

        var segments: [String] = []
        segments.reserveCapacity(raw.count)
        for piece in raw {
            guard let decoded = piece.removingPercentEncoding else {
                throw ParseError.malformed("Request path has invalid percent-encoding")
            }
            // Traversal is checked per segment, after decoding, so `%2e%2e`
            // cannot slip past by arriving encoded.
            guard decoded != ".." else {
                throw ParseError.malformed("Request path must not contain '..'")
            }
            if decoded == "." { continue }
            segments.append(decoded)
        }
        return segments
    }

    /// Query strings encode spaces as `+`, which `removingPercentEncoding`
    /// leaves alone.
    static func percentDecodePlus(_ raw: String) -> String {
        raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
    }

    /// Renders segments back into a path, for logs and error messages only.
    /// Routing works on the segments themselves — going back through a string
    /// is what lost the empty segment inside `x-coredata://…` in the first place.
    static func renderPath(_ segments: [String]) -> String {
        segments.isEmpty ? "/" : "/" + segments.joined(separator: "/")
    }

    static func resolveKeepAlive(version: String, connectionHeader: String?) -> Bool {
        let connection = connectionHeader?.lowercased() ?? ""
        if connection.contains("close") { return false }
        if version == "HTTP/1.0" { return connection.contains("keep-alive") }
        return true
    }
}
