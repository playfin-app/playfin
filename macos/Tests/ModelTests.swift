import SwiftUI
import Network
import os
import XCTest
@testable import Playfin

/// Data models and small pure helpers.
final class ModelTests: AppTestCase {
    func testCoreVersion() {
        let version = coreVersion()
        XCTAssertFalse(version.isEmpty, "Core version should not be empty")
        XCTAssertTrue(version.contains("."), "Core version should follow semver (e.g. 0.1.0)")
    }

    @MainActor
    func testAppModelInitialState() {
        let model = AppModel()
        XCTAssertEqual(model.screen, .loading)
        XCTAssertEqual(model.selectedSection, .home)
        XCTAssertEqual(model.rustCoreVersion, coreVersion())
    }

    /// Choosing the section already shown must still ask for its first page (sidebar click on "Home").
    @MainActor
    func testShowSectionRequestsFirstPageEvenWhenAlreadySelected() {
        let model = AppModel()
        model.showSection(.home)
        XCTAssertEqual(model.selectedSection, .home)
        XCTAssertEqual(model.sectionRootRequests, 1)

        model.showSection(.home)
        XCTAssertEqual(model.sectionRootRequests, 2)

        model.showSection(.favorites)
        XCTAssertEqual(model.selectedSection, .favorites)
        XCTAssertEqual(model.sectionRootRequests, 3)

        model.requestGoBack()
        XCTAssertEqual(model.goBackRequests, 1)
    }

    private func featuredCandidate(_ id: String, watched: Bool = false, backdrop: Bool = true) -> Movie {
        Movie(
            id: id, name: id, sortName: nil, productionYear: nil, premiereDate: nil,
            runTimeTicks: nil, container: nil, overview: nil, communityRating: nil,
            criticRating: nil, officialRating: nil, genres: [], dateCreated: nil,
            people: [], userData: UserData(playbackPositionTicks: 0, played: watched, playedPercentage: nil, isFavorite: false),
            seriesName: nil, seriesId: nil, seasonId: nil,
            seasonName: nil, indexNumber: nil, parentIndexNumber: nil, itemType: "Movie",
            width: nil, height: nil, primaryBlurHash: nil, primaryImageAspectRatio: nil,
            backdropImageTags: backdrop ? ["tag"] : []
        )
    }

    /// Banner titles: with a background image, not in progress, unwatched first, five at most, each once.
    @MainActor
    func testFeaturedTitlesAreUnwatchedWithABackgroundAndNotInProgress() {
        let candidates = [
            featuredCandidate("watched", watched: true),
            featuredCandidate("noBackdrop", backdrop: false),
            featuredCandidate("inProgress"),
            featuredCandidate("a"), featuredCandidate("a"),
            featuredCandidate("b"), featuredCandidate("c"), featuredCandidate("d"), featuredCandidate("e"),
            featuredCandidate("f")
        ]
        let picked = AppModel.pickFeatured(from: candidates, excluding: ["inProgress"])
        XCTAssertEqual(picked.map(\.id), ["a", "b", "c", "d", "e"])

        // A small library: the watched titles complete the banner.
        let few = AppModel.pickFeatured(from: [featuredCandidate("watched", watched: true), featuredCandidate("a")], excluding: [])
        XCTAssertEqual(few.map(\.id), ["a", "watched"])
    }

    /// The same titles come back for 30 minutes, then a new choice is made.
    func testFeaturedChoiceLastsThirtyMinutes() {
        let now = Date()
        XCTAssertTrue(AppModel.FeaturedChoice(ids: ["a"], chosenAt: now.addingTimeInterval(-29 * 60)).isFresh(at: now))
        XCTAssertFalse(AppModel.FeaturedChoice(ids: ["a"], chosenAt: now.addingTimeInterval(-31 * 60)).isFresh(at: now))
        // A date in the future (clock changed): renewed.
        XCTAssertFalse(AppModel.FeaturedChoice(ids: ["a"], chosenAt: now.addingTimeInterval(60)).isFresh(at: now))
    }

    /// Without a server, the banner shows the titles in progress (the random choice needs the server).
    @MainActor
    func testBannerFallsBackToTitlesInProgressWithoutAChoice() {
        let model = AppModel()
        model.resume = [featuredCandidate("resume")]
        XCTAssertEqual(model.heroMovies.map(\.id), ["resume"])
        model.featured = [featuredCandidate("random")]
        XCTAssertEqual(model.heroMovies.map(\.id), ["random"])
    }

    /// The pages get the toolbar and sidebar margins from the main view (see `LibraryView.pageStack`).
    @MainActor
    func testPageMarginsAreTheGapBetweenTheUsableAreaAndTheColumn() {
        let full = CGRect(x: 0, y: 0, width: 1512, height: 861)
        let safe = CGRect(x: 238, y: 52, width: 1274, height: 809)
        let margins = LibraryView.margins(of: safe, in: full)
        XCTAssertEqual(margins.top, 52)
        XCTAssertEqual(margins.leading, 238)
        XCTAssertEqual(margins.bottom, 0)
        XCTAssertEqual(margins.trailing, 0)
    }

    func testServerAddressModel() {
        let localAddr = ServerAddress(url: "http://192.168.1.10:8096", label: "Home", priority: 1, isLocal: true)
        XCTAssertEqual(localAddr.url, "http://192.168.1.10:8096")
        XCTAssertEqual(localAddr.label, "Home")
        XCTAssertTrue(localAddr.isLocal)
        XCTAssertEqual(localAddr.priority, 1)

        let remoteAddr = ServerAddress(url: "https://jellyfin.example.com", label: "Remote", priority: 2, isLocal: false)
        XCTAssertFalse(remoteAddr.isLocal)
        XCTAssertEqual(remoteAddr.priority, 2)
    }

    func testServerProfileModel() {
        let addr = ServerAddress(url: "http://localhost:8096", label: "Local", priority: 1, isLocal: true)
        let profile = ServerProfile(
            serverId: "srv-123",
            serverName: "MyServer",
            userId: "usr-456",
            userName: "Alice",
            userAvatarTag: nil,
            addresses: [addr],
            isPrimary: true
        )
        XCTAssertEqual(profile.serverId, "srv-123")
        XCTAssertEqual(profile.userName, "Alice")
        XCTAssertTrue(profile.isPrimary)
        XCTAssertEqual(profile.addresses.count, 1)
    }

    func testSessionInfoModelWithServerId() {
        let session = SessionInfo(
            serverUrl: "http://192.168.1.100:8096",
            serverId: "server-uuid-1234",
            userId: "user-5678",
            accessToken: "secret-token"
        )
        XCTAssertEqual(session.serverUrl, "http://192.168.1.100:8096")
        XCTAssertEqual(session.serverId, "server-uuid-1234")
        XCTAssertEqual(session.userId, "user-5678")
        XCTAssertEqual(session.accessToken, "secret-token")
    }

    func testHomeModelWithNextUp() {
        let episode = Movie(
            id: "ep-1",
            name: "Pilot",
            sortName: nil,
            productionYear: 2023,
            premiereDate: "2023-01-15",
            runTimeTicks: 36_000_000_000,
            container: "mkv",
            overview: "Episode 1 overview",
            communityRating: 8.5,
            criticRating: nil,
            officialRating: "TV-MA",
            genres: ["Drama"],
            dateCreated: nil,
            people: [],
            userData: nil,
            seriesName: "Super Series",
            seriesId: "series-1",
            seasonId: "season-1",
            seasonName: "Season 1",
            indexNumber: 1,
            parentIndexNumber: 1,
            itemType: "Episode",
            width: 1920,
            height: 1080,
            primaryBlurHash: nil,
            primaryImageAspectRatio: nil
        )
        let home = Home(resume: [], nextUp: [episode], latest: [])
        XCTAssertEqual(home.nextUp.count, 1)
        XCTAssertEqual(home.nextUp.first?.name, "Pilot")
        XCTAssertEqual(home.nextUp.first?.displayTitle, "Super Series")
        XCTAssertEqual(home.nextUp.first?.episodeSubtitle, "S1:E1 · Pilot")
    }

    func testMovieDisplayTitleAndEpisodeSubtitle() {
        let movie = Movie(
            id: "mov-1",
            name: "Inception",
            sortName: nil,
            productionYear: 2010,
            premiereDate: "2010-07-16",
            runTimeTicks: 88_800_000_000,
            container: "mkv",
            overview: "A thief who steals corporate secrets...",
            communityRating: 8.8,
            criticRating: nil,
            officialRating: "PG-13",
            genres: ["Action", "Sci-Fi"],
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
            width: 3840,
            height: 2160,
            primaryBlurHash: nil,
            primaryImageAspectRatio: nil
        )
        XCTAssertEqual(movie.displayTitle, "Inception")
        XCTAssertNil(movie.episodeSubtitle)
    }

    func testQuickConnectStateModel() {
        let qc = QuickConnectState(code: "891234", secret: "sec-test-secret", authenticated: false)
        XCTAssertEqual(qc.code, "891234")
        XCTAssertEqual(qc.secret, "sec-test-secret")
        XCTAssertFalse(qc.authenticated)
    }

    func testNormalizeURL() {
        XCTAssertEqual(AppModel.normalizeURL("192.168.1.50:8096"), "http://192.168.1.50:8096")
        XCTAssertEqual(AppModel.normalizeURL("http://192.168.1.50:8096/"), "http://192.168.1.50:8096")
        XCTAssertEqual(AppModel.normalizeURL("HTTP://192.168.1.50:8096"), "http://192.168.1.50:8096")
        XCTAssertEqual(AppModel.normalizeURL("https://jelly.example.com/"), "https://jelly.example.com")
        XCTAssertEqual(AppModel.normalizeURL("HTTPS://jelly.example.com/"), "https://jelly.example.com")
        XCTAssertEqual(AppModel.normalizeURL("   https://jelly.example.com///  "), "https://jelly.example.com")
    }

    func testTokioRuntimeIntegrationForTopLevelAsyncFunctions() async {
        // Calls validateServer with a dummy address.
        // If the Tokio runtime were not configured on the UniFFI export,
        // this would raise a panic "there is no reactor running".
        do {
            _ = try await validateServer(url: "http://127.0.0.1:1")
            XCTFail("Should fail with network/unreachable error")
        } catch {
            let desc = error.localizedDescription
            XCTAssertFalse(
                desc.contains("there is no reactor running"),
                "Must run in a Tokio runtime without panicking: \(desc)"
            )
        }

        // Also tests discoverServers with a short timeout
        let servers = try? await discoverServers(timeoutMs: 50)
        XCTAssertNotNil(servers)

        // Tests selectBestAddress with a dummy address
        let dummyAddr = ServerAddress(url: "http://127.0.0.1:1", label: "Local", priority: 1, isLocal: true)
        do {
            _ = try await selectBestAddress(addresses: [dummyAddr], expectedServerId: "srv-dummy")
            XCTFail("Should fail with unreachable error")
        } catch {
            let desc = error.localizedDescription
            XCTAssertFalse(
                desc.contains("there is no reactor running"),
                "Must run in a Tokio runtime without panicking: \(desc)"
            )
        }
    }

    @MainActor
    func testPlayerControllerStateAndVolumeClamping() {
        let controller = PlayerController()
        XCTAssertEqual(controller.volume, 100)
        XCTAssertFalse(controller.isPaused)

        // Volume clamping between 0 and 100
        controller.adjustVolume(by: 20)
        XCTAssertEqual(controller.volume, 100)
        controller.adjustVolume(by: -150)
        XCTAssertEqual(controller.volume, 0)
        controller.adjustVolume(by: 45)
        XCTAssertEqual(controller.volume, 45)

        // Scrubbing and state update
        controller.update(
            position: 120.0,
            duration: 3600.0,
            isPaused: false,
            volume: 45.0,
            isMuted: false,
            speed: 1.0,
            audioTracks: [],
            subtitleTracks: [],
            selectedAudioId: nil,
            selectedSubtitleId: nil
        )
        XCTAssertEqual(controller.currentTime, 120.0)
        XCTAssertEqual(controller.duration, 3600.0)

        controller.isScrubbing = true
        controller.scrubTime = 500.0
        // When isScrubbing is active, currentTime must not overwrite scrubTime
        controller.update(
            position: 125.0,
            duration: 3600.0,
            isPaused: false,
            volume: 45.0,
            isMuted: false,
            speed: 1.0,
            audioTracks: [],
            subtitleTracks: [],
            selectedAudioId: nil,
            selectedSubtitleId: nil
        )
        XCTAssertEqual(controller.currentTime, 120.0)
        XCTAssertEqual(controller.scrubTime, 500.0)
    }

    func testMovieResolutionBadge() {
        func makeMovie(w: Int32?, h: Int32?) -> Movie {
            Movie(
                id: "test", name: "Test", sortName: nil, productionYear: nil, premiereDate: nil,
                runTimeTicks: nil, container: "mkv", overview: nil, communityRating: nil,
                criticRating: nil, officialRating: nil, genres: [], dateCreated: nil,
                people: [], userData: nil, seriesName: nil, seriesId: nil, seasonId: nil,
                seasonName: nil, indexNumber: nil, parentIndexNumber: nil, itemType: "Movie",
                width: w, height: h, primaryBlurHash: nil, primaryImageAspectRatio: nil
            )
        }

        XCTAssertEqual(makeMovie(w: 3840, h: 2160).resolutionBadge, "4K UHD")
        XCTAssertEqual(makeMovie(w: 2560, h: 1440).resolutionBadge, "1440p QHD")
        XCTAssertEqual(makeMovie(w: 1920, h: 1080).resolutionBadge, "1080p FHD")
        XCTAssertEqual(makeMovie(w: 1280, h: 720).resolutionBadge, "720p HD")
        XCTAssertEqual(makeMovie(w: 854, h: 480).resolutionBadge, "480p")
        XCTAssertNil(makeMovie(w: nil, h: nil).resolutionBadge)
    }

    func testSeriesAndEpisodeProperties() {
        let series = Movie(
            id: "series-100", name: "Breaking Bad", sortName: "Breaking Bad", productionYear: 2008,
            premiereDate: "2008-01-20", runTimeTicks: nil, container: nil, overview: "A chemistry teacher...",
            communityRating: 9.5, criticRating: 96.0, officialRating: "TV-MA", genres: ["Crime", "Drama"],
            dateCreated: nil, people: [], userData: nil, seriesName: nil, seriesId: nil,
            seasonId: nil, seasonName: nil, indexNumber: nil, parentIndexNumber: nil, itemType: "Series",
            width: nil, height: nil, primaryBlurHash: nil, primaryImageAspectRatio: 0.67
        )
        XCTAssertTrue(series.isSeries)
        XCTAssertNil(series.durationMinutes)

        let episode = Movie(
            id: "ep-101", name: "Pilot", sortName: "Pilot", productionYear: 2008,
            premiereDate: "2008-01-20", runTimeTicks: 3_480_000_000, container: "mkv",
            overview: nil, communityRating: 9.0, criticRating: nil, officialRating: "TV-MA",
            genres: [], dateCreated: nil, people: [], userData: nil, seriesName: "Breaking Bad",
            seriesId: "series-100", seasonId: "season-1", seasonName: "Season 1",
            indexNumber: 1, parentIndexNumber: 1, itemType: "Episode", width: 1920, height: 1080,
            primaryBlurHash: nil, primaryImageAspectRatio: 1.77
        )
        XCTAssertFalse(episode.isSeries)
        XCTAssertEqual(episode.durationMinutes, 5) // 3480000000 ticks = 348 s = 5.8 min -> 5 min
    }

    func testUserViewAndLibraryPageModels() {
        let view = UserView(id: "lib-movies", name: "Films", collectionType: "movies", primaryBlurHash: "LEHV6nWB")
        XCTAssertEqual(view.id, "lib-movies")
        XCTAssertEqual(view.name, "Films")
        XCTAssertEqual(view.collectionType, "movies")
        XCTAssertEqual(view.primaryBlurHash, "LEHV6nWB")

        let page = LibraryPage(items: [], totalRecordCount: 1482, startIndex: 0)
        XCTAssertEqual(page.totalRecordCount, 1482)
        XCTAssertEqual(page.startIndex, 0)
        XCTAssertTrue(page.items.isEmpty)
    }

    @MainActor
    func testAppModelLibraryState() {
        let model = AppModel()
        XCTAssertTrue(model.libraries.isEmpty)
        XCTAssertNil(model.selectedLibraryId)
        XCTAssertTrue(model.libraryItems.isEmpty)
        XCTAssertEqual(model.libraryTotalCount, 0)
        XCTAssertFalse(model.isLoadingLibrary)
        XCTAssertFalse(model.isLoadingMoreLibraryItems)

        let lib1 = UserView(id: "lib-1", name: "Films", collectionType: "movies", primaryBlurHash: nil)
        let lib2 = UserView(id: "lib-2", name: "Series", collectionType: "tvshows", primaryBlurHash: nil)
        model.libraries = [lib1, lib2]
        model.selectedLibraryId = lib1.id

        XCTAssertEqual(model.currentLibrary?.id, "lib-1")
        XCTAssertEqual(model.currentLibrary?.name, "Films")
    }

    func testSortOptionsMapToJellyfinParameters() {
        XCTAssertEqual(MovieSortOption.titleAsc.serverParameters.sortBy, "SortName")
        XCTAssertEqual(MovieSortOption.titleAsc.serverParameters.sortOrder, "Ascending")
        XCTAssertEqual(MovieSortOption.dateAdded.serverParameters.sortBy, "DateCreated")
        XCTAssertEqual(MovieSortOption.dateAdded.serverParameters.sortOrder, "Descending")
        XCTAssertEqual(MovieSortOption.yearAsc.serverParameters.sortBy, "PremiereDate")
        XCTAssertEqual(MovieSortOption.yearAsc.serverParameters.sortOrder, "Ascending")
    }

    func testCardSizesGrowAndAreRemembered() {
        let ranges = CardSize.allCases.map(\.columnRange)
        XCTAssertEqual(ranges.map(\.min), ranges.map(\.min).sorted())
        XCTAssertLessThan(CardSize.small.columnRange.min, CardSize.large.columnRange.min)
        XCTAssertEqual(CardSize(rawValue: CardSize.large.rawValue), .large)
    }

    func testTicksAreClampedToValidValues() {
        XCTAssertEqual(ticks(2), 20_000_000)
        XCTAssertEqual(ticks(-5), 0)
        XCTAssertEqual(ticks(.nan), 0)
        XCTAssertGreaterThan(ticks(.infinity), 0)
    }

    func testItemTypeClassificationForAudioAndFolders() {
        XCTAssertTrue(makeItem(type: "AudioBook").isAudio)
        XCTAssertFalse(makeItem(type: "AudioBook").isContainer)
        for type in ["Folder", "MusicAlbum", "BoxSet", "CollectionFolder"] {
            XCTAssertTrue(makeItem(type: type).isContainer, type)
            XCTAssertFalse(makeItem(type: type).isAudio, type)
        }
        XCTAssertFalse(makeItem(type: "Movie").isAudio || makeItem(type: "Movie").isContainer)
        XCTAssertFalse(makeItem(type: nil).isContainer)

        // Covers: 2:3 poster for movies, square for audio, ratio from the server if known.
        XCTAssertEqual(makeItem(type: "Movie", ratio: 1.0).cardAspectRatio, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(makeItem(type: "AudioBook").cardAspectRatio, 1.0, accuracy: 0.001)
        XCTAssertEqual(makeItem(type: "Folder", ratio: 0.8).cardAspectRatio, 0.8, accuracy: 0.001)
        XCTAssertEqual(makeItem(type: "Folder", ratio: 9.0).cardAspectRatio, 1.8, accuracy: 0.001, "bounded ratio")
    }

    func testAGridOrRowUsesItsMostFrequentCardShape() {
        let mixed = [makeItem(type: "AudioBook"), makeItem(type: "Movie"), makeItem(type: "AudioBook")]
        XCTAssertEqual(Movie.commonCardAspectRatio(of: mixed), 1.0, accuracy: 0.001)
        XCTAssertEqual(Movie.commonCardAspectRatio(of: []), 2.0 / 3.0, accuracy: 0.001, "2:3 by default")
        let tie = [makeItem(type: "Movie"), makeItem(type: "AudioBook")]
        XCTAssertEqual(Movie.commonCardAspectRatio(of: tie), 2.0 / 3.0, accuracy: 0.001, "tie: the first shape seen")
    }

    func testDurationsAreWrittenLikePlex() {
        XCTAssertEqual(Movie.durationText(minutes: 86), "1 hr 26 min")
        XCTAssertEqual(Movie.durationText(minutes: 120), "2 hr")
        XCTAssertEqual(Movie.durationText(minutes: 45), "45 min")
        XCTAssertNil(Movie.durationText(minutes: 0))
    }
}
