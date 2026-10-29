import SwiftUI

/// Detail page of a movie, faithful to the PlxNative / Plex design.
/// Shows the official clear logo, detailed metadata, multiple ratings (IMDb, Rotten Tomatoes, TMDB),
/// the iconic white Play/Resume button, the director and the cast (Cast & Crew).
struct MovieDetailView: View {
    @Environment(AppModel.self) private var model
    let movie: Movie

    /// Audio and subtitles chosen before starting playback.
    @State private var trackSelection = DetailTrackSelection()

    private var currentMovie: Movie {
        model.movie(id: movie.id) ?? movie
    }

    private var seriesId: String? {
        guard currentMovie.itemType == "Episode", let id = currentMovie.seriesId, !id.isEmpty else { return nil }
        return id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // The title starts around a quarter of the height, like Plex: the image breathes above it.
                Color.clear.frame(height: 1).containerRelativeFrame(.vertical) { height, _ in max(40, height * 0.22) }

                if let seriesId { seriesLink(seriesId) }

                MovieLogoOrTitle(movie: currentMovie)
                    .frame(maxWidth: 580, alignment: .leading)

                // Movie · Genres · Rating · [format], then the ratings, as on Plex.
                VStack(alignment: .leading, spacing: 10) {
                    metadataRow
                    DetailRatingsRow(movie: currentMovie)
                }

                // Synopsis (4 lines, "Read more" if longer), then date · duration · direct play.
                VStack(alignment: .leading, spacing: 14) {
                    if let overview = currentMovie.overview, !overview.isEmpty {
                        ExpandableOverview(text: overview)
                    }
                    DetailInfoLine(
                        parts: [currentMovie.formattedReleaseDate, currentMovie.formattedDuration ?? ""].filter { !$0.isEmpty },
                        fileItemId: currentMovie.id
                    )
                }

                // Buttons on the left; Directed by / Starring at the right edge, level with them.
                HStack(alignment: .bottom, spacing: 24) {
                    buttons
                    Spacer(minLength: 24)
                    DetailCredits(item: currentMovie)
                }
                .padding(.top, 4)

                DetailAboutSection(item: currentMovie, fileItemId: currentMovie.id)
                CastCrewSection(movie: currentMovie)
            }
            .padding(.horizontal, Theme.Spacing.screenMargin)
            .padding(.top, 24)
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Immersive background: the movie image with the PlxNative gradient
        .background {
            DetailBackdrop(item: currentMovie)
        }
        // The cast is not in the lists (to keep them light): we load it here.
        .task { await model.loadDetails(of: movie.id) }
        // Space plays from anywhere on the page.
        .onKeyPress(.space) {
            play(fromStart: false)
            return .handled
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            let parts = [currentMovie.itemType == "Episode" ? "Episode" : "Movie"]
                + currentMovie.genres.prefix(2)
                + [currentMovie.officialRating].compactMap { $0 }.filter { !$0.isEmpty }
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Text("·").foregroundStyle(.white.opacity(0.5)) }
                Text(part).foregroundStyle(.white.opacity(0.85))
            }
            // Actual resolution (4K UHD, 1080p FHD, 720p HD)
            if let badge = currentMovie.resolutionBadge {
                FormatBadge(text: badge)
            }
        }
        .font(.callout)
        .lineLimit(1)
    }

    private var buttons: some View {
        HStack(spacing: 14) {
            PlayButton(title: currentMovie.resumeSeconds > 0 ? "Resume" : "Play") { play(fromStart: false) }
                .keyboardShortcut(.defaultAction) // Return plays

            if currentMovie.resumeSeconds > 0 {
                DetailCircleButton(systemName: "arrow.counterclockwise", caption: "Restart", help: "Play from the beginning") {
                    play(fromStart: true)
                }
            }

            DetailTrackButtons(itemId: currentMovie.id, selection: $trackSelection)

            DetailCircleButton(
                systemName: currentMovie.isWatched ? "checkmark.circle.fill" : "checkmark",
                tint: currentMovie.isWatched ? Theme.Colors.watched : .white,
                caption: "Watched",
                help: currentMovie.isWatched ? "Mark as unwatched" : "Mark as watched",
                action: toggleWatched
            )

            DetailCircleButton(
                systemName: currentMovie.isFavorite ? "heart.fill" : "heart",
                tint: currentMovie.isFavorite ? Theme.Colors.favorite : .white,
                caption: "Favourite",
                help: currentMovie.isFavorite ? "Remove from favourites" : "Add to favourites",
                action: toggleFavorite
            )

            DownloadButton(item: currentMovie)
        }
        .fixedSize()
    }

    /// Episode: direct link to the page of its series (whatever screen one comes from).
    private func seriesLink(_ seriesId: String) -> some View {
        RouteLink(value: Route.movie(seriesId)) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                Text(currentMovie.seriesName ?? "View the series")
                if let season = currentMovie.seasonName ?? currentMovie.parentIndexNumber.map({ "Season \($0)" }) {
                    Text("·").foregroundStyle(.white.opacity(0.5))
                    Text(season)
                }
                Image(systemName: "chevron.right").font(.caption.bold())
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(PressableButtonStyle())
        .help("Open the series page")
    }

    private func play(fromStart: Bool) {
        model.play(currentMovie, fromStart: fromStart, tracks: trackSelection.forPlayback)
    }

    private func toggleWatched() { Task { await model.toggleWatched(currentMovie) } }
    private func toggleFavorite() { Task { await model.toggleFavorite(currentMovie) } }
}

/// Shows the official movie logo (ClearLogo) if it exists in Jellyfin,
/// or gracefully falls back to the title in bold white text with a drop shadow.
struct MovieLogoOrTitle: View {
    @Environment(AppModel.self) private var model
    let movie: Movie
    /// For an episode, the logo is that of its series.
    var logoOwnerIsSeries = false
    var maxLogoHeight: CGFloat = 130
    var titleFont: Font = Theme.Typography.detail

    /// Logo only if the server has one (otherwise a useless request, then the title jumping).
    private var logoURL: URL? {
        if logoOwnerIsSeries, movie.itemType == "Episode", let seriesId = movie.seriesId, !seriesId.isEmpty,
           let client = model.client {
            return URL(string: client.imageUrl(itemId: seriesId, kind: .logo, maxHeight: 320, tag: nil))
        }
        guard movie.imageTag(.logo) != nil else { return nil }
        return model.imageURL(movie, .logo, height: 320)
    }

    var body: some View {
        if let url = logoURL {
            AsyncArtwork(
                url: url,
                content: { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: maxLogoHeight, alignment: .bottomLeading)
                        .shadow(color: .black.opacity(0.6), radius: 10, x: 0, y: 4)
                },
                placeholder: {
                    // The title in the meantime (and forever if the server has no logo), in a frame of the
                    // same height as the logo: the page does not jump when it arrives.
                    titleFallback
                }
            )
            .artworkAlignment(.bottomLeading)
            .frame(height: maxLogoHeight)
            .accessibilityLabel(movie.displayTitle)
        } else {
            titleFallback
        }
    }

    private var titleFallback: some View {
        Text(logoOwnerIsSeries ? movie.displayTitle : movie.name)
            .font(titleFont)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.7), radius: 8, x: 0, y: 3)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
    }
}
