import Foundation
import os

/// A playback ready to start: everything the player needs.
struct Playback {
    let movie: Movie
    let url: String
    let httpHeader: String
    let startSeconds: Double
    let subtitles: [ExternalSubtitle]
    /// Tracks chosen on the detail page before playback (`nil`: the player chooses automatically).
    var initialTracks: TrackPreference?
}

/// Playback: starting, next episode, progress reports to the server.
extension AppModel {

    // MARK: Playback

    /// Universal playback: works for any item (movie, episode, audiobook, series, season,
    /// folder, author, album…). A directly playable item starts at once; otherwise we look for what to
    /// play inside (in progress, otherwise first unwatched, otherwise the first). All screens go through here.
    func play(_ item: Movie, fromStart: Bool = false, tracks: TrackPreference? = nil) {
        // A downloaded item is always played from disk, whether the server is reachable or not.
        if downloads.localFile(for: item.id) != nil {
            startPlayback(item, fromStart: fromStart, tracks: tracks)
            return
        }
        if isServerUnreachable {
            offlineAlertMessage = "This media is not downloaded. Streaming requires a connection to the Jellyfin server."
            return
        }
        if item.isDirectlyPlayable {
            startPlayback(item, fromStart: fromStart, tracks: tracks)
            return
        }
        guard !isResolvingPlayback else { return }
        isResolvingPlayback = true
        Task {
            defer { isResolvingPlayback = false }
            if let target = await resolvePlayable(item) {
                startPlayback(target, fromStart: fromStart, tracks: tracks)
            } else {
                offlineAlertMessage = "Nothing to play in \"\(item.name)\"."
            }
        }
    }

    /// Natural end of a playback: if it is an episode and the setting is on, starts the next one.
    func playbackFinished() {
        guard settings.values.autoPlayNext, playback?.movie.itemType == "Episode" else { return }
        playUpNext()
    }

    /// Starts the next episode ("Play now" button of the card, button and N key of the player, or end of the episode).
    func playUpNext() {
        guard let next = upNext else { return }
        startPlayback(next, fromStart: false)
    }

    /// Starts the previous episode (button and P key of the player), where it was left.
    func playPreviousEpisode() {
        guard let previous = previousEpisode else { return }
        startPlayback(previous, fromStart: false)
    }

    /// Looks for the next and previous episodes as soon as playback starts: the card and the buttons can show
    /// without waiting. Offline, among the downloaded episodes of the series.
    private func prepareUpNext(after movie: Movie) {
        upNext = nil
        previousEpisode = nil
        guard movie.itemType == "Episode", let seriesId = movie.seriesId, !seriesId.isEmpty else { return }
        let offline = downloads.downloadedItems()
            .filter { $0.seriesId == seriesId }
            .sorted { ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0) < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0) }
        if isServerUnreachable || client == nil {
            upNext = PlaybackChooser.episode(after: movie.id, in: offline)
            previousEpisode = PlaybackChooser.episode(before: movie.id, in: offline)
            return
        }
        guard let client else { return }
        Task {
            let episodes = (try? await client.seriesEpisodes(seriesId: seriesId)) ?? offline
            guard playback?.movie.id == movie.id else { return } // the user changed meanwhile
            upNext = PlaybackChooser.episode(after: movie.id, in: episodes)
            previousEpisode = PlaybackChooser.episode(before: movie.id, in: episodes)
        }
    }

    /// Goes down into the series / container until it finds a playable item (4 levels at most).
    func resolvePlayable(_ item: Movie, depth: Int = 0) async -> Movie? {
        if item.isDirectlyPlayable { return item }
        guard depth < 4, let client else { return nil }
        let candidates: [Movie]
        if item.isSeries {
            candidates = (try? await client.seriesEpisodes(seriesId: item.id)) ?? []
        } else {
            // A season plays in episode order, a folder or an author by name.
            candidates = await children(of: item.id, sortBy: item.isSeason ? "ParentIndexNumber,IndexNumber,SortName" : "SortName")
        }
        guard let next = PlaybackChooser.next(from: candidates) else { return nil }
        return await resolvePlayable(next, depth: depth + 1)
    }

    /// Starts the video immediately without waiting for the subtitles download.
    private func startPlayback(_ movie: Movie, fromStart: Bool, tracks: TrackPreference? = nil) {
        defer { prepareUpNext(after: movie) }
        if let path = downloads.localFile(for: movie.id) {
            // Playing the downloaded file: no network, subtitles saved alongside.
            pendingSubtitles = []
            playbackSegments = []
            playback = Playback(
                movie: movie, url: path, httpHeader: "",
                startSeconds: fromStart ? 0 : movie.resumeSeconds, subtitles: downloads.localSubtitles(for: movie.id),
                initialTracks: tracks
            )
            if let client, !isServerUnreachable {
                Task {
                    let segments = await client.mediaSegments(itemId: movie.id)
                    if self.playback?.movie.id == movie.id { self.playbackSegments = segments }
                }
            }
            return
        }
        guard let client, let header = try? client.playbackHeader() else { return }
        let startSec = fromStart ? 0.0 : movie.resumeSeconds
        let streamUrl = movie.isAudio ? client.audioStreamUrl(itemId: movie.id) : client.streamUrl(itemId: movie.id)

        pendingSubtitles = []
        playback = Playback(
            movie: movie,
            url: streamUrl,
            httpHeader: header,
            startSeconds: startSec,
            subtitles: [],
            initialTracks: tracks
        )

        playbackSegments = []
        Task {
            let segments = await client.mediaSegments(itemId: movie.id)
            if self.playback?.movie.id == movie.id { self.playbackSegments = segments }
        }

        // Fetches the subtitles in the background without blocking the video opening
        Task {
            let subs = (try? await client.externalSubtitles(itemId: movie.id)) ?? []
            if self.playback?.movie.id == movie.id, !subs.isEmpty {
                self.pendingSubtitles = subs
            }
        }
    }

    func reportStart(_ movie: Movie, seconds: Double) {
        let requestedStart = playback?.startSeconds ?? 0
        let actualSeconds = requestedStart == 0 ? 0 : max(seconds, requestedStart)
        report(movie, kind: "start", ticks: ticks(actualSeconds)) { client, ticks in
            try await client.reportPlaybackStart(itemId: movie.id, positionTicks: ticks)
        }
    }

    func reportProgress(_ movie: Movie, seconds: Double, isPaused: Bool) {
        report(movie, kind: "progress", ticks: ticks(seconds)) { client, ticks in
            try await client.reportPlaybackProgress(itemId: movie.id, positionTicks: ticks, isPaused: isPaused)
        }
    }

    func reportStopped(_ movie: Movie, seconds: Double) {
        report(movie, kind: "stopped", ticks: ticks(seconds)) { [weak self] client, ticks in
            try await client.reportPlaybackStopped(itemId: movie.id, positionTicks: ticks)
            await self?.refreshAfterPlayback(of: movie)
        }
        deleteDownloadIfWatched(movie, seconds: seconds)
    }

    /// Sends a report to the server; offline (or if sending fails for lack of network), it is kept and will be
    /// sent when the server is back.
    private func report(
        _ movie: Movie, kind: String, ticks: Int64,
        send: @escaping @MainActor (JellyfinClient, Int64) async throws -> Void
    ) {
        guard let client else { return }
        if isServerUnreachable {
            downloads.queueReport(itemId: movie.id, kind: kind, ticks: ticks)
            return
        }
        Task {
            do {
                try await send(client, ticks)
            } catch let error as JellyfinError {
                switch error {
                case .Network, .ServerUnreachable:
                    downloads.queueReport(itemId: movie.id, kind: kind, ticks: ticks)
                default:
                    break
                }
            } catch {}
        }
    }

    /// After a playback: home (Resume, Up next) and the item played, without reloading everything.
    private func refreshAfterPlayback(of movie: Movie) async {
        guard let client else { return }
        if let home = try? await client.home(), self.client === client { setHome(home) }
        if let fresh = try? await client.itemDetails(itemId: movie.id), self.client === client {
            replaceEverywhere(fresh)
        }
    }

    /// "Delete after watching" setting: a downloaded item watched to the end frees its space.
    private func deleteDownloadIfWatched(_ movie: Movie, seconds: Double) {
        guard settings.values.deleteAfterWatched, downloads.downloadedIds.contains(movie.id),
              let total = movie.runTimeTicks, total > 0, Double(ticks(seconds)) >= Double(total) * 0.9 else { return }
        downloads.remove(movie.id)
    }

    func openDownloads(for client: JellyfinClient) {
        guard let session = client.sessionInfo() else { return }
        let serverName = profiles.first { $0.serverId == session.serverId }?.serverName ?? "Jellyfin"
        downloads.open(client: client, session: session, serverName: serverName, settings: settings.values)
        // Downloaded items open even without a server.
        remember(downloads.downloadedItems())
        settings.onChange = { [weak self] values in
            guard let self else { return }
            let name = self.activeProfile?.serverName ?? serverName
            self.downloads.apply(settings: values, serverName: name)
        }
    }
}

/// Jellyfin counts time in "ticks": 1 second = 10,000,000 ticks.
let ticksPerSecond = 10_000_000.0

/// Seconds -> ticks, bounded: a negative, NaN or infinite value must neither crash nor be sent to the server.
func ticks(_ seconds: Double) -> Int64 {
    guard !seconds.isNaN, seconds > 0 else { return 0 }
    return Int64(min(seconds * ticksPerSecond, Double(Int64.max / 2)))
}

/// Single rule to choose what to play in a list (episodes of a series, content of a folder or author):
/// the item in progress, otherwise the first unwatched, otherwise the first (everything watched: start over).
enum PlaybackChooser {
    /// The episode that follows `id` in the list (nil for the last one).
    static func episode(after id: String, in episodes: [Movie]) -> Movie? {
        guard let index = episodes.firstIndex(where: { $0.id == id }), index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }

    /// The episode before `id` in the list (nil for the first one).
    static func episode(before id: String, in episodes: [Movie]) -> Movie? {
        guard let index = episodes.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        return episodes[index - 1]
    }

    static func next(from items: [Movie]) -> Movie? {
        items.first(where: \.isInProgress)
            ?? items.first(where: { !$0.isWatched })
            ?? items.first
    }
}
