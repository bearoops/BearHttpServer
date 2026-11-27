//
//  HTTPServer.swift
//  BearHttpServer
//

import Foundation
import Network

/// A small HTTP/1.1 server backed by Network.framework.
///
/// The server is an actor, so listener state, active connections and the
/// readiness continuation are serialized by Swift Concurrency instead of locks.
/// It binds to loopback by default and chooses a free port when the
/// configuration port is `0`.
public actor HTTPServer {
    /// Handles a request and returns its response.
    public typealias RequestHandler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    private let configuration: HTTPServerConfiguration
    private let handler: RequestHandler
    private let queue = DispatchQueue(
        label: "com.bear.http.server",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var readyContinuation: CheckedContinuation<UInt16, Error>?

    public init(
        configuration: HTTPServerConfiguration = .localhost,
        handler: @escaping RequestHandler = { _ in HTTPResponse(status: .notFound) }
    ) {
        self.configuration = configuration
        self.handler = handler
    }

    deinit {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        connections.values.forEach { $0.cancel() }
    }

    /// Starts listening and returns the bound TCP port.
    @discardableResult
    public func start() async throws -> UInt16 {
        guard listener == nil else {
            throw HTTPServerError.alreadyRunning
        }

        let parameters = NWParameters.tcp
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

    /// Stops listening and closes all active connections. Safe to call repeatedly.
    public func stop() {
        let oldListener = listener
        listener = nil

        let activeConnections = Array(connections.values)
        connections.removeAll()

        oldListener?.stateUpdateHandler = nil
        oldListener?.newConnectionHandler = nil
        oldListener?.cancel()
        activeConnections.forEach { $0.cancel() }

        readyContinuation?.resume(throwing: HTTPServerError.listenerCancelled)
        readyContinuation = nil
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
        connections[id] = connection

        let configuration = self.configuration
        let handler = self.handler
        let session = HTTPConnection(
            connection: connection,
            configuration: configuration
        ) { request in
            do {
                return try await handler(request)
            } catch {
                return HTTPResponse.text(
                    "Internal Server Error: \(error.localizedDescription)",
                    status: .internalServerError
                )
            }
        }

        connection.start(queue: queue)

        Task { [weak self] in
            await session.run()
            await self?.removeConnection(id)
        }
    }

    private func removeConnection(_ id: UUID) {
        connections.removeValue(forKey: id)
    }
}
