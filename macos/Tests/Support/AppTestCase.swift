import SwiftUI
import Network
import os
import XCTest
@testable import Playfin

/// GitHub's macOS runners are virtual machines: no video hardware decoding and a small screen.
/// The CI sets `TEST_RUNNER_PLAYFIN_CI=1`, which xcodebuild passes to the tests as `PLAYFIN_CI`.
func skipOnCI(_ reason: String) throws {
    if ProcessInfo.processInfo.environment["PLAYFIN_CI"] == "1" { throw XCTSkip("Skipped on CI: \(reason)") }
}

/// Base class of the app tests: each test gets its own `UserDefaults`, and shared helpers live here.
class AppTestCase: XCTestCase {
    private var testDefaultsSuiteName: String?

    override func setUp() {
        super.setUp()
        let suite = "com.playfin.app.test.\(UUID().uuidString)"
        testDefaultsSuiteName = suite
        if let defaults = UserDefaults(suiteName: suite) {
            MainActor.assumeIsolated {
                AppModel.setUserDefaults(defaults)
            }
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            AppModel.setUserDefaults(.standard)
        }
        if let suite = testDefaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            testDefaultsSuiteName = nil
        }
        super.tearDown()
    }

    @MainActor
    func makeQuickConnectClient(server: MockHttpServer, tempDir: URL) -> JellyfinClient {
        JellyfinClient(serverUrl: "http://127.0.0.1:\(server.port)", cacheDir: tempDir.path)
    }

    @MainActor
    func makeWatchedFixture(status: Int) async throws -> (AppModel, Movie, MockHttpServer, URL, OSAllocatedUnfairLock<[String]>) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let requests = OSAllocatedUnfairLock(initialState: [String]())
        let server = try await MockHttpServer.start(handler: { request in
            requests.withLock { $0.append(request.components(separatedBy: "\r\n").first ?? "") }
            return (status, "{}")
        })
        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)", serverId: "srv", userId: "user-w", accessToken: "tok"
        )
        let movie = Movie(
            id: "m-1", name: "Film", sortName: nil, productionYear: nil, premiereDate: nil,
            runTimeTicks: nil, container: nil, overview: nil, communityRating: nil,
            criticRating: nil, officialRating: nil, genres: [], dateCreated: nil,
            people: [], userData: UserData(playbackPositionTicks: 600_000_000, played: false, playedPercentage: 10.0),
            seriesName: nil, seriesId: nil, seasonId: nil, seasonName: nil, indexNumber: nil,
            parentIndexNumber: nil, itemType: "Movie", width: nil, height: nil,
            primaryBlurHash: nil, primaryImageAspectRatio: nil
        )
        let model = AppModel()
        model.client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        model.movies = [movie]
        model.resume = [movie]
        model.remember([movie])
        return (model, movie, server, tempDir, requests)
    }

    /// Waits until the animated scroll is finished (position stable for 100 ms), instead of a fixed delay.
    @MainActor
    func settle(_ scrollView: NSScrollView, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        var last = scrollView.contentView.bounds.origin.x
        var stableSince = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            let now = scrollView.contentView.bounds.origin.x
            if now != last { last = now; stableSince = Date() }
            if Date().timeIntervalSince(stableSince) > 0.1 { return }
        }
    }

    func makeItem(id: String = "x", type: String?, ratio: Double? = nil) -> Movie {
        Movie(
            id: id, name: id, sortName: nil, productionYear: nil, premiereDate: nil,
            runTimeTicks: nil, container: nil, overview: nil, communityRating: nil,
            criticRating: nil, officialRating: nil, genres: [], dateCreated: nil,
            people: [], userData: nil, seriesName: nil, seriesId: nil, seasonId: nil,
            seasonName: nil, indexNumber: nil, parentIndexNumber: nil, itemType: type,
            width: nil, height: nil, primaryBlurHash: nil, primaryImageAspectRatio: ratio
        )
    }

    /// Creates a model connected to a fake server, with movie / series / audiobook libraries.
    @MainActor
    func makeLibraryModel(server: MockHttpServer, tempDir: URL) -> AppModel {
        let session = SessionInfo(
            serverUrl: "http://127.0.0.1:\(server.port)", serverId: "srv-lib", userId: "user-lib", accessToken: "tok"
        )
        let model = AppModel()
        model.client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        model.libraries = [
            UserView(id: "lib-movies", name: "Films", collectionType: "movies", primaryBlurHash: nil),
            UserView(id: "lib-shows", name: "Series", collectionType: "tvshows", primaryBlurHash: nil),
            UserView(id: "lib-books", name: "Audiobooks", collectionType: "books", primaryBlurHash: nil)
        ]
        return model
    }

    func tinyMovie(_ id: String, name: String, genres: [String] = [], overview: String? = nil, people: [Person] = []) -> Movie {
        Movie(
            id: id, name: name, sortName: nil, productionYear: nil, premiereDate: nil,
            runTimeTicks: nil, container: nil, overview: overview, communityRating: nil,
            criticRating: nil, officialRating: nil, genres: genres, dateCreated: nil,
            people: people, userData: nil, seriesName: nil, seriesId: nil, seasonId: nil,
            seasonName: nil, indexNumber: nil, parentIndexNumber: nil, itemType: "Movie",
            width: nil, height: nil, primaryBlurHash: nil, primaryImageAspectRatio: nil
        )
    }
}
