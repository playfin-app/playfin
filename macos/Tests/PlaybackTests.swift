import SwiftUI
import Network
import os
import XCTest
@testable import Playfin

/// What gets played, from the server or from disk.
final class PlaybackTests: AppTestCase {
    @MainActor
    func testAudioBooksStreamFromTheAudioEndpoint() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let server = try await MockHttpServer.start(statusCode: 200, responseBody: "{}")
        defer { server.stop() }

        let model = makeLibraryModel(server: server, tempDir: tempDir)
        model.play(makeItem(id: "book-1", type: "AudioBook"))
        XCTAssertTrue(try XCTUnwrap(model.playback).url.contains("/Audio/book-1/stream"))

        model.playback = nil
        model.play(makeItem(id: "film-1", type: "Movie"))
        XCTAssertTrue(try XCTUnwrap(model.playback).url.contains("/Videos/film-1/stream"))
    }

    func testPlaybackChooserPicksInProgressThenFirstUnwatchedThenFirst() {
        func ep(_ id: String, played: Bool, position: Int64 = 0) -> Movie {
            var m = tinyMovie(id, name: id)
            m.userData = UserData(playbackPositionTicks: position, played: played, playedPercentage: nil)
            return m
        }
        let list = [ep("e1", played: true), ep("e2", played: false), ep("e3", played: false, position: 600_000_000)]
        XCTAssertEqual(PlaybackChooser.next(from: list)?.id, "e3", "the episode in progress first")
        XCTAssertEqual(PlaybackChooser.next(from: Array(list.prefix(2)))?.id, "e2", "otherwise the first unwatched")
        XCTAssertEqual(PlaybackChooser.next(from: [ep("e1", played: true)])?.id, "e1", "everything watched: start over")
        XCTAssertNil(PlaybackChooser.next(from: []))
    }

    /// A single "play" behaviour for all types: series, folder/author, audiobook, movie.
    @MainActor
    func testPlayWorksForSeriesFoldersAudiobooksAndMovies() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-play-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let server = try await MockHttpServer.start(handler: { request in
            let line = request.components(separatedBy: "\r\n").first ?? ""
            if line.contains("/Shows/serie-1/Episodes") {
                return (200, #"{"Items":[{"Id":"ep-1","Name":"E1","Type":"Episode","UserData":{"PlaybackPositionTicks":0,"Played":true}},{"Id":"ep-2","Name":"E2","Type":"Episode","UserData":{"PlaybackPositionTicks":0,"Played":false}}],"TotalRecordCount":2}"#)
            }
            if line.contains("parentId=author-1") {
                return (200, #"{"Items":[{"Id":"book-1","Name":"Livre","Type":"AudioBook"}],"TotalRecordCount":1}"#)
            }
            return (200, #"{"Items":[],"TotalRecordCount":0}"#)
        })
        defer { server.stop() }
        let model = makeLibraryModel(server: server, tempDir: tempDir)

        func item(_ id: String, _ type: String) -> Movie {
            var m = tinyMovie(id, name: id)
            m.itemType = type
            return m
        }
        func waitForPlayback(_ id: String) async {
            for _ in 0..<100 where model.playback?.movie.id != id { try? await Task.sleep(nanoseconds: 50_000_000) }
        }

        model.play(item("serie-1", "Series"))
        await waitForPlayback("ep-2")
        XCTAssertEqual(model.playback?.movie.id, "ep-2", "the series resumes at the first unwatched episode")

        model.playback = nil
        model.play(item("author-1", "Folder"))
        await waitForPlayback("book-1")
        XCTAssertEqual(model.playback?.movie.id, "book-1", "a folder or an author plays its first book")
        XCTAssertTrue(model.playback?.url.contains("/Audio/") ?? false, "livre audio : flux audio")

        model.playback = nil
        model.play(item("movie-1", "Movie"))
        XCTAssertEqual(model.playback?.movie.id, "movie-1", "a movie starts right away")

        model.playback = nil
        model.play(item("empty-1", "Folder"))
        for _ in 0..<100 where model.offlineAlertMessage == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNil(model.playback)
        XCTAssertNotNil(model.offlineAlertMessage, "empty folder: a clear message, not silence")
    }

    /// End-to-end download with a fake server (without byte ranges: one connection), then playback
    /// from disk, including offline, and playback report kept for later.
    @MainActor
    func testDownloadedItemsPlayFromDiskEvenOffline() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let server = try await MockHttpServer.start(handler: { request in
            let line = request.components(separatedBy: "\r\n").first ?? ""
            if line.contains("/Download") { return (200, String(repeating: "x", count: 4096)) }
            if line.contains("/Users/Me") { return (200, #"{"Policy":{"EnableContentDownloading":true}}"#) }
            return (404, "")
        })
        defer { server.stop() }
        let model = makeLibraryModel(server: server, tempDir: tempDir)
        let session = try XCTUnwrap(model.client?.sessionInfo())
        model.downloads.open(client: try XCTUnwrap(model.client), session: session, serverName: "Lounge", settings: defaultSettings())
        defer { model.downloads.close() }

        var movie = tinyMovie("dl-1", name: "Downloaded movie")
        movie.container = "mp4"
        model.remember([movie])
        model.downloads.download([movie])
        for _ in 0..<200 where !model.downloads.downloadedIds.contains("dl-1") {
            try await Task.sleep(nanoseconds: 25_000_000)
            model.downloads.refresh()
        }
        XCTAssertTrue(model.downloads.downloadedIds.contains("dl-1"), "\(model.downloads.items)")
        let path = try XCTUnwrap(model.downloads.localFile(for: "dl-1"))
        XCTAssertTrue(path.hasSuffix("Lounge/Movies/Downloaded movie.mp4"), path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)).count, 4096)

        // Offline: the downloaded item still plays, from the file.
        model.isServerUnreachable = true
        model.play(movie)
        XCTAssertEqual(model.playback?.url, path)
        XCTAssertEqual(model.playback?.httpHeader, "")

        // The stop report made offline is kept for when the server is back.
        model.reportStopped(movie, seconds: 30)
        XCTAssertEqual(model.downloads.manager?.pendingReportCount(), 1)

        // An item that is not downloaded does not play offline: clear message.
        model.playback = nil
        model.play(tinyMovie("other", name: "Other"))
        XCTAssertNil(model.playback)
        XCTAssertNotNil(model.offlineAlertMessage)

        model.downloads.remove("dl-1")
        for _ in 0..<100 where FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "deleting the download erases the file")
    }
}
