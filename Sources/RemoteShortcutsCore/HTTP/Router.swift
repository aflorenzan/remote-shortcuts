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

        /// A route whose last segment is a parameter captures everything left
        /// in the path, so `/v1/notes/:id` matches an id containing slashes —
        /// which every Apple Notes id does (`x-coredata://…/ICNote/p123`).
        var hasGreedyTail: Bool { segments.last?.hasPrefix(":") ?? false }
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
        let requestSegments = request.segments
        var pathMatched = false

        // Two passes: exact-arity matches first, greedy trailing-parameter
        // matches second. Without that ordering `/v1/reminders/:id` would
        // swallow `/v1/reminders/<id>/complete`, since a greedy `:id` happily
        // absorbs the trailing `complete`.
        for route in routes.filter({ !$0.hasGreedyTail }) + routes.filter({ $0.hasGreedyTail }) {
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
            // Rebuild from segments, not from the rendered path: round-tripping
            // through a string is exactly what this fix exists to avoid.
            let asGet = HTTPRequest(
                method: "GET",
                segments: request.segments,
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
        if route.hasGreedyTail {
            guard segments.count >= route.segments.count else { return nil }
        } else {
            guard route.segments.count == segments.count else { return nil }
        }

        var parameters: [String: String] = [:]
        for (index, pattern) in route.segments.enumerated() {
            let isLast = index == route.segments.count - 1

            if pattern.hasPrefix(":") {
                let name = String(pattern.dropFirst())
                if isLast {
                    // Rejoin the remainder with "/" so an id that contained
                    // slashes — or an empty segment, as `x-coredata://` does —
                    // comes back out exactly as the client sent it.
                    let tail = segments[index...].joined(separator: "/")
                    guard !tail.isEmpty else { return nil }
                    parameters[name] = tail
                } else {
                    parameters[name] = segments[index]
                }
            } else if pattern != segments[index] {
                return nil
            }
        }
        return parameters
    }
}
