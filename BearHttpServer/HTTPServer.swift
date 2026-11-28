//
//  HTTPServer.swift
//  BearHttpServer
//

import Foundation
import Network

/// Per-connection gate used during graceful shutdown. It serializes the
/// decision between "an in-flight request is being handled" and "the
/// connection is idle", so `stop()` can cancel idle sockets immediately while
/// letting active requests finish.
actor ConnectionGate {
    private var isDraining = false
    private var inFlight = false

    /// Marks the start of request handling. Returns false when the connection
    /// is draining, in which case the request must not be processed.
    func beginRequest() -> Bool {
        guard !isDraining else { return false }
        inFlight = true
        return true
    }

    /// Marks the end of request handling. Returns true when the connection is
    /// draining and the session should stop instead of reading another request.
    func endRequest() -> Bool {
        inFlight = false
        return isDraining
    }

    /// Starts a graceful drain. Returns true when the connection is idle and
    /// the caller may cancel it immediately; false means a request is in
    /// flight and must be allowed to complete.
    func beginDrain() -> Bool {
        isDraining = true
        return !inFlight
    }
}

/// Bookkeeping for a single accepted connection.
private final class ConnectionContext: @unchecked Sendable {
    let connection: NWConnection
    let gate: ConnectionGate
    var task: Task<Void, Never>?

    init(connection: NWConnection, gate: ConnectionGate) {
        self.connection = connection
        self.gate = gate
    }
}

/// A small HTTP/1.1 server backed by Network.framework.
///
/// The server is an actor, so listener state, active connections and the
/// readiness continuation are serialized by Swift Concurrency instead of locks.
/// It binds to loopback by default and chooses a free port when the
/// configuration port is `0`.
public actor HTTPServer {
    /// Handles a request and returns its response.
    public typealias RequestHandler = @Sendable (HTTPRequest) async throws -> HTTPResponse
    /// Handles a request whose body is delivered incrementally via `stream`.
    public typealias StreamingRequestHandler = @Sendable (HTTPRequest, RequestBodyStream) async throws -> HTTPResponse

    private let configuration: HTTPServerConfiguration
    private let handler: RequestHandler
    private let streamingHandler: StreamingRequestHandler?
    private let queue = DispatchQueue(
        label: "com.bear.http.server",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var listener: NWListener?
    private var connections: [UUID: ConnectionContext] = [:]
    private var readyContinuation: CheckedContinuation<UInt16, Error>?

    public init(
        configuration: HTTPServerConfiguration = .localhost,
        handler: @escaping RequestHandler = { _ in HTTPResponse(status: .notFound) }
    ) {
        self.configuration = configuration
        self.handler = handler
        self.streamingHandler = nil
    }

    /// Creates a server whose handler reads the request body incrementally.
    /// Use this when requests may exceed `maxBodyBytes` as a whole but can be
    /// processed chunk by chunk.
    public init(
        configuration: HTTPServerConfiguration = .localhost,
        streamingHandler: @escaping StreamingRequestHandler
    ) {
        self.configuration = configuration
        self.handler = { _ in HTTPResponse(status: .notFound) }
        self.streamingHandler = streamingHandler
    }

    deinit {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        connections.values.forEach { $0.connection.cancel() }
    }

    /// Starts listening and returns the bound TCP port.
    @discardableResult
    public func start() async throws -> UInt16 {
        guard listener == nil else {
            throw HTTPServerError.alreadyRunning
        }

        let parameters: NWParameters
        if let tls = configuration.tls {
            let tlsOptions = NWProtocolTLS.Options()
            if let secIdentity = sec_identity_create(tls.identity) {
                sec_protocol_options_set_local_identity(
                    tlsOptions.securityProtocolOptions,
                    secIdentity
                )
            }
            parameters = NWParameters(tls: tlsOptions)
        } else {
            parameters = .tcp
        }
        // Intentionally do not set `allowLocalEndpointReuse`. Allowing reuse
        // lets another socket bind the same address/port, which can silently
        // steal connections. A bind conflict should fail loudly instead.
        let port = NWEndpoint.Port(rawValue: configuration.port) ?? .any
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: port
        )

        let newListener = try NWListener(using: parameters)
        listener = newListener

        // Weakly capture the listener as well as self: a strong capture here
        // would create a listener -> handler -> listener retain cycle that
        // survives a failed listener that never reaches stop().
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let newListener else { return }
            Task { await self?.handleListenerState(state, from: newListener) }
        }
        newListener.newConnectionHandler = { [weak self, weak newListener] connection in
            guard let newListener else { return }
            Task { await self?.accept(connection, from: newListener) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            newListener.start(queue: queue)
        }
    }

    /// Stops listening and gracefully closes active connections. Safe to call
    /// repeatedly.
    ///
    /// The listener is cancelled first so no new connections arrive. Idle
    /// connections are closed at once; connections with an in-flight request
    /// are allowed to finish, up to `gracefulShutdownTimeout` seconds. After
    /// the timeout any remaining connections are cancelled. Set the timeout to
    /// `0` to close all connections immediately.
    public func stop() async {
        let oldListener = listener
        listener = nil

        oldListener?.stateUpdateHandler = nil
        oldListener?.newConnectionHandler = nil
        oldListener?.cancel()

        readyContinuation?.resume(throwing: HTTPServerError.listenerCancelled)
        readyContinuation = nil

        let contexts = Array(connections.values)
        guard !contexts.isEmpty else { return }

        let timeout = configuration.gracefulShutdownTimeout
        guard timeout > 0 else {
            contexts.forEach { $0.connection.cancel() }
            connections.removeAll()
            return
        }

        // Ask each gate to drain. Idle sockets are cancelled immediately;
        // active requests are signalled to stop after the current response.
        var remaining = 0
        for context in contexts {
            if await context.gate.beginDrain() {
                context.connection.cancel()
            } else {
                remaining += 1
            }
        }
        guard remaining > 0 else {
            connections.removeAll()
            return
        }

        // The deadline force-cancels anything still alive when the grace
        // period expires. If all requests drain first, we cancel this task and
        // it returns early because `Task.sleep` throws on cancellation.
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.forceCancel(contexts)
        }

        await withTaskGroup(of: Void.self) { group in
            for context in contexts {
                if let task = context.task {
                    group.addTask { await task.value }
                }
            }
            await group.waitForAll()
        }
        deadline.cancel()

        // Still cancel leftovers defensively: a connection with no captured
        // task, or one whose session ignored cancellation, must not survive.
        forceCancel(contexts)
        connections.removeAll()
    }

    private func forceCancel(_ contexts: [ConnectionContext]) {
        for context in contexts {
            context.connection.cancel()
        }
    }

    private func handleListenerState(_ state: NWListener.State, from listener: NWListener) {
        guard self.listener === listener else { return }

        switch state {
        case .ready:
            let port = listener.port?.rawValue ?? 0
            readyContinuation?.resume(returning: port)
            readyContinuation = nil

        case .failed(let error):
            self.listener = nil
            readyContinuation?.resume(
                throwing: HTTPServerError.listenerFailed(error.localizedDescription)
            )
            readyContinuation = nil

        case .cancelled:
            self.listener = nil
            readyContinuation?.resume(throwing: HTTPServerError.listenerCancelled)
            readyContinuation = nil

        default:
            break
        }
    }

    private func accept(_ connection: NWConnection, from listener: NWListener) async {
        guard self.listener === listener else {
            connection.cancel()
            return
        }

        guard connections.count < configuration.maxConnections else {
            connection.cancel()
            return
        }

        let id = UUID()
        let gate = ConnectionGate()
        let context = ConnectionContext(connection: connection, gate: gate)
        connections[id] = context

        let configuration = self.configuration
        let handler = self.handler
        let streamingHandler = self.streamingHandler
        let connectionStreamHandler: HTTPConnection.StreamingRequestHandler? = {
            guard let streamingHandler else { return nil }
            return { request, body in
                do {
                    return try await streamingHandler(request, body)
                } catch {
                    return HTTPResponse.text(
                        "Internal Server Error: \(error.localizedDescription)",
                        status: .internalServerError
                    )
                }
            }
        }()
        let session = HTTPConnection(
            connection: connection,
            configuration: configuration,
            gate: gate,
            handler: { request in
                do {
                    return try await handler(request)
                } catch {
                    return HTTPResponse.text(
                        "Internal Server Error: \(error.localizedDescription)",
                        status: .internalServerError
                    )
                }
            },
            streamingHandler: connectionStreamHandler
        )

        connection.start(queue: queue)

        let task = Task { [weak self] in
            await session.run()
            await self?.removeConnection(id)
        }
        context.task = task
    }

    private func removeConnection(_ id: UUID) {
        connections.removeValue(forKey: id)
    }
}
