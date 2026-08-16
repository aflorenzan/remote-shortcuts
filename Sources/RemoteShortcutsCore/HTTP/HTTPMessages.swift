import Foundation

public enum HTTPStatus: Int {
    case ok = 200
    case created = 201
    case noContent = 204
    case badRequest = 400
    case unauthorized = 401
    case forbidden = 403
    case notFound = 404
    case methodNotAllowed = 405
    case requestTimeout = 408
    case lengthRequired = 411
    case payloadTooLarge = 413
    case uriTooLong = 414
    case unprocessableEntity = 422
    case tooManyRequests = 429
    case requestHeaderFieldsTooLarge = 431
    case internalServerError = 500
    case notImplemented = 501
    case badGateway = 502
    case serviceUnavailable = 503
    case gatewayTimeout = 504

    var reasonPhrase: String {
        switch self {
        case .ok: return "OK"
        case .created: return "Created"
        case .noContent: return "No Content"
        case .badRequest: return "Bad Request"
        case .unauthorized: return "Unauthorized"
        case .forbidden: return "Forbidden"
        case .notFound: return "Not Found"
        case .methodNotAllowed: return "Method Not Allowed"
        case .requestTimeout: return "Request Timeout"
        case .lengthRequired: return "Length Required"
        case .payloadTooLarge: return "Payload Too Large"
        case .uriTooLong: return "URI Too Long"
        case .unprocessableEntity: return "Unprocessable Entity"
        case .tooManyRequests: return "Too Many Requests"
        case .requestHeaderFieldsTooLarge: return "Request Header Fields Too Large"
        case .internalServerError: return "Internal Server Error"
        case .notImplemented: return "Not Implemented"
        case .badGateway: return "Bad Gateway"
        case .serviceUnavailable: return "Service Unavailable"
        case .gatewayTimeout: return "Gateway Timeout"
        }
    }
}

public struct HTTPRequest {
    public let method: String
    /// Path with percent-escapes already decoded, query string removed.
    public let path: String
    public let query: [String: String]
    /// Header names are lower-cased; repeated headers are joined with ", ".
    public let headers: [String: String]
    public let body: Data
    public let remoteAddress: String
    public let keepAlive: Bool
    /// Path parameters filled in by the router (e.g. `:id`).
    public var parameters: [String: String] = [:]

    public init(
        method: String,
        path: String,
        query: [String: String],
        headers: [String: String],
        body: Data,
        remoteAddress: String,
        keepAlive: Bool,
        parameters: [String: String] = [:]
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.remoteAddress = remoteAddress
        self.keepAlive = keepAlive
        self.parameters = parameters
    }

    public func jsonBody() throws -> JSONBody {
        guard !body.isEmpty else { return JSONBody([:]) }
        if let contentType = headers["content-type"],
           !contentType.lowercased().contains("application/json"),
           !contentType.lowercased().contains("text/json") {
            throw APIError.badRequest("Content-Type must be application/json")
        }
        do {
            return try JSONBody(data: body)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.badRequest("Request body is not valid JSON")
        }
    }

    public func parameter(_ name: String) throws -> String {
        guard let value = parameters[name], !value.isEmpty else {
            throw APIError.badRequest("Missing path parameter '\(name)'")
        }
        return value
    }

    public func queryInt(_ name: String) throws -> Int? {
        guard let raw = query[name] else { return nil }
        guard let value = Int(raw) else {
            throw APIError.badRequest("Query parameter '\(name)' must be a number")
        }
        return value
    }

    public func queryBool(_ name: String) throws -> Bool? {
        guard let raw = query[name]?.lowercased() else { return nil }
        switch raw {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: throw APIError.badRequest("Query parameter '\(name)' must be true or false")
        }
    }

    public func queryDate(_ name: String) throws -> Date? {
        guard let raw = query[name] else { return nil }
        guard let date = DateParsing.parse(raw) else {
            throw APIError.badRequest("Query parameter '\(name)' must be an ISO-8601 date")
        }
        return date
    }

    /// Comma-separated list, e.g. `?calendars=Work,Personal`.
    public func queryList(_ name: String) -> [String]? {
        guard let raw = query[name] else { return nil }
        let items = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }
}

public struct HTTPResponse {
    public var status: HTTPStatus
    public var headers: [String: String]
    public var body: Data

    public init(status: HTTPStatus = .ok, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Typed as a dictionary rather than `Any` so every call site's literal has
    /// a contextual type — otherwise each one warns that a heterogeneous
    /// literal could only be inferred as `[String: Any]`.
    public static func json(_ object: [String: Any], status: HTTPStatus = .ok) -> HTTPResponse {
        let data = (try? JSON.encode(object)) ?? Data(#"{"error":{"code":"internal_error","message":"Failed to encode response"}}"#.utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    public static func error(_ error: APIError) -> HTTPResponse {
        var payload: [String: Any] = ["code": error.code, "message": error.message]
        if let hint = error.hint { payload["hint"] = hint }
        return .json(["error": payload], status: error.status)
    }

    public static let noContent = HTTPResponse(status: .noContent)

    /// Serialises the response. Security headers are added here so every single
    /// response carries them, including error paths.
    func serialise(keepAlive: Bool) -> Data {
        var out = "HTTP/1.1 \(status.rawValue) \(status.reasonPhrase)\r\n"
        var finalHeaders = headers
        finalHeaders["Content-Length"] = String(body.count)
        finalHeaders["Connection"] = keepAlive ? "keep-alive" : "close"
        finalHeaders["X-Content-Type-Options"] = "nosniff"
        finalHeaders["Cache-Control"] = "no-store"
        // This API is for machine-to-machine calls; no browser should be able
        // to invoke it from a page the user happens to have open.
        finalHeaders["Content-Security-Policy"] = "default-src 'none'; frame-ancestors 'none'"
        finalHeaders["Referrer-Policy"] = "no-referrer"

        for (name, value) in finalHeaders.sorted(by: { $0.key < $1.key }) {
            out += "\(name): \(HTTPResponse.sanitiseHeaderValue(value))\r\n"
        }
        out += "\r\n"

        var data = Data(out.utf8)
        if status != .noContent { data.append(body) }
        return data
    }

    /// Strips CR/LF so no value can inject extra headers into the response.
    static func sanitiseHeaderValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }
}
