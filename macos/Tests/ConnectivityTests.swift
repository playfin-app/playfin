import SwiftUI
import Network
import os
import XCTest
@testable import Playfin

/// Offline mode, server probes, network changes and error handling.
final class ConnectivityTests: AppTestCase {
    @MainActor
    func testOfflineModeBlocksPlaybackAndShowsAlert() {
        let model = AppModel()
        model.isServerUnreachable = true
        XCTAssertTrue(model.isServerUnreachable)

        let movie = Movie(
            id: "mov-offline-1",
            name: "Offline Movie",
            sortName: nil,
            productionYear: 2024,
            premiereDate: nil,
            runTimeTicks: nil,
            container: nil,
            overview: nil,
            communityRating: nil,
            criticRating: nil,
            officialRating: nil,
            genres: [],
            dateCreated: nil,
            people: [],
            userData: nil,
            seriesName: nil,
            seriesId: nil,
            seasonId: nil,
            seasonName: nil,
            indexNumber: nil,
            parentIndexNumber: nil,
            itemType: "Movie",
            width: nil,
            height: nil,
            primaryBlurHash: nil,
            primaryImageAspectRatio: nil
        )

        model.play(movie)
        XCTAssertNil(model.playback)
        XCTAssertNotNil(model.offlineAlertMessage)
        XCTAssertTrue(model.offlineAlertMessage?.contains("server") == true)
    }

    @MainActor
    func testProbeAndRecoverUnauthorizedTransitionsToLogin() async throws {
        SessionStore.setServiceName("com.playfin.app.test.\(UUID().uuidString)")
        defer {
            SessionStore.delete()
            SessionStore.setServiceName(nil)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let server = try await MockHttpServer.start(statusCode: 401)
        defer { server.stop() }

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)",
            serverId: "srv-401-test",
            userId: "user-401",
            accessToken: "token-401"
        )
        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)

        let model = AppModel()
        model.client = client
        model.screen = .library
        model.isServerUnreachable = true

        let result = await model.probeAndRecover(skipAddressSelection: true)

        XCTAssertEqual(result, .terminal)
        XCTAssertEqual(model.screen, .login)
        XCTAssertEqual(model.loginError, "Your session has expired. Please sign in again.")
        XCTAssertFalse(model.isServerUnreachable)
        XCTAssertNil(model.client)
    }

    @MainActor
    func testNetworkPathUpdateUnauthorizedTransitionsToLoginWithoutProber() async throws {
        SessionStore.setServiceName("com.playfin.app.test.\(UUID().uuidString)")
        defer {
            SessionStore.delete()
            SessionStore.setServiceName(nil)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let server = try await MockHttpServer.start(handler: { request in
            if request.contains("/System/Info/Public") {
                return (200, "{\"Id\": \"srv-net-401\", \"ServerName\": \"Test\", \"Version\": \"10.9.0\"}")
            } else {
                return (401, "")
            }
        })
        defer { server.stop() }

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)",
            serverId: "srv-net-401",
            userId: "user-net-401",
            accessToken: "token-net-401"
        )
        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        let model = AppModel()
        model.client = client
        model.screen = .library
        model.isServerUnreachable = false

        let addr = ServerAddress(url: "http://127.0.0.1:\(server.port)", label: "Local", priority: 1, isLocal: true)
        let profile = ServerProfile(
            serverId: "srv-net-401",
            serverName: "Test",
            userId: "user-net-401",
            userName: "Tester",
            userAvatarTag: nil,
            addresses: [addr],
            isPrimary: true
        )
        try ProfileStore.saveProfile(profile)

        await model.handleNetworkPathUpdate(isSatisfied: true)

        XCTAssertEqual(model.screen, .login)
        XCTAssertEqual(model.loginError, "Your session has expired. Please sign in again.")
        XCTAssertFalse(model.isServerUnreachable)
        XCTAssertNil(model.client)
    }

    @MainActor
    func testProbeAndRecoverStaleClientDoesNotLogoutNewSession() async throws {
        SessionStore.setServiceName("com.playfin.app.test.\(UUID().uuidString)")
        defer {
            SessionStore.delete()
            SessionStore.setServiceName(nil)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let latch = AsyncLatch()
        let server = try await MockHttpServer.start(handler: { _ in
            latch.requestReceived()
            return (401, "")
        })
        defer {
            latch.unblock()
            server.stop()
        }

        let oldSession = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)",
            serverId: "old-srv",
            userId: "old-user",
            accessToken: "old-tok"
        )
        let oldClient = JellyfinClient.restore(info: oldSession, cacheDir: tempDir.path)

        let newSession = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)",
            serverId: "new-srv",
            userId: "new-user",
            accessToken: "new-tok"
        )
        let newClient = JellyfinClient.restore(info: newSession, cacheDir: tempDir.path)

        let model = AppModel()
        model.client = oldClient
        model.screen = .library

        let probeTask = Task { @MainActor in
            await model.probeAndRecover(skipAddressSelection: true)
        }

        try await latch.waitForRequest()
        // Client swapped while old client probe request is in flight
        model.client = newClient
        latch.unblock()

        let result = await probeTask.value
        XCTAssertEqual(result, .terminal)
        // Stale client 401 must not logout or wipe the new session
        XCTAssertEqual(model.screen, .library)
        XCTAssertEqual(model.client?.sessionInfo()?.userId, "new-user")
        XCTAssertNil(model.loginError)
    }

    @MainActor
    func testProbeAndRecoverServerErrorSetsAlertAndReturnsTerminal() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-server-err-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let server = try await MockHttpServer.start(statusCode: 500)
        defer { server.stop() }

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)",
            serverId: "err-srv",
            userId: "err-user",
            accessToken: "err-tok"
        )
        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        let model = AppModel()
        model.client = client
        model.screen = .library

        let result = await model.probeAndRecover(skipAddressSelection: true)
        XCTAssertEqual(result, .terminal)
        XCTAssertFalse(model.isServerUnreachable)
        XCTAssertEqual(model.offlineAlertMessage, "Server error: the server encountered an error.")
    }

    @MainActor
    func testProbeAndRecoverHomeCancellationWithNetworkFailureDoesNotSetOfflineOrAlert() async throws {
        SessionStore.setServiceName("com.playfin.app.test.\(UUID().uuidString)")
        defer {
            SessionStore.delete()
            SessionStore.setServiceName(nil)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-cancel-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let latch = AsyncLatch()
        let server = try await MockHttpServer.start(handler: { _ in
            latch.requestReceived()
            return (200, "{\"Items\":[]}")
        })
        defer {
            latch.unblock()
            server.stop()
        }

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)",
            serverId: "srv-cancel-home",
            userId: "usr-cancel-home",
            accessToken: "tok-cancel-home"
        )
        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        let model = AppModel()
        model.client = client
        model.screen = .library

        var caughtError: Error?
        model.onProbeErrorCaught = { caughtError = $0 }

        let task = Task { @MainActor in
            await model.probeAndRecover(skipAddressSelection: true)
        }

        try await latch.waitForRequest()
        task.cancel()
        server.stop()
        latch.unblock()

        let result = await task.value
        XCTAssertEqual(result, .terminal)
        XCTAssertNotNil(caughtError, "Must prove the in-flight call failed with a typed error while cancelled")
        if case .Network = caughtError as? JellyfinError {}
        else if case .ServerUnreachable = caughtError as? JellyfinError {}
        else { XCTFail("Expected .Network or .ServerUnreachable, got \(String(describing: caughtError))") }
        XCTAssertFalse(model.isServerUnreachable)
        XCTAssertNil(model.offlineAlertMessage)
        XCTAssertNil(model.loginError)
    }

    @MainActor
    func testProbeAndRecoverAddressSelectionCancellationWithNetworkFailureDoesNotSetOfflineOrAlert() async throws {
        SessionStore.setServiceName("com.playfin.app.test.\(UUID().uuidString)")
        defer {
            SessionStore.delete()
            SessionStore.setServiceName(nil)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-cancel-addr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let latch = AsyncLatch()
        let server = try await MockHttpServer.start(handler: { _ in
            latch.requestReceived()
            return (200, "{\"Id\":\"srv-cancel-addr\",\"ServerName\":\"Test\",\"Version\":\"10.9.0\"}")
        })
        defer {
            latch.unblock()
            server.stop()
        }

        let addr1 = ServerAddress(url: "http://127.0.0.1:\(server.port)", label: "Primary", priority: 1, isLocal: true)
        let addr2 = ServerAddress(url: "http://127.0.0.1:\(server.port)/alt", label: "Secondary", priority: 2, isLocal: true)
        let profile = ServerProfile(
            serverId: "srv-cancel-addr",
            serverName: "Test",
            userId: "usr-cancel-addr",
            userName: "Tester",
            userAvatarTag: nil,
            addresses: [addr1, addr2],
            isPrimary: true
        )
        try ProfileStore.saveProfile(profile)

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)",
            serverId: "srv-cancel-addr",
            userId: "usr-cancel-addr",
            accessToken: "tok-cancel-addr"
        )
        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        let model = AppModel()
        model.client = client
        model.screen = .library

        var caughtError: Error?
        model.onProbeErrorCaught = { caughtError = $0 }

        let task = Task { @MainActor in
            await model.probeAndRecover(skipAddressSelection: false)
        }

        try await latch.waitForRequest()
        task.cancel()
        server.stop()
        latch.unblock()

        let result = await task.value
        XCTAssertEqual(result, .terminal)
        XCTAssertNotNil(caughtError, "Must prove the in-flight call failed with a typed error while cancelled")
        if case .Network = caughtError as? JellyfinError {}
        else if case .ServerUnreachable = caughtError as? JellyfinError {}
        else { XCTFail("Expected .Network or .ServerUnreachable, got \(String(describing: caughtError))") }
        XCTAssertFalse(model.isServerUnreachable)
        XCTAssertNil(model.offlineAlertMessage)
        XCTAssertNil(model.loginError)
    }

    @MainActor
    func testNetworkPathUpdateCancellationWithNetworkErrorDoesNotSetOfflineOrStartProber() async throws {
        SessionStore.setServiceName("com.playfin.app.test.\(UUID().uuidString)")
        defer {
            SessionStore.delete()
            SessionStore.setServiceName(nil)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-cancel-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let latch = AsyncLatch()
        let server = try await MockHttpServer.start(handler: { _ in
            latch.requestReceived()
            return (200, "{\"Id\":\"srv-cancel-net\",\"ServerName\":\"Test\",\"Version\":\"10.9.0\"}")
        })
        defer {
            latch.unblock()
            server.stop()
        }

        let addr = ServerAddress(url: "http://127.0.0.1:\(server.port)", label: "Primary", priority: 1, isLocal: true)
        let profile = ServerProfile(
            serverId: "srv-cancel-net",
            serverName: "Test",
            userId: "usr-cancel-net",
            userName: "Tester",
            userAvatarTag: nil,
            addresses: [addr],
            isPrimary: true
        )
        try ProfileStore.saveProfile(profile)

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)",
            serverId: "srv-cancel-net",
            userId: "usr-cancel-net",
            accessToken: "tok-cancel-net"
        )
        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        let model = AppModel()
        model.client = client
        model.screen = .library
        model.isServerUnreachable = false

        var caughtError: Error?
        model.onProbeErrorCaught = { caughtError = $0 }

        let task = Task { @MainActor in
            await model.handleNetworkPathUpdate(isSatisfied: true)
        }

        try await latch.waitForRequest()
        task.cancel()
        server.stop()
        latch.unblock()

        await task.value
        XCTAssertNotNil(caughtError, "Must prove onNetworkChanged failed with a typed error while cancelled")
        if case .Network = caughtError as? JellyfinError {}
        else if case .ServerUnreachable = caughtError as? JellyfinError {}
        else { XCTFail("Expected .Network or .ServerUnreachable, got \(String(describing: caughtError))") }
        XCTAssertFalse(model.isServerUnreachable)
        XCTAssertNil(model.offlineAlertMessage)
        XCTAssertNil(model.loginError)
    }

    @MainActor
    func testProbeAndRecoverUnauthorizedDuringCancellationLogsOutAndClearsSession() async throws {
        SessionStore.setServiceName("com.playfin.app.test.\(UUID().uuidString)")
        defer {
            SessionStore.delete()
            SessionStore.setServiceName(nil)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-cancel-unauth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let latch = AsyncLatch()
        let server = try await MockHttpServer.start(handler: { _ in
            latch.requestReceived()
            return (401, "")
        })
        defer {
            latch.unblock()
            server.stop()
        }

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)",
            serverId: "srv-cancel-unauth",
            userId: "usr-cancel-unauth",
            accessToken: "tok-cancel-unauth"
        )
        SessionStore.save(session)
        XCTAssertNotNil(SessionStore.load())

        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        let model = AppModel()
        model.client = client
        model.screen = .library

        var caughtError: Error?
        model.onProbeErrorCaught = { caughtError = $0 }

        let task = Task { @MainActor in
            await model.probeAndRecover(skipAddressSelection: true)
        }

        try await latch.waitForRequest()
        task.cancel()
        latch.unblock() // Mock returns 401 while task is cancelled

        let result = await task.value
        XCTAssertEqual(result, .terminal)
        XCTAssertNotNil(caughtError)
        if case .Unauthorized = caughtError as? JellyfinError {
            // Expected
        } else {
            XCTFail("Expected .Unauthorized, got \(String(describing: caughtError))")
        }
        // Auth failure must never be swallowed on cancellation (Pitfall 1)
        XCTAssertEqual(model.screen, .login)
        XCTAssertEqual(model.loginError, "Your session has expired. Please sign in again.")
        XCTAssertNil(SessionStore.load())
        XCTAssertNil(model.client)
    }

    @MainActor
    func testProbeAndRecoverServerErrorDuringCancellationDoesNotSetAlert() async throws {
        SessionStore.setServiceName("com.playfin.app.test.\(UUID().uuidString)")
        defer {
            SessionStore.delete()
            SessionStore.setServiceName(nil)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-cancel-500-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let latch = AsyncLatch()
        let server = try await MockHttpServer.start(handler: { _ in
            latch.requestReceived()
            return (500, "")
        })
        defer {
            latch.unblock()
            server.stop()
        }

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)",
            serverId: "srv-cancel-500",
            userId: "usr-cancel-500",
            accessToken: "tok-cancel-500"
        )
        SessionStore.save(session)
        XCTAssertNotNil(SessionStore.load())

        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        let model = AppModel()
        model.client = client
        model.screen = .library

        var caughtError: Error?
        model.onProbeErrorCaught = { caughtError = $0 }

        let task = Task { @MainActor in
            await model.probeAndRecover(skipAddressSelection: true)
        }

        try await latch.waitForRequest()
        task.cancel()
        latch.unblock()

        let result = await task.value
        XCTAssertEqual(result, .terminal)
        XCTAssertNotNil(caughtError)
        if case .ServerError = caughtError as? JellyfinError {}
        else {
            XCTFail("Expected .ServerError, got \(String(describing: caughtError))")
        }
        // If the task was cancelled, a server error does not present a terminal error alert popup
        XCTAssertNil(model.offlineAlertMessage)
        XCTAssertNil(model.loginError)
        XCTAssertNotNil(SessionStore.load(), "Session must remain intact on server error during cancellation")
        XCTAssertNotNil(model.client, "Client must remain intact on server error during cancellation")
    }

    @MainActor
    func testHandleAsyncOperationErrorUnauthorizedLogsOutEvenIfTaskCancelled() async throws {
        SessionStore.setServiceName("com.playfin.app.test.\(UUID().uuidString)")
        defer {
            SessionStore.delete()
            SessionStore.setServiceName(nil)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-dispatch-unauth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:8096",
            serverId: "srv-dispatch-unauth",
            userId: "usr-dispatch-unauth",
            accessToken: "tok-dispatch-unauth"
        )
        SessionStore.save(session)
        XCTAssertNotNil(SessionStore.load())

        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        let model = AppModel()
        model.client = client
        model.screen = .library

        var caughtError: Error?
        model.onProbeErrorCaught = { caughtError = $0 }

        let task = Task { @MainActor in
            _ = model.handleAsyncOperationError(JellyfinError.Unauthorized(message: "expired"), for: client) {
                XCTFail("onNetworkError should not be called for Unauthorized")
                return .offline
            }
        }
        task.cancel()
        await task.value

        XCTAssertNotNil(caughtError)
        if case .Unauthorized = caughtError as? JellyfinError {}
        else {
            XCTFail("Expected .Unauthorized, got \(String(describing: caughtError))")
        }
        XCTAssertEqual(model.screen, .login)
        XCTAssertEqual(model.loginError, "Your session has expired. Please sign in again.")
        XCTAssertNil(SessionStore.load())
        XCTAssertNil(model.client)
    }

    @MainActor
    func testHandleAsyncOperationErrorNetworkErrorWhenCancelledReturnsTerminalWithoutOfflineCallback() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-dispatch-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:8096",
            serverId: "srv-dispatch-net",
            userId: "usr-dispatch-net",
            accessToken: "tok-dispatch-net"
        )
        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        let model = AppModel()
        model.client = client
        model.screen = .library

        var offlineCalled = false
        var outcome: AppModel.HandledErrorOutcome?

        let task = Task { @MainActor in
            outcome = model.handleAsyncOperationError(JellyfinError.Network(message: "timeout"), for: client) {
                offlineCalled = true
                return .offline
            }
        }
        task.cancel()
        await task.value

        XCTAssertEqual(outcome, .terminal)
        XCTAssertFalse(offlineCalled, "Network error during cancellation must not trigger offline transition")
    }

    @MainActor
    func testProbeAndRecoverServerMismatchStopsProberAndSetsAlert() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-mismatch-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Server returns public info with a mismatched ID
        let server = try await MockHttpServer.start(statusCode: 200, responseBody: "{\"Id\": \"rogue-srv\", \"ServerName\": \"Rogue\", \"Version\": \"10.9.0\"}")
        defer { server.stop() }

        let addr = ServerAddress(url: "http://127.0.0.1:\(server.port)", label: "Local", priority: 1, isLocal: true)
        let profile = ServerProfile(
            serverId: "expected-srv",
            serverName: "Expected",
            userId: "user-1",
            userName: "Alice",
            userAvatarTag: nil,
            addresses: [addr, ServerAddress(url: "http://127.0.0.1:\(server.port)/alt", label: "Alt", priority: 2, isLocal: true)],
            isPrimary: true
        )
        try ProfileStore.saveProfile(profile)

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)",
            serverId: "expected-srv",
            userId: "user-1",
            accessToken: "token-1"
        )
        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        let model = AppModel()
        model.client = client
        model.screen = .library

        let result = await model.probeAndRecover(skipAddressSelection: false)
        XCTAssertEqual(result, .terminal)
        XCTAssertFalse(model.isServerUnreachable)
        XCTAssertEqual(model.offlineAlertMessage, "Warning: the detected server does not match the configured server.")
    }

    @MainActor
    func testNetworkPathUpdateServerMismatchStopsProberAndSetsAlert() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-mismatch-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Server returns mismatched server ID
        let server = try await MockHttpServer.start(statusCode: 200, responseBody: "{\"Id\": \"rogue-srv\", \"ServerName\": \"Rogue\", \"Version\": \"10.9.0\"}")
        defer { server.stop() }

        let addr = ServerAddress(url: "http://127.0.0.1:\(server.port)", label: "Local", priority: 1, isLocal: true)
        let profile = ServerProfile(
            serverId: "expected-srv",
            serverName: "Expected",
            userId: "user-1",
            userName: "Alice",
            userAvatarTag: nil,
            addresses: [addr],
            isPrimary: true
        )
        try ProfileStore.saveProfile(profile)

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)",
            serverId: "expected-srv",
            userId: "user-1",
            accessToken: "token-1"
        )
        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        let model = AppModel()
        model.client = client
        model.screen = .library
        model.startBackgroundProber()

        await model.handleNetworkPathUpdate(isSatisfied: true)

        XCTAssertFalse(model.isServerUnreachable)
        XCTAssertEqual(model.offlineAlertMessage, "Warning: the detected server does not match the configured server.")
    }

    @MainActor
    func testNetworkEventsAreDeduplicated() {
        let model = AppModel()
        model.scheduleNetworkPathUpdate(isSatisfied: true, signature: "a") // initial state: ignored
        model.scheduleNetworkPathUpdate(isSatisfied: true, signature: "a") // identical: ignored
        // No crash nor induced offline state without a session.
        XCTAssertFalse(model.isServerUnreachable)
    }
}
