import SwiftUI

/// A movie poster with watch state, progress bar and quick play on hover.
struct PosterCard: View {
    @Environment(AppModel.self) private var model
    let movie: Movie
    /// Height requested from the server (chosen by the grid or row depending on the display size).
    var imageHeight: UInt32 = 450
    /// Shape imposed by the grid or row (same height for all its cards); otherwise the item's own.
    var aspectRatio: Double? = nil
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.clear
                    .aspectRatio(aspectRatio ?? movie.cardAspectRatio, contentMode: .fit)
                    .overlay {
                        AsyncArtwork(
                            url: model.imageURL(movie, .primary, height: imageHeight),
                            blurHash: movie.primaryBlurHash,
                            targetBlurHashSize: CGSize(width: 32, height: 48),
                            contentMode: .fill
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))

                // Quick play on hover (PlxNative / Plex style)
                if isHovered {
                    Color.black.opacity(0.35)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    PlayOverlayButton(item: movie)
                }
            }
            // Offline: whatever is not downloaded is dimmed, the rest stays sharp.
            .opacity(model.isServerUnreachable && !model.downloads.downloadedIds.contains(movie.id) ? 0.55 : 1.0)
            .overlay(alignment: .topLeading) { DownloadedBadge(itemId: movie.id).padding(6) }
            .overlay(alignment: .topTrailing) {
                if movie.userData?.played == true {
                    // No shadow (a blurred shadow per visible poster is expensive in a large grid)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, Theme.Colors.watched)
                        .background(Circle().fill(.black.opacity(0.35)).padding(2))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottom) {
                if let fraction = movie.playbackFraction {
                    ProgressBar(fraction: fraction).padding(6)
                }
            }
            .scaleEffect(isHovered ? 1.04 : 1)
            .animation(Theme.Motion.hover, value: isHovered)

            Text(movie.displayTitle)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 6) {
                if let year = movie.productionYear {
                    Text(String(year))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let rating = movie.communityRating, rating > 0 {
                    Text(String(format: "★ %.1f", rating))
                        .font(.subheadline)
                        .foregroundStyle(Theme.Colors.rating)
                }
                // Constant height even without a year or rating
                Text(" ").font(.subheadline)
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(movie.resumeSeconds > 0 ? "Resume playback" : "Play", systemImage: "play.fill") {
                model.play(movie, fromStart: false)
            }
            if movie.resumeSeconds > 0 {
                Button("Play from the beginning", systemImage: "arrow.counterclockwise") {
                    model.play(movie, fromStart: true)
                }
            }
            Divider()
            WatchedMenuItems(movie: movie)
            if movie.isDirectlyPlayable, model.downloads.canDownload {
                if model.downloads.downloadedIds.contains(movie.id) {
                    Button("Delete download", systemImage: "trash") { model.downloads.remove(movie.id) }
                } else if !model.downloads.listedIds.contains(movie.id) {
                    Button("Download", systemImage: "arrow.down.circle") { model.downloads.download([movie]) }
                }
            }
            Divider()
            RouteLink("Details", value: Route.movie(movie.id))
        }
    }
}

/// "Mark as watched" / "Mark as unwatched" of the right-click menus. A started item (even a few minutes) can be
/// marked unwatched: its position is forgotten and it starts again from the beginning next time.
struct WatchedMenuItems: View {
    @Environment(AppModel.self) private var model
    let movie: Movie

    var body: some View {
        // The list may hold an older copy: the state shown is the latest known one.
        let current = model.movie(id: movie.id) ?? movie
        if !current.isWatched {
            Button(current.isAudio ? "Mark as listened" : "Mark as watched", systemImage: "checkmark.circle") {
                Task { await model.setWatched(current, watched: true) }
            }
        }
        if current.canMarkUnwatched {
            Button(current.isAudio ? "Mark as not listened" : "Mark as unwatched", systemImage: "circle") {
                Task { await model.setWatched(current, watched: false) }
            }
        }
    }
}

struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        // No GeometryReader: a scale effect is enough (less layout work per card).
        Capsule().fill(.black.opacity(0.6))
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.Colors.accent).scaleEffect(x: max(0, min(1, fraction)), anchor: .leading)
            }
            .frame(height: 4)
    }
}
