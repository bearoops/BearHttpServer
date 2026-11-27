//
//  ObjCSupport.swift
//  BearHttpServer
//

import Foundation

/// Error codes returned by ``ObjCHTTPServer`` through `NSError`.
@objc(BRHTTPServerErrorCode)
public enum ObjCHTTPServerErrorCode: Int {
    case alreadyRunning = 1
    case listenerCancelled = 2
    case listenerFailed = 3
    case unknown = 4
    case invalidConfiguration = 5
}

/// Error domain used by ``ObjCHTTPServer``.
@objc(BRHTTPServerError)
public final class ObjCHTTPServerError: NSObject {
    @objc public static let domain = "BRHTTPServerErrorDomain"
}

/// An HTTP request exposed to Objective-C.
@objc(BRHTTPRequest)
public final class ObjCHTTPRequest: NSObject {
    @objc public let method: String
    @objc public let target: String
    @objc public let version: String
    @objc public let headers: [String: String]
    @objc public let body: Data

    init(_ request: HTTPRequest) {
        method = request.method.rawValue
        target = request.target
        version = request.version.rawValue
        headers = request.headers.all
        body = request.body
    }
}

/// An HTTP response that can be returned from an Objective-C request handler.
@objc(BRHTTPResponse)
public final class ObjCHTTPResponse: NSObject {
    @objc public let statusCode: Int
    @objc public let reasonPhrase: String
    @objc public let headers: [String: String]
    @objc public let body: Data

    @objc public init(statusCode: Int, headers: [String: String]?, body: Data?) {
        self.statusCode = statusCode
        self.reasonPhrase = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        self.headers = headers ?? [:]
        self.body = body ?? Data()
    }

    @objc(responseWithStatusCode:headers:body:)
    public static func response(
        statusCode: Int,
        headers: [String: String]?,
        body: Data?
    ) -> ObjCHTTPResponse {
        ObjCHTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }

    @objc(textResponseWithString:statusCode:)
    public static func text(_ string: String, statusCode: Int) -> ObjCHTTPResponse {
        ObjCHTTPResponse(
            statusCode: statusCode,
            headers: ["content-type": "text/plain; charset=utf-8"],
            body: Data(string.utf8)
        )
    }

    fileprivate var swiftResponse: HTTPResponse {
        HTTPResponse(
            status: HTTPStatusCode(code: statusCode, reasonPhrase: reasonPhrase),
            headers: HTTPHeaders(headers),
            body: body
        )
    }
}

/// Configuration exposed to Objective-C.
@objc(BRHTTPServerConfiguration)
public final class ObjCHTTPServerConfiguration: NSObject {
    @objc public var host: String
    @objc public var port: Int
    @objc public var maxHeaderBytes: Int
    @objc public var maxBodyBytes: Int
    @objc public var serverHeader: String?
    /// Maximum time to wait for an Objective-C handler to call its completion.
    /// Defaults to 30 seconds; a timed-out request receives HTTP 504.
    @objc public var handlerTimeout: TimeInterval

    @objc public init(
        host: String,
        port: Int,
        maxHeaderBytes: Int,
        maxBodyBytes: Int,
        serverHeader: String?
    ) {
        self.host = host
        self.port = port
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
        self.serverHeader = serverHeader
        self.handlerTimeout = 30
    }

    @objc public convenience init(
        host: String,
        port: Int,
        maxHeaderBytes: Int,
        maxBodyBytes: Int,
        serverHeader: String?,
        handlerTimeout: TimeInterval
    ) {
        self.init(
            host: host,
            port: port,
            maxHeaderBytes: maxHeaderBytes,
            maxBodyBytes: maxBodyBytes,
            serverHeader: serverHeader
        )
        self.handlerTimeout = handlerTimeout
    }

    @objc public override convenience init() {
        self.init(
            host: "127.0.0.1",
            port: 0,
            maxHeaderBytes: 64 * 1024,
            maxBodyBytes: 16 * 1024 * 1024,
            serverHeader: "BearHttpServer"
        )
    }

    /// Returns nil when `port` is outside the valid TCP range instead of
    /// silently clamping it, so the caller can report a configuration error.
    fileprivate var swiftConfiguration: HTTPServerConfiguration? {
        guard (0...Int(UInt16.max)).contains(port) else { return nil }
        return HTTPServerConfiguration(
            host: host,
            port: UInt16(port),
            maxHeaderBytes: maxHeaderBytes,
            maxBodyBytes: maxBodyBytes,
            serverHeader: serverHeader
        )
    }
}

/// Completion block used by ``ObjCHTTPServer`` request handlers.
public typealias ObjCHTTPResponseCompletion = @convention(block) (ObjCHTTPResponse) -> Void

/// Request handler block used by ``ObjCHTTPServer``.
///
/// The block should call its completion exactly once for each request. If it
/// never calls completion, the request is failed with HTTP 504 after
/// `handlerTimeout`; extra calls are ignored.
public typealias ObjCHTTPRequestHandler = @convention(block)
    (ObjCHTTPRequest, @escaping ObjCHTTPResponseCompletion) -> Void

private final class ObjCHTTPRequestHandlerBox: @unchecked Sendable {
    let handler: ObjCHTTPRequestHandler

    init(_ handler: @escaping ObjCHTTPRequestHandler) {
        self.handler = handler
    }
}

/// Carries a non-Sendable Objective-C completion block across a task boundary.
private final class SendableCompletionBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Resumes a request continuation exactly once.
///
/// An actor serializes the one-shot check, replacing the previous lock. The
/// timeout is owned by a detached task in the caller instead of by the actor:
/// an actor cannot capture `self` in an escaping task from its nonisolated
/// initializer under Swift 6. Whichever path reaches `complete` first wins.
private actor ObjCHTTPResponseOnce {
    private var continuation: CheckedContinuation<HTTPResponse, Error>?

    init(continuation: CheckedContinuation<HTTPResponse, Error>) {
        self.continuation = continuation
    }

    func complete(_ response: HTTPResponse) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: response)
    }
}

/// An Objective-C-friendly wrapper around the Swift `HTTPServer` actor.
///
/// All asynchronous operations are exposed through blocks. Completion blocks
/// are invoked on the main queue.
@objc(BRHTTPServer)
public final class ObjCHTTPServer: NSObject, @unchecked Sendable {
    private let server: HTTPServer
    private let handlerBox: ObjCHTTPRequestHandlerBox
    private let handlerTimeout: TimeInterval
    private let configurationError: NSError?

    @objc public init(
        configuration: ObjCHTTPServerConfiguration?,
        requestHandler: @escaping ObjCHTTPRequestHandler
    ) {
        let box = ObjCHTTPRequestHandlerBox(requestHandler)
        let timeout = configuration?.handlerTimeout ?? 30
        let swiftConfiguration: HTTPServerConfiguration
        if let configuration {
            if let valid = configuration.swiftConfiguration {
                swiftConfiguration = valid
                self.configurationError = nil
            } else {
                // Keep an inert server instance, but remember the error so
                // start() can report it instead of binding a clamped port.
                swiftConfiguration = .localhost
                self.configurationError = NSError(
                    domain: ObjCHTTPServerError.domain,
                    code: ObjCHTTPServerErrorCode.invalidConfiguration.rawValue,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Invalid port \(configuration.port); must be 0...65535."]
                )
            }
        } else {
            swiftConfiguration = .localhost
            self.configurationError = nil
        }
        self.handlerBox = box
        self.handlerTimeout = timeout
        self.server = HTTPServer(
            configuration: swiftConfiguration
        ) { request in
            let objcRequest = ObjCHTTPRequest(request)
            return try await withCheckedThrowingContinuation { continuation in
                let once = ObjCHTTPResponseOnce(continuation: continuation)

                // Own the timeout outside the actor. Cancellation must return
                // early: a cancelled `Task.sleep` throws, and falling through
                // would still fire the 504 after the handler already answered.
                let timeoutTask = Task.detached {
                    guard timeout > 0 else { return }
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    } catch {
                        return
                    }
                    await once.complete(
                        HTTPResponse.text("Request handler timed out.", status: .gatewayTimeout)
                    )
                }

                box.handler(objcRequest) { response in
                    // The Objective-C block is synchronous and non-Sendable;
                    // snapshot its fields into a Sendable value before hopping
                    // to the once actor.
                    let snapshot = response.swiftResponse
                    Task {
                        await once.complete(snapshot)
                        timeoutTask.cancel()
                    }
                }
            }
        }
        super.init()
    }

    @objc public convenience init(requestHandler: @escaping ObjCHTTPRequestHandler) {
        self.init(configuration: nil, requestHandler: requestHandler)
    }

    /// Starts listening. The completion receives the bound port, or an error.
    @objc(startWithCompletion:)
    public func start(completion: ((Int, NSError?) -> Void)?) {
        let completionBox = SendableCompletionBox(completion)
        Task { [weak self] in
            guard let self else {
                let error = NSError(
                    domain: ObjCHTTPServerError.domain,
                    code: ObjCHTTPServerErrorCode.listenerCancelled.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "The HTTP server was deallocated."]
                )
                Self.callOnMain { completionBox.value?(0, error) }
                return
            }
            if let configurationError = self.configurationError {
                Self.callOnMain { completionBox.value?(0, configurationError) }
                return
            }
            do {
                let port = try await self.server.start()
                Self.callOnMain { completionBox.value?(Int(port), nil) }
            } catch {
                Self.callOnMain { completionBox.value?(0, Self.nsError(from: error)) }
            }
        }
    }

    /// Stops listening and closes active connections without waiting.
    @objc public func stop() {
        Task { [weak self] in
            await self?.server.stop()
        }
    }

    /// Stops listening and calls `completion` when shutdown is complete.
    @objc(stopWithCompletion:)
    public func stop(completion: (() -> Void)?) {
        let completionBox = SendableCompletionBox(completion)
        Task { [weak self] in
            await self?.server.stop()
            Self.callOnMain { completionBox.value?() }
        }
    }

    private static func nsError(from error: Error) -> NSError {
        if let serverError = error as? HTTPServerError {
            let code: ObjCHTTPServerErrorCode
            switch serverError {
            case .alreadyRunning:
                code = .alreadyRunning
            case .listenerCancelled:
                code = .listenerCancelled
            case .listenerFailed:
                code = .listenerFailed
            case .invalidTLSIdentity:
                code = .invalidConfiguration
            }
            return NSError(
                domain: ObjCHTTPServerError.domain,
                code: code.rawValue,
                userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
            )
        }

        return NSError(
            domain: ObjCHTTPServerError.domain,
            code: ObjCHTTPServerErrorCode.unknown.rawValue,
            userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
        )
    }

    private static func callOnMain(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async { work() }
        }
    }
}
