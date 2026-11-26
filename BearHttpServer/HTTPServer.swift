//
//  HTTPServer.swift
//  BearHttpServer
//

import Foundation
import Network

/// A small HTTP/1.1 server backed by Network.framework.
///
/// The server binds to loopback by default and chooses a free port when the
/// configuration port is `0`.
public final class HTTPServer: @unchecked Sendable {
    /// Handles a request and returns its response.
    public typealias RequestHandler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    private let configuration: HTTPServerConfiguration
    private let handler: RequestHandler
    private let queue = DispatchQueue(
        label: "com.bear.http.server",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    public init(
        configuration: HTTPServerConfiguration = .localhost,
        handler: @escaping RequestHandler = { _ in HTTPResponse(status: .notFound) }
    ) {
        self.configuration = configuration
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// Starts listening and returns the bound TCP port.
    @discardableResult
    public func start() async throws -> UInt16 {
        let listener = try withLock { () -> NWListener in
            guard self.listener == nil else {
                throw HTTPServerError.alreadyRunning
            }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let port = NWEndpoint.Port(rawValue: configuration.port) ?? .any
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(configuration.host),
                port: port
            )
            let listener = try NWListener(using: parameters)
            self.listener = listener
            return listener
        }

        do {
            return try await waitUntilReady(listener)
        } catch {
            listener.cancel()
            withLock {
                if self.listener === listener {
                    self.listener = nil
                }
            }
            throw error
        }
    }

    /// Stops listening and closes all active connections. Safe to call repeatedly.
    public func stop() {
        let (listener, connections) = withLock { () -> (NWListener?, [NWConnection]) in
            let listener = self.listener
            self.listener = nil
            let connections = Array(self.connections.values)
            self.connections.removeAll()
            return (listener, connections)
        }

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    private func waitUntilReady(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    box.resume(throwing: HTTPServerError.listenerFailed(error.localizedDescription))
                case .cancelled:
                    box.resume(throwing: HTTPServerError.listenerCancelled)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        withLock { self.connections[id] = connection }

        let session = HTTPConnectionSession(
            connection: connection,
            configuration: configuration
        ) { [weak self] request in
            guard let self else {
                return HTTPResponse(status: .serviceUnavailable)
            }
            do {
                return try await self.handler(request)
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
            self?.removeConnection(id)
        }
    }

    private func removeConnection(_ id: UUID) {
        withLock { _ = self.connections.removeValue(forKey: id) }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class ContinuationBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}
