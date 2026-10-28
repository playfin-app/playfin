import SwiftUI
import Network
import os
import XCTest
@testable import Playfin

/// Libraries: loading, cache, sorting, paging and grid content.
final class LibraryTests: AppTestCase {
    @MainActor
    func testFolderChildrenAreFetchedAtFirstLevelOnly() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let requests = OSAllocatedUnfairLock(initialState: [String]())
        let server = try await MockHttpServer.start(handler: { request in
            requests.withLock { $0.append(request.components(separatedBy: "\r\n").first ?? "") }
            return (200, #"{"Items":[{"Id":"b1","Name":"Livre 1","Type":"AudioBook"}],"TotalRecordCount":1}"#)
        })
        defer { server.stop() }

        let model = makeLibraryModel(server: server, tempDir: tempDir)
        let children = await model.children(of: "author-1")

        XCTAssertEqual(children.map(\.id), ["b1"])
        let line = try XCTUnwrap(requests.withLock { $0.first })
        XCTAssertTrue(line.contains("parentId=author-1") && line.contains("recursive=false"), line)
        XCTAssertFalse(line.contains("includeItemTypes"))
        XCTAssertEqual(model.movie(id: "b1")?.isAudio, true)
    }

    @MainActor
    func testLibraryRequestsAskForTheRightItemTypes() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let requests = OSAllocatedUnfairLock(initialState: [String]())
        let server = try await MockHttpServer.start(handler: { request in
            requests.withLock { $0.append(request.components(separatedBy: "\r\n").first ?? "") }
            return (200, #"{"Items":[],"TotalRecordCount":0}"#)
        })
        defer { server.stop() }

        let model = makeLibraryModel(server: server, tempDir: tempDir)
        await model.loadLibraryItems(libraryId: "lib-movies")
        await model.loadLibraryItems(libraryId: "lib-shows")
        await model.loadLibraryItems(libraryId: "lib-books")

        let lines = requests.withLock { $0 }
        let movies = try XCTUnwrap(lines.first { $0.contains("parentId=lib-movies") })
        let shows = try XCTUnwrap(lines.first { $0.contains("parentId=lib-shows") })
        let books = try XCTUnwrap(lines.first { $0.contains("parentId=lib-books") })

        // Movies and series: a precise type, in recursive search (never the episodes).
        XCTAssertTrue(movies.contains("includeItemTypes=Movie") && movies.contains("recursive=true"))
        XCTAssertTrue(shows.contains("includeItemTypes=Series") && shows.contains("recursive=true"))
        // Other library: first level only, to see the items that group the others.
        XCTAssertFalse(books.contains("includeItemTypes"))
        XCTAssertTrue(books.contains("recursive=false"))
    }

    /// B1: the first library shows its cache even when it is already "selected", and offline.
    @MainActor
    func testFirstLibraryShowsItsCacheWhenOffline() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Unreachable server (closed port).
        let session = SessionInfo(serverUrl: "http://127.0.0.1:9", serverId: "srv-off", userId: "user-off", accessToken: "t")
        let client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        await client.storeLibraryItems(parentId: "lib-movies", items: [tinyMovie("a", name: "Avatar"), tinyMovie("b", name: "Brazil")])

        let model = AppModel()
        model.client = client
        model.libraries = [UserView(id: "lib-movies", name: "Films", collectionType: "movies", primaryBlurHash: nil)]
        model.selectedLibraryId = "lib-movies" // as loadLibraries does for the first library

        await model.loadLibraryItems(libraryId: "lib-movies")
        XCTAssertEqual(model.libraryItems.map(\.id), ["a", "b"])
        XCTAssertNotNil(model.movie(id: "a"), "cached items must be openable")
    }

    /// B2 + P2: "Refresh" keeps the chosen sort, and a recent list is not downloaded again.
    @MainActor
    func testRefreshKeepsSortAndFreshListIsNotReloaded() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let requests = OSAllocatedUnfairLock(initialState: [String]())
        let server = try await MockHttpServer.start(handler: { request in
            let line = request.components(separatedBy: "\r\n").first ?? ""
            requests.withLock { $0.append(line) }
            if line.contains("/UserViews") {
                return (200, #"{"Items":[{"Id":"lib-movies","Name":"Films","CollectionType":"movies"}],"TotalRecordCount":1}"#)
            }
            return (200, #"{"Items":[{"Id":"i-1","Name":"Film"}],"TotalRecordCount":1}"#)
        })
        defer { server.stop() }

        let model = makeLibraryModel(server: server, tempDir: tempDir)
        await model.loadLibraryItems(libraryId: "lib-movies", reset: true, sortBy: "DateCreated", sortOrder: "Descending")
        let afterFirst = requests.withLock { $0.filter { $0.contains("GET /Items?") && $0.contains("parentId=lib-movies") }.count }
        XCTAssertEqual(afterFirst, 1)

        // Back on the same list (same sort) shortly after: no extra request.
        await model.loadLibraryItems(libraryId: "lib-movies", reset: true, sortBy: "DateCreated", sortOrder: "Descending")
        XCTAssertEqual(requests.withLock { $0.filter { $0.contains("GET /Items?") && $0.contains("parentId=lib-movies") }.count }, 1)

        // Forced refresh: new request with the remembered sort, not the default one.
        await model.refresh()
        let libraryLines = requests.withLock { $0.filter { $0.contains("GET /Items?") && $0.contains("parentId=lib-movies") } }
        XCTAssertEqual(libraryLines.count, 2)
        XCTAssertTrue(libraryLines[1].contains("sortBy=DateCreated"), libraryLines[1])
    }

    /// Without a saved copy and without a server: an error message, not an "empty" library.
    @MainActor
    func testLibraryWithoutCopyAndWithoutServerReportsAnError() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let session = SessionInfo(serverUrl: "http://127.0.0.1:9", serverId: "srv-e", userId: "user-e", accessToken: "t")
        let model = AppModel()
        model.client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        model.libraries = [UserView(id: "lib-x", name: "X", collectionType: "movies", primaryBlurHash: nil)]

        await model.loadLibraryItems(libraryId: "lib-x")
        XCTAssertTrue(model.libraryItems.isEmpty)
        XCTAssertNotNil(model.libraryLoadError)
        XCTAssertFalse(model.isLoadingLibrary)

        // A new attempt clears the old error before reloading.
        await model.loadLibraryItems(libraryId: "lib-x", reset: true, force: true)
        XCTAssertNotNil(model.libraryLoadError)
    }

    @MainActor
    func testRememberKeepsCastAndIgnoresIdenticalItems() {
        let model = AppModel()
        let cast = [Person(id: "p1", name: "Ana", roleType: "Actor", role: nil)]
        model.remember([tinyMovie("m", name: "Film", people: cast)])
        // A list (without the cast) must not erase the detailed record already loaded.
        model.remember([tinyMovie("m", name: "Film")])
        XCTAssertEqual(model.movie(id: "m")?.people.count, 1)
        // Same actor name, different role: two distinct identifiers for SwiftUI.
        XCTAssertNotEqual(
            Person(id: nil, name: "Ana", roleType: nil, role: "A").castId,
            Person(id: nil, name: "Ana", roleType: nil, role: "B").castId
        )
    }

    func testGridContentIsFilteredSortedAndGroupedOnce() {
        let items = [
            tinyMovie("1", name: "Brazil", genres: ["Drama"]),
            tinyMovie("2", name: "Avatar", genres: ["Action", "Drama"], overview: "blue"),
            tinyMovie("3", name: "Alien", genres: ["Action"])
        ]
        let all = GridContentBuilder.build(items: items, query: GridQuery(localSort: .titleAsc))
        XCTAssertEqual(all.filtered.map(\.name), ["Alien", "Avatar", "Brazil"])
        XCTAssertEqual(all.sections.map(\.letter), ["A", "B"])
        XCTAssertEqual(all.activeLetters, ["A", "B"])
        XCTAssertEqual(all.genres.first { $0.genre == "Drama" }?.count, 2)

        let action = GridContentBuilder.build(items: items, query: GridQuery(genre: "Action"))
        XCTAssertEqual(action.filtered.map(\.id), ["2", "3"], "original order kept without local sort")

        let searched = GridContentBuilder.build(items: items, query: GridQuery(search: "blue"))
        XCTAssertEqual(searched.filtered.map(\.id), ["2"])
    }

    @MainActor
    func testWholeLibraryIsLoadedAndCached() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let total = 1200
        let server = try await MockHttpServer.start(handler: { request in
            let line = request.components(separatedBy: "\r\n").first ?? ""
            let start = line.components(separatedBy: "startIndex=").dropFirst().first
                .flatMap { Int($0.prefix { $0.isNumber }) } ?? 0
            let items = (start..<min(start + 500, total)).map { #"{"Id":"i-\#($0)","Name":"Film \#($0)"}"# }
            return (200, #"{"Items":[\#(items.joined(separator: ","))],"TotalRecordCount":\#(total)}"#)
        })
        defer { server.stop() }

        let model = makeLibraryModel(server: server, tempDir: tempDir)
        await model.loadLibraryItems(libraryId: "lib-movies")

        XCTAssertEqual(model.libraryItems.count, total, "the whole library is loaded, not just the first page")
        XCTAssertEqual(model.libraryItems.last?.id, "i-1199")
        XCTAssertFalse(model.isLoadingLibrary)
        XCTAssertFalse(model.isLoadingMoreLibraryItems)

        // The complete list is kept on disk for an immediate display the next time.
        let cached = await try XCTUnwrap(model.client).cachedLibraryItems(parentId: "lib-movies")
        XCTAssertEqual(cached.count, total)
    }

    @MainActor
    func testSlowResponseFromPreviousLibraryDoesNotOverwriteCurrentLibrary() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let server = try await MockHttpServer.start(handler: { request in
            if request.contains("parentId=lib-movies") {
                Thread.sleep(forTimeInterval: 0.6) // the movies answer late
                return (200, #"{"Items":[{"Id":"movie-1","Name":"A movie"}],"TotalRecordCount":1}"#)
            }
            return (200, #"{"Items":[{"Id":"show-1","Name":"A series"}],"TotalRecordCount":1}"#)
        })
        defer { server.stop() }

        let model = makeLibraryModel(server: server, tempDir: tempDir)
        let slowMovies = Task { await model.loadLibraryItems(libraryId: "lib-movies") }
        try await Task.sleep(nanoseconds: 150_000_000)
        await model.loadLibraryItems(libraryId: "lib-shows")
        await slowMovies.value

        XCTAssertEqual(model.selectedLibraryId, "lib-shows")
        XCTAssertEqual(model.libraryItems.map(\.id), ["show-1"])
        XCTAssertFalse(model.isLoadingLibrary)
    }
}

@MainActor
final class LibraryPreferencesTests: AppTestCase {
    func testSortAndFiltersAreRememberedPerLibrary() {
        XCTAssertEqual(LibraryPreferences.load(libraryId: "movies"), LibraryPreferences(), "title order by default")
        LibraryPreferences(sort: .dateAdded, watchFilter: .unwatched, genre: "Drama").save(libraryId: "movies")
        XCTAssertEqual(LibraryPreferences.load(libraryId: "movies"),
                       LibraryPreferences(sort: .dateAdded, watchFilter: .unwatched, genre: "Drama"))
        XCTAssertEqual(LibraryPreferences.load(libraryId: "series"), LibraryPreferences(), "each library has its own")

        LibraryPreferences(sort: .dateAdded, watchFilter: .unwatched, genre: nil).save(libraryId: "movies")
        XCTAssertNil(LibraryPreferences.load(libraryId: "movies").genre, "\"All genres\" is remembered too")
    }

    func testSmallLibrariesHaveNoLetterSections() {
        XCTAssertFalse(LibraryPreferences.showsLetterSections(sort: .titleAsc, search: "", genre: nil, itemCount: 19),
                       "19 series: one poster per letter otherwise")
        XCTAssertTrue(LibraryPreferences.showsLetterSections(sort: .titleAsc, search: "", genre: nil, itemCount: 301))
        XCTAssertFalse(LibraryPreferences.showsLetterSections(sort: .dateAdded, search: "", genre: nil, itemCount: 301))
        XCTAssertFalse(LibraryPreferences.showsLetterSections(sort: .titleAsc, search: "a", genre: nil, itemCount: 301))
    }
}
