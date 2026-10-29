import Foundation
import os

/// Libraries, their items, seasons, episodes, the movie list and refreshing.
extension AppModel {

    /// Loads the libraries configured on the Jellyfin server (Movies, Series, Cartoons...).
    func loadLibraries(_ client: JellyfinClient? = nil) async {
        guard let client = client ?? self.client else { return }
        if libraries.isEmpty {
            let cached = await client.cachedUserViews()
            if !cached.isEmpty && libraries.isEmpty {
                self.libraries = cached
                if selectedLibraryId == nil {
                    selectedLibraryId = cached.first?.id
                }
            }
        }
        do {
            let fresh = try await client.userViews()
            self.libraries = fresh
            if selectedLibraryId == nil || !fresh.contains(where: { $0.id == selectedLibraryId }) {
                selectedLibraryId = fresh.first?.id
            }
        } catch {
            // offline mode: keep the cached libraries
        }
        await loadLatestByLibrary(client)
        await loadFavorites(client)
    }

    /// "Favourites" row: the copy first, then the server.
    func loadFavorites(_ client: JellyfinClient) async {
        if favorites.isEmpty {
            let cached = await client.cachedFavorites()
            if self.client === client, !cached.isEmpty {
                remember(cached)
                favorites = cached
            }
        }
        guard let fresh = try? await client.favorites(), self.client === client else { return }
        remember(fresh)
        favorites = fresh
    }

    /// One "Recently added" row per library: the copy first, then the server (in parallel).
    func loadLatestByLibrary(_ client: JellyfinClient) async {
        let views = Array(libraries.prefix(8))
        guard !views.isEmpty else { return }
        if latestByLibrary.isEmpty {
            var cached: [LibraryLatest] = []
            for view in views {
                let items = await client.cachedLatestInLibrary(parentId: view.id)
                if !items.isEmpty { cached.append(LibraryLatest(library: view, items: items)) }
            }
            if self.client === client, !cached.isEmpty {
                remember(cached.flatMap(\.items))
                latestByLibrary = cached
            }
        }
        let fresh = await withTaskGroup(of: (Int, [Movie]).self) { group in
            for (index, view) in views.enumerated() {
                group.addTask { (index, (try? await client.latestInLibrary(parentId: view.id, limit: 20)) ?? []) }
            }
            var results: [(Int, [Movie])] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        guard self.client === client else { return }
        let rows = fresh.compactMap { index, items in items.isEmpty ? nil : LibraryLatest(library: views[index], items: items) }
        if !rows.isEmpty {
            remember(rows.flatMap(\.items))
            latestByLibrary = rows
        }
    }

    /// Loads the items of a library in pages with sorting.
    /// A series library must list the series, not their episodes.
    private func includeItemTypes(forLibrary libraryId: String) -> String? {
        switch libraries.first(where: { $0.id == libraryId })?.collectionType {
        case "tvshows": return "Series"
        case "movies": return "Movie"
        default: return nil
        }
    }

    /// Loads the WHOLE library from the server (in pages of 500) and keeps it on disk.
    /// The first page shows right away, the rest is added as it comes; search
    /// therefore covers the entire library as soon as loading is done.
    func loadLibraryItems(
        libraryId: String,
        reset: Bool = false,
        sortBy: String = "SortName",
        sortOrder: String = "Ascending",
        force: Bool = false
    ) async {
        guard let client else { return }

        let isSwitchingLibrary = loadedLibraryId != libraryId
        let sortChanged = sortBy != librarySort.sortBy || sortOrder != librarySort.sortOrder

        // List already up to date (same library, same sort, loaded recently): no new download.
        // Avoids downloading the whole library again each time one comes back from a page.
        if !isSwitchingLibrary, !sortChanged, !force, !libraryItems.isEmpty,
           let loadedAt = libraryLoadedAt, Date().timeIntervalSince(loadedAt) < Self.libraryFreshness {
            selectedLibraryId = libraryId
            return
        }
        guard isSwitchingLibrary || reset || sortChanged else { return }

        // Each call invalidates the previous ones: a late response must never overwrite the displayed list.
        libraryLoadGeneration += 1
        let generation = libraryLoadGeneration
        let isDefaultSort = sortBy == "SortName" && sortOrder == "Ascending"
        selectedLibraryId = libraryId

        if isSwitchingLibrary {
            loadedLibraryId = libraryId
            librarySort = (sortBy, sortOrder)
            libraryLoadedAt = nil
            // We empty the old list right away: otherwise the new grid would briefly show the items
            // of the previous library (movies) before those of the new one (series).
            libraryItems = []
            libraryTotalCount = 0
            isLoadingLibrary = true
            // Immediate display of the last complete list, while the server answers.
            let cached = isDefaultSort ? await client.cachedLibraryItems(parentId: libraryId) : []
            guard generation == libraryLoadGeneration else { return }
            remember(cached) // without this, opening a page from the cached list would do nothing
            libraryItems = cached
            libraryTotalCount = UInt32(cached.count)
            isLoadingLibrary = cached.isEmpty
        } else {
            librarySort = (sortBy, sortOrder)
            isLoadingLibrary = libraryItems.isEmpty
        }
        isLoadingMoreLibraryItems = false

        // Reloading the same list in the same order: we keep the old one displayed (no jump of
        // the grid) and replace it all at once at the end. Otherwise we show the pages as they come.
        let publishProgressively = isSwitchingLibrary || sortChanged || libraryItems.isEmpty
        libraryLoadError = nil

        let types = includeItemTypes(forLibrary: libraryId)
        let pageSize: UInt32 = 500
        var loaded: [Movie] = []
        var seen = Set<String>()

        do {
            while true {
                let page = try await client.libraryItems(
                    parentId: libraryId,
                    startIndex: UInt32(loaded.count),
                    limit: pageSize,
                    sortBy: sortBy,
                    sortOrder: sortOrder,
                    includeItemTypes: types
                )
                guard generation == libraryLoadGeneration else { return }
                remember(page.items)
                for item in page.items where seen.insert(item.id).inserted {
                    loaded.append(item)
                }
                let done = page.items.isEmpty || loaded.count >= Int(page.totalRecordCount)
                if publishProgressively || done {
                    libraryItems = loaded
                    libraryTotalCount = max(page.totalRecordCount, UInt32(loaded.count))
                    isLoadingLibrary = false
                }
                if done { break }
                isLoadingMoreLibraryItems = true
            }
            isLoadingMoreLibraryItems = false
            libraryLoadedAt = Date()
            if isDefaultSort {
                await client.storeLibraryItems(parentId: libraryId, items: loaded)
            }
        } catch {
            guard generation == libraryLoadGeneration else { return }
            isLoadingLibrary = false
            isLoadingMoreLibraryItems = false
            // A saved copy stays displayed; without a copy, we explain instead of showing "empty library".
            if libraryItems.isEmpty { libraryLoadError = message(for: error) }
            if isSessionExpired(error) { fail(error) }
        }
    }

    /// Direct content of an item that groups others (author, album, folder), sorted by name.
    func children(of parentId: String, sortBy: String = "SortName") async -> [Movie] {
        guard let client else { return [] }
        var all: [Movie] = []
        var seen = Set<String>()
        do {
            while true {
                let page = try await client.libraryItems(
                    parentId: parentId, startIndex: UInt32(all.count), limit: 500,
                    sortBy: sortBy, sortOrder: "Ascending", includeItemTypes: nil
                )
                remember(page.items)
                for item in page.items where seen.insert(item.id).inserted { all.append(item) }
                if page.items.isEmpty || all.count >= Int(page.totalRecordCount) { break }
            }
        } catch {
            logger.error("Failed to load the content of a folder: \(error.localizedDescription, privacy: .private)")
        }
        return all
    }

    func cachedSeasons(for seriesId: String) async -> [Movie] {
        let list = await client?.cachedSeasons(seriesId: seriesId) ?? []
        remember(list)
        return list
    }

    func cachedEpisodes(for seriesId: String, seasonId: String) async -> [Movie] {
        let list = await client?.cachedEpisodes(seriesId: seriesId, seasonId: seasonId) ?? []
        remember(list)
        return list
    }

    /// Loads the list of seasons of a series.
    func seasons(for seriesId: String) async -> [Movie] {
        guard let client else { return [] }
        do {
            let list = try await client.seasons(seriesId: seriesId)
            remember(list)
            return list
        } catch {
            return []
        }
    }

    /// Loads the list of episodes for a given series and season.
    func episodes(for seriesId: String, seasonId: String) async -> [Movie] {
        guard let client else { return [] }
        do {
            let list = try await client.episodes(seriesId: seriesId, seasonId: seasonId)
            remember(list)
            return list
        } catch {
            return []
        }
    }

    /// At startup: only the disk cache (fast). The full download is done on demand.
    func loadCachedMovies(_ client: JellyfinClient) async {
        guard movies.isEmpty else { return }
        let cached = await client.cachedMovies()
        if self.client === client, movies.isEmpty { setMovies(cached) }
    }

    /// Downloads the list of all movies, but only when a screen needs it (Search, Movies)
    /// and if the last copy is more than 10 minutes old (or if `force`).
    func loadMoviesIfNeeded(force: Bool = false) async {
        guard let client, !isLoadingMovies else { return }
        if !force, let loadedAt = moviesLoadedAt, Date().timeIntervalSince(loadedAt) < 600 { return }
        isLoadingMovies = true
        defer { isLoadingMovies = false }
        await loadCachedMovies(client)
        do {
            let fresh = try await client.movies()
            if self.client === client {
                setMovies(fresh)
                moviesLoadedAt = Date()
            }
        } catch {
            if self.client === client, isSessionExpired(error) { fail(error) }
        }
    }

    func refresh() async {
        guard let client else { return }
        do {
            let home = try await client.home()
            guard self.client === client else { return }
            setHome(home)
            isServerUnreachable = false
            stopBackgroundProber()
        } catch {
            guard self.client === client else { return }
            if isSessionExpired(error) { fail(error); return }
            let outcome = handleAsyncOperationError(error, for: client) {
                isServerUnreachable = true
                startBackgroundProber()
                return .offline
            }
            _ = outcome
            return
        }
        await loadLibraries(client)
        if selectedSection == .search || selectedSection == .movies { await loadMoviesIfNeeded(force: true) }
        if let currentId = selectedLibraryId {
            await loadLibraryItems(
                libraryId: currentId, reset: true,
                sortBy: librarySort.sortBy, sortOrder: librarySort.sortOrder, force: true
            )
        }
    }

    func setHome(_ home: Home) {
        resume = home.resume
        nextUp = home.nextUp
        latest = home.latest
        remember(home.resume + home.nextUp + home.latest)
    }

    private func setMovies(_ list: [Movie]) {
        movies = list
        remember(list)
    }

    func clearMetadataCache() {
        client?.clearCache()
        movies = []
        libraryItems = []
        loadedLibraryId = nil
        libraryLoadedAt = nil
        moviesLoadedAt = nil
    }
}
