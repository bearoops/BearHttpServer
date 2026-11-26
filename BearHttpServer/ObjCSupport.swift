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

    fileprivate var swiftConfiguration: HTTPServerConfiguration {
        HTTPServerConfiguration(
            host: host,
            port: UInt16(clamping: port),
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
/// The block must call its completion exactly once for each request.
public typealias ObjCHTTPRequestHandler = @convention(block)
    (ObjCHTTPRequest, @escaping ObjCHTTPResponseCompletion) -> Void

private final class ObjCHTTPRequestHandlerBox {
    let handler: ObjCHTTPRequestHandler

    init(_ handler: @escaping ObjCHTTPRequestHandler) {
        self.handler = handler
    }
}

/// An Objective-C-friendly wrapper around the Swift `HTTPServer` actor.
///
/// All asynchronous operations are exposed through blocks. Completion blocks
/// are invoked on the main queue.
@objc(BRHTTPServer)
public final class ObjCHTTPServer: NSObject {
    private let server: HTTPServer
    private let handlerBox: ObjCHTTPRequestHandlerBox

    @objc public init(
        configuration: ObjCHTTPServerConfiguration?,
        requestHandler: @escaping ObjCHTTPRequestHandler
    ) {
        let box = ObjCHTTPRequestHandlerBox(requestHandler)
        self.handlerBox = box
        self.server = HTTPServer(
            configuration: configuration?.swiftConfiguration ?? .localhost
        ) { request in
            let objcRequest = ObjCHTTPRequest(request)
            let handler = box.handler
            return try await withCheckedThrowingContinuation { continuation in
                handler(objcRequest) { response in
                    continuation.resume(returning: response.swiftResponse)
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
        let completion = completion
        Task { [weak self] in
            guard let self else { return }
            do {
                let port = try await self.server.start()
                Self.callOnMain { completion?(Int(port), nil) }
            } catch {
                Self.callOnMain { completion?(0, self.nsError(from: error)) }
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
        let completion = completion
        Task { [weak self] in
            await self?.server.stop()
            Self.callOnMain { completion?() }
        }
    }

    private func nsError(from error: Error) -> NSError {
        if let serverError = error as? HTTPServerError {
            let code: ObjCHTTPServerErrorCode
            switch serverError {
            case .alreadyRunning:
                code = .alreadyRunning
            case .listenerCancelled:
                code = .listenerCancelled
            case .listenerFailed:
                code = .listenerFailed
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
