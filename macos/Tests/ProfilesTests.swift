import XCTest
@testable import Playfin

@MainActor
final class ProfilesTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-prof-\(UUID().uuidString)")
        ProfileStore.setStorageDirectory(dir)
        SessionStore.setServiceName("com.playfin.app.test.\(UUID().uuidString)")
        try ProfileStore.clear()
    }

    override func tearDown() async throws {
        SessionStore.delete()
        SessionStore.setServiceName(nil)
        ProfileStore.setStorageDirectory(nil)
        try? FileManager.default.removeItem(at: dir)
    }

    private func address(_ url: String, _ label: String, _ priority: UInt32) -> ServerAddress {
        ServerAddress(url: url, label: label, priority: priority, isLocal: false)
    }

    private func profile(user: String, primary: Bool = false) -> ServerProfile {
        ServerProfile(
            serverId: "srv-1", serverName: "Lounge", userId: user, userName: user.capitalized,
            userAvatarTag: nil,
            addresses: [address("https://a.example.com", "Remote", 1), address("https://b.example.com", "Backup", 2)],
            isPrimary: primary
        )
    }

    func testSecondUserInheritsAddressesAndDoesNotStealPrimary() throws {
        let model = AppModel()
        let first = SessionInfo(serverUrl: "https://a.example.com", serverId: "srv-1", userId: "ana", accessToken: "t1")
        model.saveProfileAfterLogin(info: first, username: "Ana")
        try ProfileStore.saveProfile(profile(user: "ana", primary: true))
        // Adds a 2nd address to Ana, then signs Ben in on the same server.
        let second = SessionInfo(serverUrl: "https://a.example.com", serverId: "srv-1", userId: "ben", accessToken: "t2")
        model.saveProfileAfterLogin(info: second, username: "Ben")

        let all = try ProfileStore.loadAll()
        let ben = try XCTUnwrap(all.first { $0.userId == "ben" })
        XCTAssertEqual(ben.addresses.count, 2, "same addresses as the first user of the server")
        XCTAssertFalse(ben.isPrimary)
        XCTAssertTrue(try XCTUnwrap(all.first { $0.userId == "ana" }).isPrimary)
        XCTAssertEqual(model.profiles.count, 2)
    }

    func testAddressEditsApplyToEveryUserOfTheServerAndDropAForcedAddressThatWasRemoved() throws {
        try ProfileStore.saveAll([profile(user: "ana", primary: true), profile(user: "ben")])
        let model = AppModel()
        model.refreshProfiles()

        model.setForcedAddress("https://b.example.com", forServer: "srv-1")
        XCTAssertEqual(model.profiles.map(\.forcedAddress), ["https://b.example.com", "https://b.example.com"])

        model.moveAddress(forServer: "srv-1", from: 1, to: 0)
        XCTAssertEqual(model.profiles[0].addresses.map(\.label), ["Backup", "Remote"])
        XCTAssertEqual(model.profiles[1].addresses.map(\.priority), [1, 2])

        model.removeAddress(forServer: "srv-1", at: 0) // deletes "Backup", the forced address
        XCTAssertEqual(model.profiles[0].addresses.map(\.label), ["Remote"])
        XCTAssertNil(model.profiles[0].forcedAddress)

        model.removeAddress(forServer: "srv-1", at: 0)
        XCTAssertEqual(model.profiles[0].addresses.count, 1, "the last address cannot be deleted")
    }

    func testSwitchProfileNeedsASavedTokenAndPrimaryCanBeChanged() throws {
        try ProfileStore.saveAll([profile(user: "ana", primary: true), profile(user: "ben")])
        SessionStore.save(SessionInfo(serverUrl: "https://a.example.com", serverId: "srv-1", userId: "ana", accessToken: "t1"))
        let model = AppModel()
        model.refreshProfiles()
        model.screen = .library

        // Ben has no token: we offer sign-in with the server address already prefilled.
        let ben = try XCTUnwrap(model.profiles.first { $0.userId == "ben" })
        model.switchProfile(ben)
        XCTAssertEqual(model.screen, .login)
        XCTAssertTrue(model.isAddingProfile)
        XCTAssertEqual(model.loginPrefillServer, "https://a.example.com")

        SessionStore.save(SessionInfo(serverUrl: "https://a.example.com", serverId: "srv-1", userId: "ben", accessToken: "t2"))
        SessionStore.setActive(serverId: "srv-1", userId: "ana")
        model.screen = .library
        model.switchProfile(ben)
        XCTAssertEqual(model.screen, .loading, "with a token: Ben's session is reopened")
        XCTAssertEqual(SessionStore.load()?.userId, "ben")

        model.setPrimary(ben)
        XCTAssertEqual(model.profiles.first { $0.isPrimary }?.userId, "ben")
        XCTAssertEqual(model.profiles.filter(\.isPrimary).count, 1)
    }

    func testSignOutRemovesTheTokenAndPromotesAnotherPrimary() throws {
        try ProfileStore.saveAll([profile(user: "ana", primary: true), profile(user: "ben")])
        SessionStore.save(SessionInfo(serverUrl: "https://a.example.com", serverId: "srv-1", userId: "ben", accessToken: "t2"))
        SessionStore.save(SessionInfo(serverUrl: "https://a.example.com", serverId: "srv-1", userId: "ana", accessToken: "t1"))
        let model = AppModel()
        model.refreshProfiles()
        let ana = try XCTUnwrap(model.profiles.first { $0.userId == "ana" })

        model.signOut(ana)
        XCTAssertFalse(SessionStore.hasEntry(serverId: "srv-1", userId: "ana"))
        XCTAssertTrue(SessionStore.hasEntry(serverId: "srv-1", userId: "ben"))
        XCTAssertEqual(model.profiles.map(\.userId), ["ben"])
        XCTAssertEqual(try ProfileStore.primaryProfile()?.userId, "ben", "a primary profile always exists")
    }

    func testTestsNeverTouchTheRealUserData() {
        XCTAssertTrue(AppPaths.isRunningTests)
        let temp = FileManager.default.temporaryDirectory.path
        XCTAssertTrue(AppPaths.cachesDirectory.path.hasPrefix(temp))
        AppPaths.supportDirectoryOverride = nil
        defer { AppPaths.supportDirectoryOverride = nil }
        XCTAssertTrue(AppPaths.supportDirectory.path.hasPrefix(temp), "profiles and settings outside the real folder")
        XCTAssertNotEqual(AppPaths.sessionService, AppPaths.bundleName, "separate sessions during the tests")
    }

    func testAMissingProfileIsRecreatedFromTheOpenSession() throws {
        let model = AppModel()
        let session = SessionInfo(serverUrl: "https://jf.example.com/", serverId: "srv-9", userId: "u-9", accessToken: "t")
        let created = try XCTUnwrap(model.recreateProfile(for: session, existing: []))
        XCTAssertEqual(created.addresses.map(\.url), ["https://jf.example.com"])
        XCTAssertTrue(created.isPrimary, "only profile: it becomes primary")
        XCTAssertEqual(try ProfileStore.loadAll().map(\.id), ["srv-9:u-9"])
        XCTAssertEqual(model.profiles.count, 1, "visible right away in the settings")
    }

    func testProfileInitialsAndIdentity() {
        XCTAssertEqual(profile(user: "ana").initials, "A")
        var named = profile(user: "x")
        named.userName = "Ana Lopez"
        XCTAssertEqual(named.initials, "AL")
        XCTAssertEqual(profile(user: "ana").id, "srv-1:ana")
    }

    func testDiagnosticsNeverContainTokens() {
        let report = DiagnosticsReport.build(
            appVersion: "1.0", coreVersion: "0.1", systemVersion: "macOS",
            servers: [.init(name: "Lounge", addressCount: 2, activeAddressLabel: "Home")],
            settings: defaultSettings(), logs: ["ligne"]
        )
        XCTAssertTrue(report.contains("Lounge"))
        XCTAssertFalse(report.lowercased().contains("token"))
        XCTAssertFalse(report.contains("t1"))
    }
}
