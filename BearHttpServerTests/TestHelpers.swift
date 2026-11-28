//
//  TestHelpers.swift
//  BearHttpServerTests
//

import Foundation
import Network
import Testing
@testable import BearHttpServer

private enum TestError: Error {
case missingCertificate
}

func rawResponse(
    port: UInt16,
    request: String = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
) async throws -> String {
    let connection = NWConnection(
        host: "127.0.0.1",
        port: NWEndpoint.Port(rawValue: port)!,
        using: .tcp
    )
    connection.start(queue: DispatchQueue(label: "bear.test.raw"))
    defer { connection.cancel() }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(
            content: Data(request.utf8),
            completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        )
    }

    let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: data)
            }
        }
    }
    return String(decoding: data ?? Data(), as: UTF8.self)
}

/// Opens a raw TCP connection for tests that need to exchange several
/// messages in sequence (e.g. the 100-continue handshake).
func makeRawConnection(port: UInt16) -> NWConnection {
    let connection = NWConnection(
        host: "127.0.0.1",
        port: NWEndpoint.Port(rawValue: port)!,
        using: .tcp
    )
    connection.start(queue: DispatchQueue(label: "bear.test.raw.stream"))
    return connection
}

func sendRaw(_ text: String, on connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        })
    }
}

func receiveRaw(from connection: NWConnection) async throws -> String {
    let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: data)
            }
        }
    }
    return String(decoding: data ?? Data(), as: UTF8.self)
}

/// Loads the self-signed test identity shipped beside this test source.
/// Resolving via `#filePath` works under both SwiftPM and a plain Xcode
/// test target (where `Bundle.module` is not generated).
func testTLSConfiguration() throws -> HTTPServerTLSConfiguration {
    let sourceURL = URL(fileURLWithPath: #filePath)
    let certificateURL = sourceURL.deletingLastPathComponent()
        .appendingPathComponent("bear_test.p12")
    guard FileManager.default.fileExists(atPath: certificateURL.path) else {
        throw TestError.missingCertificate
    }
    let data = try Data(contentsOf: certificateURL)
    return try HTTPServerTLSConfiguration(pkcs12: data, password: "testpass")
}

/// Opens a TLS connection that accepts the self-signed test certificate.
func makeTLSConnection(port: UInt16) -> NWConnection {
    let options = NWProtocolTLS.Options()
    sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in
        complete(true)
    }, DispatchQueue.global())
    let parameters = NWParameters(tls: options)
    let connection = NWConnection(
        host: "127.0.0.1",
        port: NWEndpoint.Port(rawValue: port)!,
        using: parameters
    )
    connection.start(queue: DispatchQueue(label: "bear.test.tls"))
    return connection
}

func startObjCServer(_ server: ObjCHTTPServer) async throws -> UInt16 {
    try await withCheckedThrowingContinuation { continuation in
        server.start { port, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: UInt16(port))
            }
        }
    }
}

func stopObjCServer(_ server: ObjCHTTPServer) async {
    await withCheckedContinuation { continuation in
        server.stop { continuation.resume() }
    }
}

/// Actor-backed one-shot flag: the first caller to claim wins.
actor OnceFlag {
    private var used = false
    func claim() -> Bool {
        guard !used else { return false }
        used = true
        return true
    }
}

actor Signal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }
}
