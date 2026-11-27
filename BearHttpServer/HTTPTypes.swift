//
//  HTTPTypes.swift
//  BearHttpServer
//

import Foundation
import Security

/// TLS settings for ``HTTPServer``. Supply the server's certificate and
/// private key as a `SecIdentity`; the server then accepts HTTPS connections
/// via Network.framework's built-in TLS protocol.
///
/// `SecIdentity` itself is not `Sendable`, but it is immutable once created,
/// so wrapping it makes the configuration safe to pass into the server actor.
public struct HTTPServerTLSConfiguration: @unchecked Sendable {
    public let identity: SecIdentity

    public init(identity: SecIdentity) {
        self.identity = identity
    }

    /// Loads a server identity from a PKCS#12 bundle (`.p12` / `.pfx`).
    /// - Parameters:
    ///   - pkcs12: The raw PKCS#12 file contents.
    ///   - password: The bundle's import password.
    public init(pkcs12: Data, password: String) throws {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items)
        // Some PKCS#12 bundles (e.g. produced by OpenSSL 3) return a non-zero
        // status while still yielding a usable identity. Accept the bundle
        // whenever an identity can be extracted; only fail when it cannot.
        guard let imported = items as? [[String: Any]],
              let first = imported.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw HTTPServerError.invalidTLSIdentity(status)
        }
        // SecPKCS12Import returns a SecIdentity for the identity key.
        self.identity = identity as! SecIdentity
    }
}

/// Replaces CR/LF with spaces so untrusted values cannot break out of a single
/// HTTP field line. Applied at construction and again before serialization.
@inline(__always)
func sanitizedHTTPField(_ value: String) -> String {
    let scalars = value.unicodeScalars.map { scalar -> Unicode.Scalar in
        (scalar == "\r" || scalar == "\n") ? " " : scalar
    }
    return String(String.UnicodeScalarView(scalars))
}

/// A case-insensitive collection of HTTP header fields.
public struct HTTPHeaders: Sendable, ExpressibleByDictionaryLiteral {
    private var storage: [String: String]

    public init() {
        storage = [:]
    }

    public init(_ headers: [String: String]) {
        storage = [:]
        for (name, value) in headers {
            append(name, value: value)
        }
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        storage = [:]
        for (name, value) in elements {
            append(name, value: value)
        }
    }

    public subscript(name: String) -> String? {
        get { storage[sanitizedHTTPField(name).lowercased()] }
        set {
            let key = sanitizedHTTPField(name).lowercased()
            if let newValue {
                storage[key] = sanitizedHTTPField(newValue)
            } else {
                storage.removeValue(forKey: key)
            }
        }
    }

    /// All headers, keyed by lowercased field names.
    public var all: [String: String] { storage }

    mutating func append(_ name: String, value: String) {
        let key = sanitizedHTTPField(name).lowercased()
        let sanitizedValue = sanitizedHTTPField(value)
        guard let existing = storage[key] else {
            storage[key] = sanitizedValue
            return
        }

        // Set-Cookie cannot be folded into a comma-separated list.
        if key == "set-cookie" {
            storage[key] = existing + "\r\nSet-Cookie: " + sanitizedValue
        } else {
            storage[key] = existing + ", " + sanitizedValue
        }
    }
}

/// An HTTP request method.
public struct HTTPMethod: RawRepresentable, Hashable, Sendable,
    CustomStringConvertible, ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }

    public static let get = HTTPMethod(rawValue: "GET")
    public static let head = HTTPMethod(rawValue: "HEAD")
    public static let post = HTTPMethod(rawValue: "POST")
    public static let put = HTTPMethod(rawValue: "PUT")
    public static let patch = HTTPMethod(rawValue: "PATCH")
    public static let delete = HTTPMethod(rawValue: "DELETE")
    public static let options = HTTPMethod(rawValue: "OPTIONS")
}

/// The HTTP version used by a request.
public struct HTTPVersion: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static let http10 = HTTPVersion(rawValue: "HTTP/1.0")
    public static let http11 = HTTPVersion(rawValue: "HTTP/1.1")
}

/// A single HTTP request received by the server.
public struct HTTPRequest: Sendable {
    public let method: HTTPMethod
    public let target: String
    public let version: HTTPVersion
    public let headers: HTTPHeaders
    public let body: Data

    public init(
        method: HTTPMethod,
        target: String,
        version: HTTPVersion = .http11,
        headers: HTTPHeaders = HTTPHeaders(),
        body: Data = Data()
    ) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
        self.body = body
    }
}

/// An HTTP response status code and its canonical reason phrase.
public struct HTTPStatusCode: Hashable, Sendable, CustomStringConvertible {
    public let code: Int
    public let reasonPhrase: String

    public init(code: Int, reasonPhrase: String) {
        self.code = code
        self.reasonPhrase = sanitizedHTTPField(reasonPhrase)
    }

    public var description: String { "\(code) \(reasonPhrase)" }

    public static let ok = HTTPStatusCode(code: 200, reasonPhrase: "OK")
    public static let created = HTTPStatusCode(code: 201, reasonPhrase: "Created")
    public static let noContent = HTTPStatusCode(code: 204, reasonPhrase: "No Content")
    public static let badRequest = HTTPStatusCode(code: 400, reasonPhrase: "Bad Request")
    public static let notFound = HTTPStatusCode(code: 404, reasonPhrase: "Not Found")
    public static let methodNotAllowed = HTTPStatusCode(code: 405, reasonPhrase: "Method Not Allowed")
    public static let payloadTooLarge = HTTPStatusCode(code: 413, reasonPhrase: "Payload Too Large")
    public static let requestHeaderFieldsTooLarge = HTTPStatusCode(
        code: 431,
        reasonPhrase: "Request Header Fields Too Large"
    )
    public static let internalServerError = HTTPStatusCode(code: 500, reasonPhrase: "Internal Server Error")
    public static let notImplemented = HTTPStatusCode(code: 501, reasonPhrase: "Not Implemented")
    public static let gatewayTimeout = HTTPStatusCode(code: 504, reasonPhrase: "Gateway Timeout")
    public static let serviceUnavailable = HTTPStatusCode(code: 503, reasonPhrase: "Service Unavailable")
}

/// An HTTP response produced by a request handler.
public struct HTTPResponse: Sendable {
    public let status: HTTPStatusCode
    public let headers: HTTPHeaders
    public let body: Data

    public init(
        status: HTTPStatusCode = .ok,
        headers: HTTPHeaders = HTTPHeaders(),
        body: Data = Data()
    ) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func text(
        _ string: String,
        status: HTTPStatusCode = .ok
    ) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["content-type": "text/plain; charset=utf-8"],
            body: Data(string.utf8)
        )
    }
}

/// Errors thrown while starting the HTTP server.
public enum HTTPServerError: Error, Sendable, LocalizedError {
    case alreadyRunning
    case listenerCancelled
    case listenerFailed(String)
    /// A PKCS#12 bundle could not be imported. The associated value is the
    /// Security framework status code.
    case invalidTLSIdentity(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "The HTTP server is already running."
        case .listenerCancelled:
            return "The HTTP listener was cancelled before it became ready."
        case .listenerFailed(let message):
            return "The HTTP listener failed: \(message)"
        case .invalidTLSIdentity(let status):
            return "The TLS identity could not be imported (status \(status))."
        }
    }
}

/// Configuration for ``HTTPServer``.
public struct HTTPServerConfiguration: Sendable {
    /// The local host to bind. Defaults to loopback only.
    public var host: String
    /// The TCP port to bind. Use `0` to let the system choose a free port.
    public var port: UInt16
    /// Maximum accepted HTTP header block size, in bytes.
    public var maxHeaderBytes: Int
    /// Maximum accepted request body size, in bytes.
    public var maxBodyBytes: Int
    /// Value sent in the `Server` response header.
    public var serverHeader: String?
    /// Maximum number of simultaneously open TCP connections.
    public var maxConnections: Int
    /// Seconds a connection may stay idle before it is closed. `0` disables the timeout.
    public var connectionIdleTimeout: TimeInterval
    /// Seconds an async request handler may run before the server answers 504.
    /// `0` (the default) disables the timeout, preserving existing behavior.
    public var handlerTimeout: TimeInterval
    /// TLS settings. When set, the server accepts HTTPS instead of plain HTTP.
    public var tls: HTTPServerTLSConfiguration?
    /// How long `stop()` waits for in-flight requests to finish before
    /// cancelling the remaining connections. `0` closes immediately.
    public var gracefulShutdownTimeout: TimeInterval

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 0,
        maxHeaderBytes: Int = 64 * 1024,
        maxBodyBytes: Int = 16 * 1024 * 1024,
        serverHeader: String? = "BearHttpServer",
        maxConnections: Int = 128,
        connectionIdleTimeout: TimeInterval = 60,
        handlerTimeout: TimeInterval = 0,
        tls: HTTPServerTLSConfiguration? = nil,
        gracefulShutdownTimeout: TimeInterval = 5
    ) {
        self.host = host
        self.port = port
        self.maxHeaderBytes = max(1, maxHeaderBytes)
        self.maxBodyBytes = max(0, maxBodyBytes)
        self.serverHeader = serverHeader
        self.maxConnections = max(1, maxConnections)
        self.connectionIdleTimeout = max(0, connectionIdleTimeout)
        self.handlerTimeout = max(0, handlerTimeout)
        self.tls = tls
        self.gracefulShutdownTimeout = max(0, gracefulShutdownTimeout)
    }

    public static let localhost = HTTPServerConfiguration()
}
