import Foundation
import Network

/// HTTP/1.1 server built directly on `Network.framework`.
///
/// Using Apple's networking stack rather than a third-party server keeps the
/// dependency count at zero and means TCP handling, IPv4/IPv6 and interface
/// binding are all handled by code that ships with the OS.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = (HTTPRequest) -> HTTPResponse

    private let configuration: Configuration
    private let handler: Handler
    private let listenerQueue = DispatchQueue(label: "com.remoteshortcuts.listener")
    private var listener: NWListener?
    private let stateLock = NSLock()
    /// Live connections, held strongly. Network.framework only keeps a weak
    /// path back to the handler through its callbacks, so without this the
    /// handler would be deallocated the moment `accept` returns and the socket
    /// would go silent.
    private var connections: [ObjectIdentifier: ConnectionHandler] = [:]

    /// Hard cap on simultaneous sockets. A local automation endpoint never
    /// needs more, and it bounds memory under a connection flood.
    private let maxConcurrentConnections = 64

    public init(configuration: Configuration, handler: @escaping Handler) {
        self.configuration = configuration
        self.handler = handler
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
            tcpOptions.connectionTimeout = 10
            tcpOptions.enableKeepalive = false
        }

        // Binding to a concrete address is what actually keeps the loopback
        // default honest — not a check later in the request path.
        if configuration.host != "0.0.0.0" && configuration.host != "::" {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(configuration.host),
                port: NWEndpoint.Port(rawValue: configuration.port) ?? .any
            )
        }

        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw ServerError.invalidPort(configuration.port)
        }

        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let readyGroup = DispatchGroup()
        readyGroup.enter()
        var startupError: Error?
        var signalled = false
        let signalOnce = { (error: Error?) in
            guard !signalled else { return }
            signalled = true
            startupError = error
            readyGroup.leave()
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.listenerQueue.async { signalOnce(nil) }
            case let .failed(error):
                self.listenerQueue.async { signalOnce(ServerError.listenFailed(error, port: self.configuration.port)) }
            case .cancelled:
                self.listenerQueue.async { signalOnce(ServerError.cancelled) }
            default:
                break
            }
        }

        listener.start(queue: listenerQueue)
        self.listener = listener

        if readyGroup.wait(timeout: .now() + 10) == .timedOut {
            listener.cancel()
            throw ServerError.startupTimeout
        }
        if let startupError { throw startupError }
    }

    public func stop() {
        listener?.cancel()
        listener = nil

        stateLock.lock()
        let open = Array(connections.values)
        connections.removeAll()
        stateLock.unlock()
        open.forEach { $0.shutDown() }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)

        stateLock.lock()
        let atCapacity = connections.count >= maxConcurrentConnections
        stateLock.unlock()

        if atCapacity {
            Log.warn("Refusing connection: \(maxConcurrentConnections) concurrent connections already open")
            connection.cancel()
            return
        }

        let handler = ConnectionHandler(
            connection: connection,
            configuration: configuration,
            requestHandler: self.handler,
            onClose: { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                self.connections.removeValue(forKey: identifier)
                self.stateLock.unlock()
            }
        )

        stateLock.lock()
        connections[identifier] = handler
        stateLock.unlock()

        // Each connection gets its own serial queue: Network.framework expects
        // a serial queue, and this keeps a slow request on one socket from
        // blocking the others while still ordering that socket's callbacks.
        handler.start()
    }

    public enum ServerError: Error, CustomStringConvertible {
        case invalidPort(UInt16)
        case listenFailed(NWError, port: UInt16)
        case startupTimeout
        case cancelled

        public var description: String {
            switch self {
            case let .invalidPort(port):
                return "Invalid port \(port)"
            case let .listenFailed(error, port):
                if case let .posix(code) = error, code == .EADDRINUSE {
                    return "Port \(port) is already in use. Stop the other process or set REMOTE_SHORTCUTS_PORT to a free port."
                }
                if case let .posix(code) = error, code == .EADDRNOTAVAIL {
                    return "Cannot bind to the configured host — this machine has no such address."
                }
                return "Failed to listen on port \(port): \(error.localizedDescription)"
            case .startupTimeout:
                return "The listener did not become ready within 10 seconds"
            case .cancelled:
                return "The listener was cancelled during startup"
            }
        }
    }
}

/// Owns one TCP connection: reads, parses, dispatches and writes, with an idle
/// timeout so a peer cannot pin a socket open indefinitely.
private final class ConnectionHandler: @unchecked Sendable {
    private let connection: NWConnection
    private let configuration: Configuration
    private let requestHandler: HTTPServer.Handler
    private let onClose: () -> Void

    private var buffer = Data()
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var timeoutSource: DispatchSourceTimer?
    private var closed = false
    private var requestsServed = 0
    private let maxRequestsPerConnection = 100

    init(
        connection: NWConnection,
        configuration: Configuration,
        requestHandler: @escaping HTTPServer.Handler,
        onClose: @escaping () -> Void
    ) {
        self.connection = connection
        self.configuration = configuration
        self.requestHandler = requestHandler
        self.onClose = onClose
        self.queue = DispatchQueue(label: "com.remoteshortcuts.connection.\(ObjectIdentifier(connection).hashValue)")
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        armTimeout()
        receive()
    }

    private var remoteAddress: String {
        switch connection.endpoint {
        case let .hostPort(host, _):
            switch host {
            case let .ipv4(address): return "\(address)".components(separatedBy: "%").first ?? "\(address)"
            case let .ipv6(address): return "\(address)".components(separatedBy: "%").first ?? "\(address)"
            case let .name(name, _): return name
            @unknown default: return "unknown"
            }
        default:
            return "unknown"
        }
    }

    private func armTimeout() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + configuration.requestTimeoutSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Log.debug("Closing idle connection from \(self.remoteAddress)")
            self.close()
        }
        timer.resume()
        lock.lock()
        timeoutSource?.cancel()
        timeoutSource = timer
        lock.unlock()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                Log.debug("Receive error: \(error.localizedDescription)")
                self.close()
                return
            }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.buffer.append(data)
                let bufferSize = self.buffer.count
                self.lock.unlock()

                let ceiling = self.configuration.maxBodyBytes + HTTPParser.maxHeaderBlockBytes + 4096
                if bufferSize > ceiling {
                    self.respond(.error(.payloadTooLarge("Request exceeds the configured size limit")), keepAlive: false)
                    return
                }
                self.drainBuffer()
            }
            if isComplete {
                self.close()
                return
            }
            if !self.isClosed { self.receive() }
        }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func drainBuffer() {
        let parser = HTTPParser(maxBodyBytes: configuration.maxBodyBytes, remoteAddress: remoteAddress)

        while true {
            lock.lock()
            let snapshot = buffer
            lock.unlock()
            if snapshot.isEmpty { return }

            do {
                switch try parser.parse(snapshot) {
                case .needMoreData:
                    return
                case let .complete(request, consumed):
                    lock.lock()
                    buffer = Data(buffer.dropFirst(consumed))
                    requestsServed += 1
                    let served = requestsServed
                    lock.unlock()

                    let response = requestHandler(request)
                    let keepAlive = request.keepAlive
                        && response.status != .payloadTooLarge
                        && served < maxRequestsPerConnection
                    respond(response, keepAlive: keepAlive)
                    if !keepAlive { return }
                }
            } catch let error as HTTPParser.ParseError {
                switch error {
                case let .malformed(message):
                    respond(.error(.badRequest(message)), keepAlive: false)
                case let .tooLarge(apiError):
                    respond(.error(apiError), keepAlive: false)
                case let .unsupported(message):
                    respond(HTTPResponse.json(
                        ["error": ["code": "not_implemented", "message": message]],
                        status: .notImplemented
                    ), keepAlive: false)
                }
                return
            } catch {
                respond(.error(.internalError("Failed to parse request")), keepAlive: false)
                return
            }
        }
    }

    private func respond(_ response: HTTPResponse, keepAlive: Bool) {
        let data = response.serialise(keepAlive: keepAlive)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                Log.debug("Send error: \(error.localizedDescription)")
                self.close()
                return
            }
            if keepAlive {
                self.armTimeout()
            } else {
                self.close()
            }
        })
    }

    /// Closes from the outside (server shutdown) without re-entering `onClose`
    /// while the server already holds its lock.
    func shutDown() {
        lock.lock()
        closed = true
        timeoutSource?.cancel()
        timeoutSource = nil
        lock.unlock()
        connection.cancel()
    }

    private func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        timeoutSource?.cancel()
        timeoutSource = nil
        lock.unlock()

        connection.cancel()
        onClose()
    }
}
