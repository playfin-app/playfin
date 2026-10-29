import Foundation
import os

/// Known items, details, watched state, search and image URLs.
extension AppModel {

    func remember(_ list: [Movie]) {
        var changed: [(String, Movie)] = []
        for var item in list {
            let old = known[item.id]
            // The lists do not include the cast: we keep the one from an already loaded record.
            if item.people.isEmpty, let old, !old.people.isEmpty { item.people = old.people }
            if old != item { changed.append((item.id, item)) }
        }
        // Nothing changed: we do not write, so as not to wake the views that observe `known`.
        guard !changed.isEmpty else { return }
        known.merge(changed, uniquingKeysWith: { _, new in new })
    }

    func mediaInfo(for itemId: String) async -> MediaInfo? {
        if let cached = mediaInfoCache[itemId] { return cached }
        guard let client, let info = try? await client.mediaInfo(itemId: itemId) else { return nil }
        mediaInfoCache[itemId] = info
        return info
    }

    /// Everything a person appears in (actor, director), for the person page.
    func itemsWithPerson(_ personId: String) async throws -> [Movie] {
        guard let client else { return [] }
        let items = try await client.itemsWithPerson(personId: personId)
        remember(items)
        return items
    }

    /// Loads the full record (with the cast) of an item and updates `known`.
    func loadDetails(of id: String) async {
        guard let client, known[id]?.people.isEmpty ?? true else { return }
        if let detailed = try? await client.itemDetails(itemId: id), self.client === client {
            known[id] = detailed
        }
    }

    // MARK: Media actions

    /// Watched button of the pages: watched ↔ unwatched.
    func toggleWatched(_ movie: Movie) async {
        await setWatched(movie, watched: !movie.isWatched)
    }

    /// Marks an item as watched, or as unwatched, on the server and updates the interface immediately.
    /// "Unwatched" also forgets the position (Jellyfin resets it): a started item starts again from the beginning.
    func setWatched(_ movie: Movie, watched: Bool) async {
        guard let client else { return }

        // Immediate local optimistic update
        var updatedMovie = movie
        let optimistic = UserData(playbackPositionTicks: 0, played: watched, playedPercentage: watched ? 100.0 : nil,
                                  isFavorite: movie.isFavorite)
        updatedMovie.userData = optimistic

        let removedResume = resume.firstIndex(where: { $0.id == movie.id }).map { (index: $0, item: resume[$0]) }
        let removedNextUp = nextUp.firstIndex(where: { $0.id == movie.id }).map { (index: $0, item: nextUp[$0]) }
        replaceEverywhere(updatedMovie)
        // No longer in progress either way: out of "Continue watching".
        resume.removeAll(where: { $0.id == movie.id })
        if watched { nextUp.removeAll(where: { $0.id == movie.id }) }

        do {
            if watched {
                try await client.markAsPlayed(itemId: movie.id)
            } else {
                try await client.markAsUnplayed(itemId: movie.id)
            }
        } catch {
            if isSessionExpired(error) {
                fail(error)
                return
            }
            logger.error("Failed to mark watched / unwatched: \(error.localizedDescription, privacy: .private)")
            // Roll back only if the displayed state is still the optimistic update
            // (otherwise another user action came in meanwhile).
            guard self.movie(id: movie.id)?.userData == optimistic else { return }
            replaceEverywhere(movie)
            if let removedResume, !resume.contains(where: { $0.id == movie.id }) {
                resume.insert(removedResume.item, at: min(removedResume.index, resume.count))
            }
            if let removedNextUp, !nextUp.contains(where: { $0.id == movie.id }) {
                nextUp.insert(removedNextUp.item, at: min(removedNextUp.index, nextUp.count))
            }
        }
    }

    /// Heart button of the pages: adds to or removes from the favourites, on the server and at once in the interface.
    func toggleFavorite(_ movie: Movie) async {
        guard let client else { return }
        let favorite = !movie.isFavorite
        var updated = movie
        var data = movie.userData ?? UserData(playbackPositionTicks: 0, played: false, playedPercentage: nil)
        data.isFavorite = favorite
        updated.userData = data
        let oldFavorites = favorites
        replaceEverywhere(updated)
        // Removed first in both cases: a page a little behind the server must not add it twice.
        favorites.removeAll(where: { $0.id == movie.id })
        if favorite { favorites.insert(updated, at: 0) }

        do {
            if favorite {
                try await client.markAsFavorite(itemId: movie.id)
            } else {
                try await client.unmarkAsFavorite(itemId: movie.id)
            }
        } catch {
            if isSessionExpired(error) {
                fail(error)
                return
            }
            logger.error("Failed to change the favourite: \(error.localizedDescription, privacy: .private)")
            // Roll back only if nobody changed it again meanwhile.
            guard self.movie(id: movie.id)?.isFavorite == favorite else { return }
            replaceEverywhere(movie)
            favorites = oldFavorites
        }
    }

    /// Replaces an item in all the lists that display it, without reloading from the server.
    func replaceEverywhere(_ updated: Movie) {
        remember([updated])
        if let idx = movies.firstIndex(where: { $0.id == updated.id }) { movies[idx] = updated }
        if let idx = libraryItems.firstIndex(where: { $0.id == updated.id }) { libraryItems[idx] = updated }
        if let idx = resume.firstIndex(where: { $0.id == updated.id }) { resume[idx] = updated }
        if let idx = nextUp.firstIndex(where: { $0.id == updated.id }) { nextUp[idx] = updated }
        if let idx = latest.firstIndex(where: { $0.id == updated.id }) { latest[idx] = updated }
        if let idx = favorites.firstIndex(where: { $0.id == updated.id }) { favorites[idx] = updated }
    }

    enum SearchOutcome {
        case results([Movie])
        /// Server unreachable: saved movies only.
        case localOnly([Movie])
        case failed(String)
    }

    /// Search across all libraries via the server; offline, in the movies already saved.
    func search(_ term: String) async -> SearchOutcome {
        guard let client else { return .failed("No server connected.") }
        if isServerUnreachable { return .localOnly(await localSearch(term, client: client)) }
        do {
            let found = try await client.search(term: term, limit: 60)
            remember(found)
            return .results(found)
        } catch let error as JellyfinError {
            switch error {
            case .Network, .ServerUnreachable:
                return .localOnly(await localSearch(term, client: client))
            default:
                return .failed(message(for: error))
            }
        } catch {
            return .failed(message(for: error))
        }
    }

    private func localSearch(_ term: String, client: JellyfinClient) async -> [Movie] {
        if movies.isEmpty { movies = await client.cachedMovies() }
        let found = MovieSearch.titleMatches(in: movies, query: term)
        remember(found)
        return found
    }

    func imageURL(_ movie: Movie, _ kind: ImageKind, height: UInt32) -> URL? {
        // Downloaded item: its images are on disk (immediate display, and offline).
        if kind != .logo, let path = downloads.localAssets[movie.id]?[kind == .primary ? "poster" : "backdrop"] {
            return URL(fileURLWithPath: path)
        }
        // An episode has no poster or background of its own: we use those of its series.
        var itemId = movie.id
        if kind != .logo, !movie.isSeries, let seriesId = movie.seriesId, !seriesId.isEmpty {
            itemId = seriesId
        }
        let tag = movie.imageTag(kind)
        return client.flatMap { URL(string: $0.imageUrl(itemId: itemId, kind: kind, maxHeight: height, tag: tag)) }
    }

    /// 16:9 thumbnail of an episode: its own image if it has one, otherwise its series' background.
    func episodeThumbnailURL(_ episode: Movie, height: UInt32) -> URL? {
        if let path = downloads.localAssets[episode.id]?["backdrop"] { return URL(fileURLWithPath: path) }
        guard let client else { return nil }
        if let tag = episode.imageTags.first(where: { $0.kind == "Primary" })?.tag {
            return URL(string: client.imageUrl(itemId: episode.id, kind: .primary, maxHeight: height, tag: tag))
        }
        let seriesId = episode.seriesId.flatMap { $0.isEmpty ? nil : $0 } ?? episode.id
        return URL(string: client.imageUrl(
            itemId: seriesId, kind: .backdrop, maxHeight: height, tag: episode.parentBackdropImageTags.first
        ))
    }

    func personImageURL(_ personId: String, height: UInt32 = 200) -> URL? {
        client.flatMap { URL(string: $0.personImageUrl(personId: personId, maxHeight: height)) }
    }
}
