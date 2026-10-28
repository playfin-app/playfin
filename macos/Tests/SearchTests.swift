import SwiftUI
import Network
import os
import XCTest
@testable import Playfin

/// Search, online and offline.
final class SearchTests: AppTestCase {
    func testSearchResultsAreGroupedByTypeInAFixedOrder() {
        func item(_ id: String, _ type: String?) -> Movie {
            var m = tinyMovie(id, name: id)
            m.itemType = type
            return m
        }
        let sections = SearchGrouping.sections(from: [
            item("a", "AudioBook"), item("m", "Movie"), item("s", "Series"), item("e", "Episode"),
            item("t", "MusicAlbum"), item("x", "Photo")
        ])
        XCTAssertEqual(sections.map(\.title), ["Movies", "Series", "Episodes", "Audiobooks", "Music", "Other"])
        XCTAssertEqual(sections.first { $0.title == "Audiobooks" }?.items.map(\.id), ["a"])
        XCTAssertTrue(SearchGrouping.sections(from: []).isEmpty)
    }

    func testOfflineSearchFallsBackToSavedMoviesByTitleGenreOrSummary() {
        let items = [
            tinyMovie("1", name: "Café Society", genres: ["Comedy"]),
            tinyMovie("2", name: "Other", genres: ["Drama"], overview: "a sad cafe story"),
            tinyMovie("3", name: "Nothing", genres: ["Drama"])
        ]
        XCTAssertEqual(MovieSearch.titleMatches(in: items, query: "cafe").map(\.id), ["1", "2"])
        XCTAssertTrue(MovieSearch.titleMatches(in: items, query: "  ").isEmpty)
    }

    @MainActor
    func testSearchAsksTheServerAcrossLibrariesAndFallsBackWhenOffline() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let server = try await MockHttpServer.start(handler: { request in
            lines.withLock { $0.append(request.components(separatedBy: "\r\n").first ?? "") }
            return (200, #"{"Items":[{"Id":"b1","Name":"Livre Alien","Type":"AudioBook"}]}"#)
        })
        defer { server.stop() }
        let model = makeLibraryModel(server: server, tempDir: tempDir)

        guard case .results(let found) = await model.search("alien") else { return XCTFail("results expected") }
        XCTAssertEqual(found.map(\.id), ["b1"])
        XCTAssertNotNil(model.movie(id: "b1"), "a result must be openable")
        XCTAssertTrue(lines.withLock { $0.contains { $0.contains("searchTerm=alien") && !$0.contains("parentId") } })

        // Server marked unreachable: no request, saved movies.
        model.isServerUnreachable = true
        model.movies = [tinyMovie("m1", name: "Alien")]
        let before = lines.withLock { $0.count }
        guard case .localOnly(let local) = await model.search("alien") else { return XCTFail("local fallback expected") }
        XCTAssertEqual(local.map(\.id), ["m1"])
        XCTAssertEqual(lines.withLock { $0.count }, before)
    }
}
