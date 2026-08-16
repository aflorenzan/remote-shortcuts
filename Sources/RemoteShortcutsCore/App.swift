import Dispatch
import Foundation

/// Assembles the server: middleware chain, routes, listener and shutdown.
public final class App: @unchecked Sendable {
    private let configuration: Configuration
    private let router: Router
    private let authenticator: TokenAuthenticator
    private let rateLimiter: RateLimiter
    private var server: HTTPServer?
    /// Held for the process lifetime; a released signal source stops firing.
    private var signalSources: [DispatchSourceSignal] = []

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.authenticator = TokenAuthenticator(token: configuration.token)
        self.rateLimiter = RateLimiter(limitPerMinute: configuration.rateLimitPerMinute)
        self.router = RouteBuilder(
            configuration: configuration,
            eventKit: EventKitService(),
            notes: NotesService(),
            shortcuts: ShortcutsService(
                allowList: configuration.allowedShortcuts,
                defaultTimeout: configuration.shortcutTimeoutSeconds
            )
        ).build()
    }

    public func run() throws {
        Log.shared.setLevel(configuration.logLevel)

        let server = HTTPServer(configuration: configuration) { [weak self] request in
            guard let self else { return .error(.internalError("Server is shutting down")) }
            return self.handle(request)
        }
        self.server = server
        try server.start()

        Log.info("remote-shortcuts \(BuildInfo.version) listening on http://\(configuration.host):\(configuration.port)")
        Log.info("Modules: \(configuration.modules.asJSON.filter { ($0.value as? Bool) == true }.keys.sorted().joined(separator: ", "))")
        if configuration.readOnly { Log.warn("Read-only mode: all mutating endpoints are disabled") }
        if configuration.bindsToNonLoopback {
            Log.warn("Bound to \(configuration.host) — reachable from the network. Ensure the token stays secret.")
        }

        installSignalHandlers()
        dispatchMain()
    }

    public func stop() {
        server?.stop()
        server = nil
    }

    // MARK: - Request pipeline

    /// The order here is the security model: cheap rejections first, so an
    /// unauthenticated caller never reaches EventKit or spawns a process.
    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let started = Date()
        var response: HTTPResponse

        do {
            try enforceSourceAddress(request)
            try enforceRateLimit(request)
            try enforceHostHeader(request)

            // Health is intentionally the one unauthenticated endpoint so a
            // monitor or `curl` can confirm the process is alive. It reveals
            // only the version and the current time.
            if request.path != "/v1/health" {
                try authenticator.authenticate(headers: request.headers)
            }

            response = try router.handle(request, readOnly: configuration.readOnly)
        } catch let error as APIError {
            response = .error(error)
        } catch let error as ConfigurationError {
            response = .error(.internalError(error.description))
        } catch {
            Log.error("Unhandled error on \(request.method) \(request.path): \(error)")
            response = .error(.internalError("The server hit an unexpected error handling this request"))
        }

        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let level: LogLevel = response.status.rawValue >= 500 ? .error
            : (response.status.rawValue >= 400 ? .warn : .info)
        let line = "\(request.method) \(request.path) → \(response.status.rawValue) (\(elapsed)ms) from \(request.remoteAddress)"
        switch level {
        case .error: Log.error(line)
        case .warn: Log.warn(line)
        default: Log.info(line)
        }

        return response
    }

    private func enforceSourceAddress(_ request: HTTPRequest) throws {
        let address = request.remoteAddress

        if configuration.loopbackOnly {
            guard CIDR.isLoopback(address) else {
                Log.warn("Rejected non-loopback request from \(address)")
                throw APIError.forbidden("This server only accepts connections from localhost.")
            }
            return
        }

        guard !configuration.allowedOrigins.isEmpty else { return }
        if CIDR.isLoopback(address) { return }
        guard configuration.allowedOrigins.contains(where: { $0.contains(address) }) else {
            Log.warn("Rejected request from \(address): not in allowed_origins")
            throw APIError.forbidden("Source address \(address) is not in 'allowed_origins'.")
        }
    }

    private func enforceRateLimit(_ request: HTTPRequest) throws {
        if let retryAfter = rateLimiter.consume(key: request.remoteAddress) {
            throw APIError.tooManyRequests("Rate limit of \(configuration.rateLimitPerMinute) requests/minute exceeded. Retry in \(retryAfter)s.")
        }
    }

    /// DNS-rebinding defence: a browser on the LAN can be pointed at this port
    /// via an attacker-controlled hostname, but it cannot forge the Host
    /// header. Only names that resolve to us are accepted.
    private func enforceHostHeader(_ request: HTTPRequest) throws {
        guard let host = request.headers["host"] else { return }
        let name = App.hostname(from: host)

        let permitted: Bool
        if name.isEmpty {
            permitted = false
        } else if CIDR.parseAddress(name) != nil {
            permitted = true
        } else {
            let lowered = name.lowercased()
            permitted = lowered == "localhost"
                || lowered.hasSuffix(".local")
                || lowered == configuration.host.lowercased()
                || lowered == ProcessInfo.processInfo.hostName.lowercased()
        }

        guard permitted else {
            throw APIError.forbidden("Unexpected Host header '\(name)'. Call the server by IP address or hostname.")
        }
    }

    /// Splits `host:port`, handling bracketed IPv6 literals.
    static func hostname(from header: String) -> String {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return "" }
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
        return String(trimmed.split(separator: ":").first ?? "")
    }

    // MARK: - Lifecycle

    private func installSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                Log.info("Shutting down")
                self?.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
