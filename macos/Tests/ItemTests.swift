import SwiftUI
import Network
import os
import XCTest
@testable import Playfin

/// Watched state and image URLs of items.
final class ItemTests: AppTestCase {
    @MainActor
    func testToggleWatchedRollsBackWhenServerFails() async throws {
        let (model, movie, server, tempDir, _) = try await makeWatchedFixture(status: 500)
        defer { server.stop(); try? FileManager.default.removeItem(at: tempDir) }

        await model.toggleWatched(movie)

        XCTAssertFalse(model.movie(id: "m-1")?.isWatched ?? true, "the original state is restored")
        XCTAssertEqual(model.movies.first?.isWatched, false)
        XCTAssertEqual(model.resume.map(\.id), ["m-1"], "the movie comes back under \"Resume\"")
    }

    @MainActor
    func testToggleWatchedKeepsOptimisticStateOnSuccessAndUsesUserPlayedItems() async throws {
        let (model, movie, server, tempDir, requests) = try await makeWatchedFixture(status: 200)
        defer { server.stop(); try? FileManager.default.removeItem(at: tempDir) }

        await model.toggleWatched(movie)

        XCTAssertTrue(model.movie(id: "m-1")?.isWatched ?? false)
        XCTAssertTrue(model.resume.isEmpty)
        let lines = requests.withLock { $0 }
        XCTAssertEqual(lines.count, 1, "no full reload after the toggle")
        XCTAssertTrue(lines[0].hasPrefix("POST /UserPlayedItems/m-1?userId=user-w"), lines[0])
    }

    @MainActor
    func testToggleFavoriteUsesUserFavoriteItemsAndFillsTheHomeRow() async throws {
        let (model, movie, server, tempDir, requests) = try await makeWatchedFixture(status: 200)
        defer { server.stop(); try? FileManager.default.removeItem(at: tempDir) }

        await model.toggleFavorite(movie)

        XCTAssertTrue(model.movie(id: "m-1")?.isFavorite ?? false)
        XCTAssertEqual(model.favorites.map(\.id), ["m-1"])
        let lines = requests.withLock { $0 }
        XCTAssertTrue(lines[0].hasPrefix("POST /UserFavoriteItems/m-1?userId=user-w"), lines[0])

        // A page still showing the old state: no second copy in the row.
        await model.toggleFavorite(movie)
        await model.toggleFavorite(movie)
        XCTAssertEqual(model.favorites.map(\.id), ["m-1"])

        // Watched afterwards: the heart stays.
        await model.setWatched(try XCTUnwrap(model.movie(id: "m-1")), watched: true)
        XCTAssertTrue(model.movie(id: "m-1")?.isFavorite ?? false)
    }

    @MainActor
    func testToggleFavoriteRollsBackWhenServerFails() async throws {
        let (model, movie, server, tempDir, _) = try await makeWatchedFixture(status: 500)
        defer { server.stop(); try? FileManager.default.removeItem(at: tempDir) }

        await model.toggleFavorite(movie)

        XCTAssertFalse(model.movie(id: "m-1")?.isFavorite ?? true)
        XCTAssertTrue(model.favorites.isEmpty)
    }

    @MainActor
    func testToggleWatchedKeepsImageTagsAndBackdropHash() async throws {
        let (model, movie, server, tempDir, _) = try await makeWatchedFixture(status: 200)
        defer { server.stop(); try? FileManager.default.removeItem(at: tempDir) }
        var tagged = movie
        tagged.imageTags = [ImageTag(kind: "Primary", tag: "p1")]
        tagged.backdropBlurHash = "BACK"
        model.movies = [tagged]
        model.remember([tagged])

        await model.toggleWatched(tagged)

        let after = try XCTUnwrap(model.movie(id: "m-1"))
        XCTAssertEqual(after.imageTags.first?.tag, "p1")
        XCTAssertEqual(after.backdropBlurHash, "BACK")
    }

    @MainActor
    func testEpisodesUseTheirSeriesArtwork() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-lib-\(UUID().uuidString)")
        let session = SessionInfo(serverUrl: "http://127.0.0.1:9", serverId: "s", userId: "u", accessToken: "t")
        let model = AppModel()
        model.client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)

        func item(_ id: String, type: String, seriesId: String?) -> Movie {
            Movie(
                id: id, name: id, sortName: nil, productionYear: nil, premiereDate: nil,
                runTimeTicks: nil, container: nil, overview: nil, communityRating: nil,
                criticRating: nil, officialRating: nil, genres: [], dateCreated: nil,
                people: [], userData: nil, seriesName: nil, seriesId: seriesId, seasonId: nil,
                seasonName: nil, indexNumber: nil, parentIndexNumber: nil, itemType: type,
                width: nil, height: nil, primaryBlurHash: nil, primaryImageAspectRatio: nil
            )
        }

        let episode = item("ep-1", type: "Episode", seriesId: "series-9")
        XCTAssertTrue(try XCTUnwrap(model.imageURL(episode, .primary, height: 450)).absoluteString.contains("/Items/series-9/Images/Primary"))
        XCTAssertTrue(try XCTUnwrap(model.imageURL(episode, .backdrop, height: 360)).absoluteString.contains("/Items/series-9/Images/Backdrop"))

        let series = item("series-9", type: "Series", seriesId: "series-9")
        XCTAssertTrue(try XCTUnwrap(model.imageURL(series, .primary, height: 450)).absoluteString.contains("/Items/series-9/"))

        let movie = item("movie-3", type: "Movie", seriesId: nil)
        XCTAssertTrue(try XCTUnwrap(model.imageURL(movie, .primary, height: 450)).absoluteString.contains("/Items/movie-3/Images/Primary"))
    }

    @MainActor
    func testImageURLCarriesTheRightTag() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-tag-\(UUID().uuidString)")
        let session = SessionInfo(serverUrl: "http://127.0.0.1:9", serverId: "s", userId: "u", accessToken: "t")
        let model = AppModel()
        model.client = JellyfinClient.restore(info: session, cacheDir: tempDir.path)
        var episode = Movie(
            id: "ep-1", name: "ep", sortName: nil, productionYear: nil, premiereDate: nil,
            runTimeTicks: nil, container: nil, overview: nil, communityRating: nil,
            criticRating: nil, officialRating: nil, genres: [], dateCreated: nil,
            people: [], userData: nil, seriesName: nil, seriesId: "series-9", seasonId: nil,
            seasonName: nil, indexNumber: nil, parentIndexNumber: nil, itemType: "Episode",
            width: nil, height: nil, primaryBlurHash: nil, primaryImageAspectRatio: nil,
            imageTags: [ImageTag(kind: "Primary", tag: "own"), ImageTag(kind: "Logo", tag: "logo1")],
            backdropImageTags: ["ownbd"], seriesPrimaryImageTag: "serie", parentBackdropImageTags: ["parentbd"]
        )
        // An episode shows the poster and background of its series: we use their tags.
        XCTAssertTrue(try XCTUnwrap(model.imageURL(episode, .primary, height: 450)).absoluteString.hasSuffix("&tag=serie"))
        XCTAssertTrue(try XCTUnwrap(model.imageURL(episode, .backdrop, height: 360)).absoluteString.hasSuffix("&tag=parentbd"))
        XCTAssertTrue(try XCTUnwrap(model.imageURL(episode, .logo, height: 100)).absoluteString.hasSuffix("&tag=logo1"))
        episode.seriesId = nil
        XCTAssertTrue(try XCTUnwrap(model.imageURL(episode, .primary, height: 450)).absoluteString.hasSuffix("&tag=own"))
        XCTAssertTrue(try XCTUnwrap(model.imageURL(episode, .backdrop, height: 360)).absoluteString.hasSuffix("&tag=ownbd"))
    }

    func testRecentlyAddedEpisodesAndSeasonsOpenTheirSeries() {
        func item(_ type: String, seriesId: String?) -> Movie {
            Movie(
                id: "item-1", name: "x", sortName: nil, productionYear: nil, premiereDate: nil,
                runTimeTicks: nil, container: nil, overview: nil, communityRating: nil,
                criticRating: nil, officialRating: nil, genres: [], dateCreated: nil,
                people: [], userData: nil, seriesName: nil, seriesId: seriesId, seasonId: nil,
                seasonName: nil, indexNumber: nil, parentIndexNumber: nil, itemType: type,
                width: nil, height: nil, primaryBlurHash: nil, primaryImageAspectRatio: nil,
                imageTags: [], backdropImageTags: [], seriesPrimaryImageTag: nil, parentBackdropImageTags: []
            )
        }
        XCTAssertEqual(item("Episode", seriesId: "series-9").seriesPageId, "series-9")
        XCTAssertEqual(item("Season", seriesId: "series-9").seriesPageId, "series-9")
        XCTAssertEqual(item("Series", seriesId: "series-9").seriesPageId, "item-1")
        XCTAssertEqual(item("Movie", seriesId: nil).seriesPageId, "item-1")
        XCTAssertEqual(item("Episode", seriesId: "").seriesPageId, "item-1", "no series known: the item itself")
    }
}

/// "Mark as unwatched" on a started item: it starts again from the beginning.
final class MarkUnwatchedTests: AppTestCase {
    @MainActor
    func testAStartedItemCanBeMarkedUnwatchedAndForgetsItsPosition() async throws {
        let (model, movie, server, tempDir, requests) = try await makeWatchedFixture(status: 200)
        defer { server.stop(); try? FileManager.default.removeItem(at: tempDir) }
        XCTAssertFalse(movie.isWatched)
        XCTAssertTrue(movie.canMarkUnwatched, "10 % watched: the option is offered")

        await model.setWatched(movie, watched: false)

        let after = try XCTUnwrap(model.movie(id: "m-1"))
        XCTAssertEqual(after.userData?.playbackPositionTicks, 0)
        XCTAssertEqual(after.resumeSeconds, 0, "next time: from the beginning")
        XCTAssertFalse(after.canMarkUnwatched)
        XCTAssertTrue(model.resume.isEmpty, "no longer under \"Continue watching\"")
        let lines = requests.withLock { $0 }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("DELETE /UserPlayedItems/m-1?userId=user-w"), lines[0])
    }

    @MainActor
    func testMarkUnwatchedRollsBackWhenServerFails() async throws {
        let (model, movie, server, tempDir, _) = try await makeWatchedFixture(status: 500)
        defer { server.stop(); try? FileManager.default.removeItem(at: tempDir) }

        await model.setWatched(movie, watched: false)

        XCTAssertEqual(model.movie(id: "m-1")?.userData?.playbackPositionTicks, 600_000_000, "the position comes back")
        XCTAssertEqual(model.resume.map(\.id), ["m-1"])
    }

    func testOptionOnlyForWatchedOrStartedItems() {
        var item = makeItem(id: "a", type: "Movie")
        XCTAssertFalse(item.canMarkUnwatched, "never started")
        item.userData = UserData(playbackPositionTicks: 0, played: true, playedPercentage: nil)
        XCTAssertTrue(item.canMarkUnwatched)
        item.userData = UserData(playbackPositionTicks: 0, played: false, playedPercentage: 40)
        XCTAssertTrue(item.canMarkUnwatched, "a series partly watched")
    }
}
