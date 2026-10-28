import SwiftUI
import Network
import os
import XCTest
@testable import Playfin

/// Sign-in, Quick Connect, profiles, Keychain session and device identity.
final class SessionTests: AppTestCase {
    func testProfileStoreAndMultiAddress() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-\(UUID().uuidString)")
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }
        try ProfileStore.clear()

        let addr1 = ServerAddress(url: "http://192.168.1.50:8096", label: "Home", priority: 1, isLocal: true)
        let profile = ServerProfile(
            serverId: "srv-multi-test",
            serverName: "TestServer",
            userId: "user-1",
            userName: "Alice",
            userAvatarTag: nil,
            addresses: [addr1],
            isPrimary: true
        )

        try ProfileStore.saveProfile(profile)
        XCTAssertEqual(try ProfileStore.loadAll().count, 1)
        XCTAssertEqual(try ProfileStore.primaryProfile()?.serverId, "srv-multi-test")

        // Add a secondary remote address after validation by the Rust core
        let server = try await MockHttpServer.start(statusCode: 200, responseBody: """
        {"Id":"srv-multi-test","ServerName":"TestServer","Version":"10.9.0"}
        """)
        defer { server.stop() }

        let addr2 = ServerAddress(url: "http://127.0.0.1:\(server.port)", label: "Remote", priority: 2, isLocal: false)
        _ = try await ProfileStore.verifyAndAddAddress(toServerId: "srv-multi-test", address: addr2, timeoutMs: 3000)

        let reloaded = try ProfileStore.primaryProfile()
        XCTAssertEqual(reloaded?.addresses.count, 2)
        XCTAssertEqual(reloaded?.addresses[1].url, "http://127.0.0.1:\(server.port)")
        XCTAssertFalse(reloaded?.addresses[1].isLocal ?? true)

        try ProfileStore.clear()
    }

    @MainActor
    func testLogoutDoesNotClearProfiles() throws {
        SessionStore.setServiceName("com.playfin.app.test.\(UUID().uuidString)")
        defer {
            SessionStore.delete()
            SessionStore.setServiceName(nil)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-\(UUID().uuidString)")
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }
        try ProfileStore.clear()
        let profile = ServerProfile(
            serverId: "srv-persist",
            serverName: "PersistentServer",
            userId: "u-1",
            userName: "Bob",
            userAvatarTag: nil,
            addresses: [ServerAddress(url: "http://192.168.1.10:8096", label: "Home", priority: 1, isLocal: true)],
            isPrimary: true
        )
        try ProfileStore.saveProfile(profile)
        XCTAssertEqual(try ProfileStore.loadAll().count, 1)

        let model = AppModel()
        model.logout()

        // Profiles and addresses must remain intact
        XCTAssertEqual(try ProfileStore.loadAll().count, 1)
        XCTAssertEqual(try ProfileStore.primaryProfile()?.serverName, "PersistentServer")
        try ProfileStore.clear()
    }

    func testProfileStoreCoreOmittedUserAvatarTagDeserialization() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-avatar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let json = """
        [
            {
                "serverId": "srv-omitted-avatar-swift",
                "serverName": "Server Without Avatar",
                "userId": "user-uuid-swift-2",
                "userName": "Bob",
                "addresses": [
                    {
                        "url": "http://127.0.0.1:8096",
                        "label": "Home",
                        "priority": 1,
                        "isLocal": true
                    }
                ],
                "isPrimary": false
            }
        ]
        """
        let filePath = tempDir.appendingPathComponent("profiles.json")
        try json.write(to: filePath, atomically: true, encoding: .utf8)

        let store = ProfileStoreCore(storageDir: tempDir.path)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].serverId, "srv-omitted-avatar-swift")
        XCTAssertEqual(loaded[0].userName, "Bob")
        XCTAssertNil(loaded[0].userAvatarTag)
        XCTAssertFalse(loaded[0].isPrimary)
        XCTAssertEqual(loaded[0].addresses.count, 1)
        XCTAssertEqual(loaded[0].addresses[0].url, "http://127.0.0.1:8096")
    }

    @MainActor
    func testAddSecondaryAddressRejectsMismatchedServerId() async throws {
        let serverJson = """
        {"Id": "rogue-server-999", "ServerName": "Rogue Server", "Version": "10.9.0"}
        """
        let server = try await MockHttpServer.start(statusCode: 200, responseBody: serverJson)
        defer { server.stop() }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)",
            serverId: "expected-server-111",
            userId: "user-1",
            accessToken: "token-1"
        )
        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        let model = AppModel()
        model.client = client

        do {
            try await model.addSecondaryAddress(url: "http://127.0.0.1:\(server.port)", label: "Secondary")
            XCTFail("Must reject address when server ID does not match")
        } catch let JellyfinError.ServerMismatch(message) {
            XCTAssertTrue(message.contains("rogue-server-999") || message.contains("expected-server-111"))
        } catch {
            XCTFail("Expected ServerMismatch, got \(error)")
        }
    }

    @MainActor
    func testLogoutAndResetClearsStateAndSessionWithoutAffectingKeychain() throws {
        SessionStore.setServiceName("com.playfin.app.test.\(UUID().uuidString)")
        defer {
            SessionStore.delete()
            SessionStore.setServiceName(nil)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-logout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:8096",
            serverId: "srv-logout",
            userId: "usr-logout",
            accessToken: "tok-logout"
        )
        SessionStore.save(session)
        XCTAssertNotNil(SessionStore.load())

        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        let model = AppModel()
        model.client = client
        model.screen = .library
        model.lastLoggedInUsername = "Alice"
        model.corruptProfileStorageError = true

        model.logout()

        XCTAssertEqual(model.lastLoggedInUsername, "")
        XCTAssertFalse(model.corruptProfileStorageError)
        XCTAssertNil(model.client)
        XCTAssertEqual(model.screen, .login)
        XCTAssertNil(SessionStore.load())
    }

    @MainActor
    func testCorruptProfileStorageTriggersErrorAndAllowsRecovery() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-test-corrupt-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let profilesFile = tempDir.appendingPathComponent("profiles.json")
        try "corrupted json content".write(to: profilesFile, atomically: true, encoding: .utf8)

        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:8096",
            serverId: "srv-rec",
            userId: "usr-rec",
            accessToken: "tok-rec"
        )
        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        let model = AppModel()
        model.client = client

        // Saving profile when file is corrupt triggers corruptProfileStorageError without setting offlineAlertMessage
        model.saveProfileAfterLogin(info: session, username: "Charlie")
        XCTAssertTrue(model.corruptProfileStorageError)
        XCTAssertNil(model.offlineAlertMessage)

        // Calling repair resets corrupt storage, clears error flag, and saves profile
        try model.repairCorruptProfileStorage(username: "Charlie")
        XCTAssertFalse(model.corruptProfileStorageError)
        XCTAssertNil(model.offlineAlertMessage)

        let reloaded = try ProfileStore.primaryProfile()
        XCTAssertEqual(reloaded?.serverId, "srv-rec")
        XCTAssertEqual(reloaded?.userName, "Charlie")
    }

    func testSessionStoreSavesUnderServerAndUserKeyAndRestores() throws {
        SessionStore.setServiceName("com.playfin.app.test.\(UUID().uuidString)")
        defer {
            SessionStore.delete()
            SessionStore.setServiceName(nil)
        }
        let info = SessionInfo(serverUrl: "http://127.0.0.1:1", serverId: "srv-a", userId: "user-1", accessToken: "tok-1")
        XCTAssertTrue(SessionStore.save(info))

        let loaded = try XCTUnwrap(SessionStore.load())
        XCTAssertEqual(loaded.accessToken, "tok-1")
        XCTAssertEqual(loaded.serverId, "srv-a")
        XCTAssertEqual(SessionStore.accountKey(serverId: "srv-a", userId: "user-1"), "srv-a:user-1")

        // Another user becomes the active session; the first one's token stays, so that profiles can be switched.
        let other = SessionInfo(serverUrl: "http://127.0.0.1:1", serverId: "srv-a", userId: "user-2", accessToken: "tok-2")
        XCTAssertTrue(SessionStore.save(other))
        XCTAssertEqual(SessionStore.load()?.accessToken, "tok-2")
        XCTAssertTrue(SessionStore.hasEntry(serverId: "srv-a", userId: "user-1"))
        XCTAssertEqual(SessionStore.load(serverId: "srv-a", userId: "user-1")?.accessToken, "tok-1")

        // Switch profile, then sign out the first: its token disappears, the other stays.
        XCTAssertTrue(SessionStore.setActive(serverId: "srv-a", userId: "user-1"))
        XCTAssertEqual(SessionStore.load()?.accessToken, "tok-1")
        XCTAssertFalse(SessionStore.setActive(serverId: "srv-a", userId: "inconnu"))
        SessionStore.delete(serverId: "srv-a", userId: "user-1")
        XCTAssertFalse(SessionStore.hasEntry(serverId: "srv-a", userId: "user-1"))
        XCTAssertNil(SessionStore.load(), "the active pointer is deleted with its token")
        XCTAssertTrue(SessionStore.hasEntry(serverId: "srv-a", userId: "user-2"))
        SessionStore.delete(serverId: "srv-a", userId: "user-2")

        SessionStore.delete()
        XCTAssertNil(SessionStore.load())
    }

    func testSessionStoreMigratesLegacySingleEntry() throws {
        let service = "com.playfin.app.test.\(UUID().uuidString)"
        SessionStore.setServiceName(service)
        defer {
            SessionStore.delete()
            SessionStore.setServiceName(nil)
        }
        // Old format: a single "session" entry.
        let legacy = #"{"serverUrl":"http://127.0.0.1:1","serverId":"srv-old","userId":"user-old","accessToken":"tok-old"}"#
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "session",
            kSecValueData as String: Data(legacy.utf8),
        ]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)

        let loaded = try XCTUnwrap(SessionStore.load())
        XCTAssertEqual(loaded.accessToken, "tok-old")

        // The old entry is deleted after the migration, and the new one reloads by itself.
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "session",
        ]
        XCTAssertEqual(SecItemCopyMatching(legacyQuery as CFDictionary, nil), errSecItemNotFound)
        XCTAssertEqual(SessionStore.load()?.userId, "user-old")
    }

    @MainActor
    func testQuickConnectPollingStopsAfterTimeout() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-qc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let polls = OSAllocatedUnfairLock(initialState: 0)
        let server = try await MockHttpServer.start(handler: { _ in
            polls.withLock { $0 += 1 }
            return (200, #"{"Code":"123456","Secret":"s","Authenticated":false}"#)
        })
        defer { server.stop() }

        let model = AppModel()
        // Simulated delay: 15 minutes of polling without real waiting.
        let outcome = await model.runQuickConnectPolling(
            client: makeQuickConnectClient(server: server, tempDir: tempDir), secret: "s",
            interval: .seconds(100), timeout: .seconds(900), sleep: { _ in }
        )
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(polls.withLock { $0 }, 9)
        XCTAssertNotNil(model.loginError)
    }

    @MainActor
    func testQuickConnectPollingStopsOnTerminalError() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-qc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let polls = OSAllocatedUnfairLock(initialState: 0)
        let server = try await MockHttpServer.start(handler: { _ in
            polls.withLock { $0 += 1 }
            return (404, "{}")
        })
        defer { server.stop() }

        let model = AppModel()
        let outcome = await model.runQuickConnectPolling(
            client: makeQuickConnectClient(server: server, tempDir: tempDir), secret: "s",
            interval: .seconds(1), timeout: .seconds(900), sleep: { _ in }
        )
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(polls.withLock { $0 }, 1, "a definitive error stops the loop immediately")
    }

    @MainActor
    func testQuickConnectPollingDoesNotRetryServerErrors() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-qc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let polls = OSAllocatedUnfairLock(initialState: 0)
        let server = try await MockHttpServer.start(handler: { _ in
            polls.withLock { $0 += 1 }
            return (500, "{}")
        })
        defer { server.stop() }

        let model = AppModel()
        let outcome = await model.runQuickConnectPolling(
            client: makeQuickConnectClient(server: server, tempDir: tempDir), secret: "s",
            interval: .seconds(1), timeout: .seconds(900), sleep: { _ in }
        )
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(polls.withLock { $0 }, 1)
    }

    @MainActor
    func testQuickConnectPollingStopsOnCancellation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-qc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let server = try await MockHttpServer.start(handler: { _ in (200, #"{"Code":"1","Secret":"s","Authenticated":false}"#) })
        defer { server.stop() }

        let model = AppModel()
        let client = makeQuickConnectClient(server: server, tempDir: tempDir)
        let task = Task { @MainActor in
            await model.runQuickConnectPolling(client: client, secret: "s", interval: .seconds(30), timeout: .seconds(900))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
    }

    @MainActor
    func testShowAddAddressWorksAfterLaterWasChosen() throws {
        let model = AppModel()
        model.showAddAddress()
        XCTAssertFalse(model.promptSecondaryAddress, "no session: nothing to open")

        model.client = JellyfinClient.restore(
            info: SessionInfo(serverUrl: "http://127.0.0.1:9", serverId: "s-later", userId: "u", accessToken: "t"),
            cacheDir: FileManager.default.temporaryDirectory.path
        )
        model.screen = .library
        model.dismissSecondaryAddressPrompt()
        defer { UserDefaults.standard.removeObject(forKey: "Playfin_SecondaryPromptDismissed_s-later") }
        model.showAddAddress()
        XCTAssertTrue(model.promptSecondaryAddress)
    }

    func testDeviceIdentitySurvivesCachePurge() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("jn-dev-\(UUID().uuidString)")
        let cache = base.appendingPathComponent("cache")
        let support = base.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // The core creates the identifier in the cache; it is copied to Application Support.
        try "playfin-abc".write(to: cache.appendingPathComponent("device_id"), atomically: true, encoding: .utf8)
        DeviceIdentity.sync(cacheDir: cache, persistentDir: support)
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("device_id"), encoding: .utf8), "playfin-abc")

        // macOS empties the Caches: the identifier is restored before the client is created.
        try FileManager.default.removeItem(at: cache)
        DeviceIdentity.sync(cacheDir: cache, persistentDir: support)
        XCTAssertEqual(try String(contentsOf: cache.appendingPathComponent("device_id"), encoding: .utf8), "playfin-abc")
    }

    func testDeviceIdentityDoesNotOverwriteExistingPersistentCopy() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("jn-dev-\(UUID().uuidString)")
        let cache = base.appendingPathComponent("cache")
        let support = base.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try "from-cache".write(to: cache.appendingPathComponent("device_id"), atomically: true, encoding: .utf8)
        try "from-support".write(to: support.appendingPathComponent("device_id"), atomically: true, encoding: .utf8)
        DeviceIdentity.sync(cacheDir: cache, persistentDir: support)
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("device_id"), encoding: .utf8), "from-support")
    }

    @MainActor
    func testSecondaryAddressPromptIsNotRepeatedAfterLater() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "jn-secondary-\(UUID().uuidString)"))
        AppModel.setUserDefaults(defaults)
        defer { AppModel.setUserDefaults(.standard) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ProfileStore.setStorageDirectory(tempDir)
        defer {
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let session = SessionInfo(serverUrl: "http://127.0.0.1:8096", serverId: "srv-sec", userId: "usr-sec", accessToken: "t")
        let model = AppModel()
        model.client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)

        // First sign-in: a second address is offered.
        model.saveProfileAfterLogin(info: session, username: "Ana")
        XCTAssertTrue(model.promptSecondaryAddress)

        // "Later": no more offers on the following sign-ins.
        model.dismissSecondaryAddressPrompt()
        XCTAssertFalse(model.promptSecondaryAddress)
        model.saveProfileAfterLogin(info: session, username: "Ana")
        XCTAssertFalse(model.promptSecondaryAddress)
    }

    /// Smoke test: sign-in to a fake server then home; relaunch with the server stopped:
    /// home from the copy, offline banner and Downloads screen usable.
    @MainActor
    func testSmokeLoginHomeThenOfflineRelaunch() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-smoke-\(UUID().uuidString)")
        ProfileStore.setStorageDirectory(tempDir)
        SessionStore.setServiceName("com.playfin.app.test.\(UUID().uuidString)")
        defer {
            SessionStore.delete()
            SessionStore.setServiceName(nil)
            ProfileStore.setStorageDirectory(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }
        try ProfileStore.clear()

        let server = try await MockHttpServer.start(handler: { request in
            let line = request.components(separatedBy: "\r\n").first ?? ""
            if line.contains("/System/Info/Public") {
                return (200, #"{"Id":"srv-smoke","ServerName":"Lounge","Version":"10.10.0"}"#)
            }
            if line.contains("/Users/AuthenticateByName") {
                return (200, #"{"AccessToken":"tok","ServerId":"srv-smoke","User":{"Id":"user-smoke","Name":"Ana"}}"#)
            }
            if line.contains("/UserItems/Resume") {
                return (200, #"{"Items":[{"Id":"m1","Name":"Movie in progress","Type":"Movie","UserData":{"PlaybackPositionTicks":6000000000,"Played":false}}]}"#)
            }
            if line.contains("/UserViews") {
                return (200, #"{"Items":[{"Id":"lib-1","Name":"Films","CollectionType":"movies"}]}"#)
            }
            return (200, #"{"Items":[],"TotalRecordCount":0}"#)
        })
        let url = "http://127.0.0.1:\(server.port)"

        let model = AppModel()
        _ = try await model.validateServerURL(url)
        let loggedIn = await model.login(server: url, username: "Ana", password: "pw")
        XCTAssertTrue(loggedIn)
        for _ in 0..<100 where model.screen != .library || model.resume.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.screen, .library)
        XCTAssertEqual(model.resume.map(\.id), ["m1"], "home filled by the server")
        XCTAssertEqual(model.profiles.first?.serverName, "Lounge", "the server appears in the profiles")

        // Relaunch with the server stopped.
        server.stop()
        model.reset()
        let relaunched = AppModel()
        relaunched.hasLaunched = true
        await relaunched.start()
        for _ in 0..<250 where !relaunched.isServerUnreachable { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(relaunched.screen, .library, "home from the copy, without waiting")
        XCTAssertEqual(relaunched.resume.map(\.id), ["m1"])
        XCTAssertTrue(relaunched.isServerUnreachable, "offline banner")

        // The Downloads screen shows without a server.
        relaunched.selectedSection = .downloads
        let host = NSHostingView(rootView: DownloadsView().environment(relaunched))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        relaunched.reset()
    }
}
