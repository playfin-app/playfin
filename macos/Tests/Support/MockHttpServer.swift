import SwiftUI
import Network
import os
import XCTest
@testable import Playfin

final class MockHttpServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16
    private let activeConnections = OSAllocatedUnfairLock(initialState: [NWConnection]())
    private let serverRef: OSAllocatedUnfairLock<MockHttpServer?>

    private init(listener: NWListener, port: UInt16, serverRef: OSAllocatedUnfairLock<MockHttpServer?>) {
        self.listener = listener
        self.port = port
        self.serverRef = serverRef
    }

    fileprivate func track(_ connection: NWConnection) {
        activeConnections.withLock { $0.append(connection) }
    }

    fileprivate func untrack(_ connection: NWConnection) {
        activeConnections.withLock { conns in
            conns.removeAll(where: { $0 === connection })
        }
    }

    static func start(
        handler: (@Sendable (String) -> (Int, String))? = nil,
        statusCode: Int = 200,
        responseBody: String = "",
        contentType: String = "application/json"
    ) async throws -> MockHttpServer {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: .any)
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let serverRef = OSAllocatedUnfairLock<MockHttpServer?>(initialState: nil)
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue {
                    let shouldResume = resumed.withLock { isResumed in
                        if !isResumed {
                            isResumed = true
                            return true
                        }
                        return false
                    }
                    if shouldResume {
                        let server = MockHttpServer(listener: listener, port: port, serverRef: serverRef)
                        serverRef.withLock { $0 = server }
                        continuation.resume(returning: server)
                    }
                } else if case .failed(let err) = state {
                    let shouldResume = resumed.withLock { isResumed in
                        if !isResumed {
                            isResumed = true
                            return true
                        }
                        return false
                    }
                    if shouldResume {
                        continuation.resume(throwing: err)
                    }
                }
            }
            listener.newConnectionHandler = { connection in
                serverRef.withLock { $0?.track(connection) }
                connection.start(queue: .global(qos: .userInitiated))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    let reqString = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let (code, body) = handler?(reqString) ?? (statusCode, responseBody)
                    let bodyData = body.data(using: .utf8) ?? Data()
                    let header = "HTTP/1.1 \(code) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
                    var fullResponse = header.data(using: .utf8) ?? Data()
                    fullResponse.append(bodyData)
                    connection.send(content: fullResponse, completion: .contentProcessed({ _ in
                        connection.cancel()
                        serverRef.withLock { $0?.untrack(connection) }
                    }))
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func stop() {
        listener.cancel()
        serverRef.withLock { $0 = nil }
        let conns = activeConnections.withLock { conns in
            let copy = conns
            conns.removeAll()
            return copy
        }
        for conn in conns {
            conn.cancel()
        }
    }
}

/// `AsyncLatch` coordinates the asynchronous tests: when an HTTP request arrives on the mock,
/// `requestReceived()` notifies the test via `continuation.yield()`, then suspends the network thread
/// until the test orders the continuation via `unblock()`.
/// The 2 s timeout acts as a safeguard in case of abnormal interruption.
/// Later concurrent requests chain immediately by baton passing thanks to the re-signal.
/// `DispatchSemaphore.signal()` is thread-safe and non-blocking.
final class AsyncLatch: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let continuation: AsyncStream<Void>.Continuation
    let stream: AsyncStream<Void>

    init() {
        let (s, c) = AsyncStream.makeStream(of: Void.self)
        self.stream = s
        self.continuation = c
    }

    func requestReceived() {
        continuation.yield()
        _ = semaphore.wait(timeout: .now() + 2.0)
        semaphore.signal()
    }

    func unblock() {
        semaphore.signal()
    }

    func waitForRequest(timeoutSeconds: Double = 2.0) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in self.stream {
                    return
                }
            }
            group.addTask {
                let ns = UInt64(timeoutSeconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: ns)
                throw NSError(domain: "Timeout", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock request timed out"])
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

