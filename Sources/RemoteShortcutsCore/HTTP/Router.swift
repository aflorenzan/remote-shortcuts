import Foundation

/// Small path router with `:parameter` support.
public final class Router {
    public typealias Handler = (HTTPRequest) throws -> HTTPResponse

    private struct Route {
        let method: String
        let segments: [String]
        let handler: Handler
        /// Mutating routes are blocked when the server runs in read-only mode.
        let mutating: Bool
    }

    private var routes: [Route] = []

    public init() {}

    public func get(_ path: String, _ handler: @escaping Handler) {
        add(method: "GET", path: path, mutating: false, handler: handler)
    }

    public func post(_ path: String, mutating: Bool = true, _ handler: @escaping Handler) {
        add(method: "POST", path: path, mutating: mutating, handler: handler)
    }

    public func patch(_ path: String, _ handler: @escaping Handler) {
        add(method: "PATCH", path: path, mutating: true, handler: handler)
    }

    public func delete(_ path: String, _ handler: @escaping Handler) {
        add(method: "DELETE", path: path, mutating: true, handler: handler)
    }

    private func add(method: String, path: String, mutating: Bool, handler: @escaping Handler) {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        routes.append(Route(method: method, segments: segments, handler: handler, mutating: mutating))
    }

    public func handle(_ request: HTTPRequest, readOnly: Bool) throws -> HTTPResponse {
        let requestSegments = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var pathMatched = false

        for route in routes {
            guard let parameters = match(route: route, against: requestSegments) else { continue }
            pathMatched = true
            guard route.method == request.method else { continue }

            if readOnly && route.mutating {
                throw APIError.forbidden("This server runs in read-only mode; \(request.method) \(request.path) is disabled.")
            }

            var enriched = request
            enriched.parameters = parameters
            return try route.handler(enriched)
        }

        // HEAD is answered as a GET with the body stripped, which keeps health
        // probes and uptime monitors working.
        if request.method == "HEAD" {
            let asGet = HTTPRequest(
                method: "GET",
                path: request.path,
                query: request.query,
                headers: request.headers,
                body: request.body,
                remoteAddress: request.remoteAddress,
                keepAlive: request.keepAlive
            )
            var response = try handle(asGet, readOnly: readOnly)
            response.body = Data()
            return response
        }

        if pathMatched {
            let allowed = allowedMethods(for: requestSegments)
            var response = HTTPResponse.error(.methodNotAllowed("\(request.method) is not allowed on \(request.path)"))
            response.headers["Allow"] = allowed.joined(separator: ", ")
            return response
        }

        throw APIError.notFound("No route for \(request.method) \(request.path). See GET /v1 for the available endpoints.")
    }

    private func allowedMethods(for segments: [String]) -> [String] {
        var methods = routes.compactMap { match(route: $0, against: segments) != nil ? $0.method : nil }
        if methods.contains("GET") { methods.append("HEAD") }
        return Array(Set(methods)).sorted()
    }

    private func match(route: Route, against segments: [String]) -> [String: String]? {
        guard route.segments.count == segments.count else { return nil }
        var parameters: [String: String] = [:]
        for (pattern, actual) in zip(route.segments, segments) {
            if pattern.hasPrefix(":") {
                parameters[String(pattern.dropFirst())] = actual
            } else if pattern != actual {
                return nil
            }
        }
        return parameters
    }
}
