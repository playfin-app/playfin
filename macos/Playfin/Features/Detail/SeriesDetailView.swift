import SwiftUI

/// Detail page of a TV series (PlxNative / Plex style).
/// Shows the hero banner, the series metadata, the season picker
/// and the full list of episodes with thumbnails, durations, synopses and direct play.
struct SeriesDetailView: View {
    @Environment(AppModel.self) private var model
    let series: Movie

    /// Audio and subtitles chosen before starting playback (for the episode that will be played).
    @State private var trackSelection = DetailTrackSelection()
    @State private var seasonsList: [Movie] = []
    @State private var selectedSeasonId: String? = nil
    @State private var episodesList: [Movie] = []
    @State private var isLoadingSeasons = false
    /// The server has answered for the seasons (a series without any season shows its empty message).
    @State private var seasonsLoaded = false
    @State private var isLoadingEpisodes = false
    /// Season whose episodes are displayed (differs from `selectedSeasonId` while another season is loading).
    @State private var shownSeasonId: String?

    private var currentSeries: Movie {
        model.movie(id: series.id) ?? series
    }

    /// Episode to play, like Plex: the one in progress or "up next" for the series (all seasons combined),
    /// otherwise the first unwatched of the displayed season.
    private var nextEpisode: Movie? {
        if let upcoming = (model.resume + model.nextUp).first(where: { $0.seriesId == series.id }) {
            return model.movie(id: upcoming.id) ?? upcoming
        }
        return episodesList.first(where: { $0.userData?.played != true }) ?? episodesList.first
    }

    /// Season to open: that of the next episode, otherwise the first real season (not "Specials").
    private func preferredSeasonId(in seasons: [Movie]) -> String? {
        if let seasonId = (model.resume + model.nextUp).first(where: { $0.seriesId == series.id })?.seasonId,
           seasons.contains(where: { $0.id == seasonId }) {
            return seasonId
        }
        return (seasons.first { ($0.indexNumber ?? 0) > 0 } ?? seasons.first)?.id
    }

    /// "Season 1 · 10 episodes" (a single title above the episodes).
    private var episodesTitle: String {
        let name = selectedSeason?.name ?? "Episodes"
        guard !episodesList.isEmpty else { return name }
        return "\(name) · \(episodesList.count) episode\(episodesList.count > 1 ? "s" : "")"
    }

    private var selectedSeason: Movie? {
        seasonsList.first { $0.id == selectedSeasonId } ?? seasonsList.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // The title starts a little lower than the top, like Plex: the image breathes above it. Less than on
                // a movie page (22 %): the episodes, below, stay visible without scrolling in a normal window.
                Color.clear.frame(height: 1).containerRelativeFrame(.vertical) { height, _ in max(40, height * 0.12) }

                MovieLogoOrTitle(movie: currentSeries)
                    .frame(maxWidth: 580, alignment: .leading)

                // Series · Year · Genres · Seasons · Rating · [format], then the ratings.
                VStack(alignment: .leading, spacing: 10) {
                    metadataRow
                    DetailRatingsRow(movie: currentSeries)
                }

                // Synopsis, then the episode that will be played: "S2:E3 · Title · 45 min · Direct play".
                VStack(alignment: .leading, spacing: 14) {
                    if let overview = currentSeries.overview, !overview.isEmpty {
                        ExpandableOverview(text: overview)
                    }
                    if let next = nextEpisode {
                        DetailInfoLine(
                            parts: [next.episodeSubtitle, next.formattedDuration].compactMap { $0 },
                            fileItemId: next.id
                        )
                    }
                }

                // Buttons on the left; Starring at the right edge, level with them.
                HStack(alignment: .bottom, spacing: 24) {
                    buttons
                    Spacer(minLength: 24)
                    DetailCredits(item: currentSeries)
                }
                .padding(.top, 4)

                // A single season: no picker, its name is already the title of the episodes.
                if seasonsList.count > 1 { seasonPicker }
                episodesSection

                // About (file and languages of the episode that will be played), then the cast
                DetailAboutSection(item: currentSeries, fileItemId: nextEpisode?.id)
                CastCrewSection(movie: currentSeries)

                Spacer().frame(height: 60)
            }
            .padding(.horizontal, Theme.Spacing.screenMargin)
        }
        .background {
            DetailBackdrop(item: currentSeries)
        }
        .navigationTitle(currentSeries.name)
        .task {
            await model.loadDetails(of: series.id)
            await loadSeasons()
        }
        // `task(id:)` cancels the request of the old season when another one is chosen.
        .task(id: selectedSeasonId) {
            if let id = selectedSeasonId {
                await loadEpisodes(seasonId: id)
            }
        }
        // Space plays the next episode from anywhere on the page.
        .onKeyPress(.space) {
            guard let ep = nextEpisode else { return .ignored }
            model.play(ep, fromStart: false, tracks: trackSelection.forPlayback)
            return .handled
        }
    }

    /// "Series · 2008 · Drama · 5 seasons · TV-14": the pieces of information that are known.
    private var metadataParts: [String] {
        var parts = ["Series"]
        if let year = currentSeries.productionYear { parts.append(String(year)) }
        parts.append(contentsOf: currentSeries.genres.prefix(2))
        if !seasonsList.isEmpty {
            parts.append(seasonsList.count > 1 ? "\(seasonsList.count) seasons" : "1 season")
        }
        if let rating = currentSeries.officialRating, !rating.isEmpty { parts.append(rating) }
        return parts
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(metadataParts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Text("·").foregroundStyle(.white.opacity(0.5)) }
                Text(part).foregroundStyle(.white.opacity(0.85))
            }
            // Format of the episode that will be played, as on a movie page
            if let badge = nextEpisode?.resolutionBadge { FormatBadge(text: badge) }
        }
        .font(.callout)
        .lineLimit(1)
    }

    private var buttons: some View {
        HStack(spacing: 14) {
            if let nextEp = nextEpisode {
                PlayButton(title: nextEp.playButtonTitle) { play(nextEp, fromStart: false) }
                    .keyboardShortcut(.defaultAction) // Return plays

                if nextEp.resumeSeconds > 0 {
                    DetailCircleButton(systemName: "arrow.counterclockwise", caption: "Restart", help: "Play from the beginning") {
                        play(nextEp, fromStart: true)
                    }
                }

                DetailTrackButtons(itemId: nextEp.id, selection: $trackSelection)
            }

            DetailCircleButton(
                systemName: currentSeries.isWatched ? "checkmark.circle.fill" : "checkmark",
                tint: currentSeries.isWatched ? Theme.Colors.watched : .white,
                caption: "Watched",
                help: currentSeries.isWatched ? "Mark the series as unwatched" : "Mark the series as watched",
                action: toggleWatched
            )

            DetailCircleButton(
                systemName: currentSeries.isFavorite ? "heart.fill" : "heart",
                tint: currentSeries.isFavorite ? Theme.Colors.favorite : .white,
                caption: "Favourite",
                help: currentSeries.isFavorite ? "Remove from favourites" : "Add to favourites",
                action: toggleFavorite
            )

            DownloadButton(item: currentSeries, seasonId: selectedSeasonId)
        }
        .fixedSize()
    }

    /// The seasons wrap onto several lines when there are many (or long names): all of them stay visible.
    private var seasonPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Seasons")
                .font(Theme.Typography.section)
                .foregroundStyle(.white)

            FlowLayout(spacing: 10) {
                ForEach(seasonsList, id: \.id) { season in
                    let isSelected = selectedSeason?.id == season.id
                    Button { select(season) } label: {
                        Text(season.name)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(isSelected ? Color.white : Color.white.opacity(0.12)))
                            .foregroundStyle(isSelected ? Color.black : Color.white)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.top, 8)
    }

    /// Episodes of the selected season.
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch EpisodesSectionState.state(
                selectedSeasonId: selectedSeasonId, shownSeasonId: shownSeasonId, isLoadingEpisodes: isLoadingEpisodes,
                seasonsLoaded: seasonsLoaded, hasSeasons: !seasonsList.isEmpty, hasEpisodes: !episodesList.isEmpty
            ) {
            case .loading:
                // Seasons or episodes not known yet: never "No episode" for a moment before they arrive.
                ProgressView().frame(maxWidth: .infinity).frame(height: 200)
            case .empty:
                VStack(alignment: .leading, spacing: 8) {
                    Text(EmptyStateText.message(
                        isOffline: model.isServerUnreachable,
                        offline: "Offline: the episodes of this season have not been saved on this Mac.",
                        online: "No episode available for this season."))
                        .foregroundStyle(.white.opacity(0.6))
                    Button("Try again") {
                        if let id = selectedSeasonId {
                            Task { await loadEpisodes(seasonId: id) }
                        } else {
                            Task { await loadSeasons() }
                        }
                    }
                }
                .padding(.vertical, 16)
            case .episodes:
                // The row goes to the edge of the window (margin cancelled), the title stays aligned.
                Shelf(title: episodesTitle, titleColor: .white, isLazy: true) {
                    ForEach(episodesList, id: \.id) { episode in
                        EpisodeRowCard(episode: episode)
                    }
                }
                .padding(.horizontal, -Theme.Spacing.screenMargin)
                .id(shownSeasonId)
                .transition(.opacity)
            }
        }
        .padding(.top, 8)
    }

    private func select(_ season: Movie) {
        withAnimation(Theme.Motion.standard) { selectedSeasonId = season.id }
    }

    private func play(_ episode: Movie, fromStart: Bool) {
        model.play(episode, fromStart: fromStart, tracks: trackSelection.forPlayback)
    }

    private func toggleWatched() { Task { await model.toggleWatched(currentSeries) } }
    private func toggleFavorite() { Task { await model.toggleFavorite(currentSeries) } }

    private func loadSeasons() async {
        // The known seasons show right away, the server updates afterwards.
        let cached = await model.cachedSeasons(for: series.id)
        if !cached.isEmpty, seasonsList.isEmpty {
            seasonsList = cached
            if selectedSeasonId == nil { selectedSeasonId = preferredSeasonId(in: cached) }
        }
        isLoadingSeasons = cached.isEmpty
        let list = await model.seasons(for: series.id)
        guard !Task.isCancelled else { return }
        isLoadingSeasons = false
        seasonsLoaded = true
        guard !list.isEmpty else { return }
        seasonsList = list
        if selectedSeasonId == nil || !list.contains(where: { $0.id == selectedSeasonId }) {
            selectedSeasonId = preferredSeasonId(in: list)
        }
    }

    private func loadEpisodes(seasonId: String) async {
        let cached = await model.cachedEpisodes(for: series.id, seasonId: seasonId)
        guard !Task.isCancelled else { return }
        if !cached.isEmpty { show(cached, of: seasonId) }
        isLoadingEpisodes = cached.isEmpty
        let list = await model.episodes(for: series.id, seasonId: seasonId)
        // A response from an abandoned season must not replace the episodes of the displayed season.
        guard !Task.isCancelled, selectedSeasonId == seasonId else { return }
        isLoadingEpisodes = false
        if !list.isEmpty || cached.isEmpty { show(list, of: seasonId) }
    }

    private func show(_ episodes: [Movie], of seasonId: String) {
        withAnimation(Theme.Motion.standard) {
            episodesList = episodes
            shownSeasonId = seasonId
        }
    }
}

/// What the episodes area of a series page shows (pure function, tested).
enum EpisodesSectionState: Equatable {
    case loading, empty, episodes

    static func state(
        selectedSeasonId: String?, shownSeasonId: String?, isLoadingEpisodes: Bool,
        seasonsLoaded: Bool, hasSeasons: Bool, hasEpisodes: Bool
    ) -> EpisodesSectionState {
        // No season chosen yet: the seasons are loading, unless the server said there are none.
        guard selectedSeasonId != nil else { return seasonsLoaded && !hasSeasons ? .empty : .loading }
        // Another season is loading: not the episodes of the old one under the new title.
        guard shownSeasonId == selectedSeasonId else { return .loading }
        if hasEpisodes { return .episodes }
        return isLoadingEpisodes ? .loading : .empty
    }
}

/// Card representing an individual episode of a series.
struct EpisodeRowCard: View {
    @Environment(AppModel.self) private var model
    let episode: Movie
    @State private var isHovered = false

    private var currentEpisode: Movie {
        model.movie(id: episode.id) ?? episode
    }

    var body: some View {
        Button {
            model.play(currentEpisode, fromStart: false)
        } label: {
            content
        }
        .buttonStyle(CardButtonStyle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(currentEpisode.resumeSeconds > 0 ? "Resume" : "Play", systemImage: "play.fill") {
                model.play(currentEpisode, fromStart: false)
            }
            if currentEpisode.resumeSeconds > 0 {
                Button("Play from the beginning", systemImage: "arrow.counterclockwise") {
                    model.play(currentEpisode, fromStart: true)
                }
            }
            WatchedMenuItems(movie: currentEpisode)
            Divider()
            if model.downloads.downloadedIds.contains(currentEpisode.id) {
                Button("Delete download", systemImage: "trash", role: .destructive) {
                    model.downloads.remove(currentEpisode.id)
                }
            } else if model.downloads.canDownload {
                Button("Download", systemImage: "arrow.down.circle") { model.downloads.download([currentEpisode]) }
            }
        }
        .accessibilityLabel(currentEpisode.episodeSubtitle ?? currentEpisode.name)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        AsyncArtwork(
                            url: model.episodeThumbnailURL(currentEpisode, height: 360),
                            blurHash: currentEpisode.primaryBlurHash,
                            targetBlurHashSize: CGSize(width: 48, height: 27),
                            contentMode: .fill
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))

                if isHovered {
                    Color.black.opacity(0.35)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
                    Image(systemName: currentEpisode.resumeSeconds > 0 ? "play.circle.fill" : "play.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white)
                }
            }
            .overlay(alignment: .bottom) {
                if let fraction = currentEpisode.playbackFraction {
                    ProgressBar(fraction: fraction).padding(6)
                }
            }
            .overlay(alignment: .topLeading) { DownloadedBadge(itemId: currentEpisode.id).padding(6) }
            .frame(width: 280, height: 158)

            HStack(spacing: 6) {
                if let index = currentEpisode.indexNumber {
                    Text("\(index).")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white.opacity(0.75))
                }
                Text(currentEpisode.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if currentEpisode.userData?.played == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.watched)
                }
                Spacer(minLength: 0)
                if let minutes = currentEpisode.durationMinutes, minutes > 0 {
                    Text("\(minutes) min")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 280)

            // Always 3 lines tall, even without a summary: every card of the row has the same height.
            Text(currentEpisode.overview ?? "")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(3, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(width: 280, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
        )
        .contentShape(Rectangle())
        .animation(Theme.Motion.hover, value: isHovered)
    }
}
