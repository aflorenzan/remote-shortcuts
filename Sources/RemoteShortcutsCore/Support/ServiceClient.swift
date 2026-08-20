import Foundation

/// Talks to a running server from the CLI.
///
/// `doctor` needs this because a CLI process cannot answer the question it is
/// asked. macOS attributes a privacy grant to the **responsible process**: for
/// a command run from a terminal, that is the terminal application. So reading
/// `EKEventStore.authorizationStatus` from the CLI reports whether *Terminal*
/// (or iTerm, or whatever) may read your calendars — which says nothing about
/// the LaunchAgent, and reported a confident "granted ✓" while the service was
/// returning 403 to every request.
///
/// The only process that can report the service's permissions is the service.
struct ServiceClient {
    let endpoint: URL
    let token: String

    enum ClientError: Error, CustomStringConvertible {
        case unreachable(String)
        /// The server accepted the connection and did not finish answering.
        /// It is running — a stopped one refuses the connection instead — so
        /// the remedy is never "start the service".
        case timedOut(String)
        /// The server answered and declined this address. A *running* service,
        /// which is the opposite of what the caller concludes from a bare
        /// failure — and concluding wrongly is what left an install with no way
        /// to grant permissions at all.
        case refusedOrigin(String)
        case http(status: Int, body: String)

        var description: String {
            switch self {
            case let .unreachable(detail): return detail
            case let .timedOut(detail): return detail
            case let .refusedOrigin(detail): return detail
            case let .http(status, body): return "HTTP \(status): \(body)"
            }
        }

        /// Did the server answer at all? A refusal is an answer.
        var serviceIsRunning: Bool {
            switch self {
            case .unreachable: return false
            case .timedOut, .refusedOrigin, .http: return true
            }
        }
    }

    static func fromConfiguration() -> ServiceClient? {
        guard let result = try? ConfigurationLoader.load() else { return nil }
        let configuration = result.configuration
        // A server bound to 0.0.0.0 is reachable on loopback.
        let host = configuration.host == "0.0.0.0" || configuration.host == "::"
            ? "127.0.0.1"
            : configuration.host
        guard let url = URL(string: "http://\(host):\(configuration.port)") else { return nil }
        return ServiceClient(endpoint: url, token: configuration.token)
    }

    func get(_ path: String, timeout: TimeInterval = 10) throws -> [String: Any] {
        try send(method: "GET", path: path, timeout: timeout)
    }

    /// Long enough to outlast the service's own worst case.
    ///
    /// `requestAllAccess` raises one prompt per entity, waiting up to 120s for
    /// each, so it can legitimately take 240s before answering. The client used
    /// to wait 180 — less than that — and so gave up on an install that was
    /// working, printing "could not reach the service" while the prompts were
    /// still on the screen waiting to be accepted. The client must never be the
    /// first to lose patience.
    static let permissionRequestTimeout: TimeInterval = 300

    func post(_ path: String, timeout: TimeInterval = ServiceClient.permissionRequestTimeout) throws -> [String: Any] {
        try send(method: "POST", path: path, timeout: timeout)
    }

    /// Joins base and path by hand.
    ///
    /// Not `appendingPathComponent`: that API inserts its own separator, so a
    /// path already starting with "/" can come out as "//v1/...". The router
    /// treats an empty leading segment as real — it has to, for note ids that
    /// contain "//" — so such a request would 404 for a reason nobody would
    /// enjoy tracking down.
    static func url(base: URL, path: String) -> URL? {
        var base = base.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        return URL(string: base + suffix)
    }

    private func send(method: String, path: String, timeout: TimeInterval) throws -> [String: Any] {
        guard let url = ServiceClient.url(base: endpoint, path: path) else {
            throw ClientError.unreachable("could not build a URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var response: URLResponse?
        var transportError: Error?

        // The CLI has no run loop of its own here, so the async call is bridged
        // back with a semaphore.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let task = URLSession(configuration: configuration).dataTask(with: request) {
            data = $0
            response = $1
            transportError = $2
            semaphore.signal()
        }
        task.resume()

        guard semaphore.wait(timeout: .now() + timeout + 5) == .success else {
            task.cancel()
            throw ClientError.timedOut("no reply within \(Int(timeout))s")
        }
        if let transportError {
            if (transportError as? URLError)?.code == .timedOut {
                throw ClientError.timedOut(transportError.localizedDescription)
            }
            throw ClientError.unreachable(transportError.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = data.flatMap { try? JSON.decodeObject($0) } ?? [:]
        guard (200..<300).contains(status) else {
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if status == 403, text.contains("allowed_origins") {
                throw ClientError.refusedOrigin(
                    "the service is running, but it refused this machine's address (allowed_origins)"
                )
            }
            throw ClientError.http(status: status, body: text)
        }
        return body
    }
}
