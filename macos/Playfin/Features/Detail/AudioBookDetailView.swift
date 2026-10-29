import SwiftUI

private let detailBackground = Theme.Colors.background

/// Detail page of an audiobook: large square cover, information, resume and playback.
struct AudioBookDetailView: View {
    @Environment(AppModel.self) private var model
    let item: Movie

    private var current: Movie { model.movie(id: item.id) ?? item }

    var body: some View {
        ScrollView {
            // Narrow window: the cover goes above the text instead of squashing it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 40) {
                    cover
                    info.frame(minWidth: 380)
                }
                VStack(alignment: .leading, spacing: 28) {
                    cover
                    info
                }
            }
            .padding(.horizontal, Theme.Spacing.screenMargin)
            .padding(.top, 40)
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { coverBackground }
        .onKeyPress(.space) {
            model.play(current, fromStart: false)
            return .handled
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(current.name)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 2)
                .lineLimit(3)

            if let people = current.starringText {
                Text(people)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
            }

            metaLine
            DetailInfoLine(parts: [], fileItemId: current.id)

            DetailRatingsRow(movie: current)

            if let overview = current.overview, !overview.isEmpty {
                ExpandableOverview(text: overview, lineLimit: 6, maxWidth: 640)
            }

            progressInfo
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cover: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncArtwork(
                    url: model.imageURL(current, .primary, height: 700),
                    blurHash: current.primaryBlurHash,
                    targetBlurHashSize: CGSize(width: 32, height: 32),
                    contentMode: .fill
                ) {
                    Color.white.opacity(0.08).overlay(
                        Image(systemName: "headphones").font(.system(size: 60)).foregroundStyle(.white.opacity(0.4))
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel))
            .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 8)
            .frame(width: 300, height: 300)
    }

    /// Background: the cover's BlurHash, already blurry by nature (no full-screen blur filter to recompute).
    private var coverBackground: some View {
        ZStack {
            detailBackground
            if let hash = current.primaryBlurHash, let image = renderBlurHash(blurHash: hash, width: 32, height: 32) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.5)
                    .overlay(detailBackground.opacity(0.55))
            }
        }
        .clipped()
        .ignoresSafeArea()
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            Text("Audiobook")
            if let year = current.productionYear {
                Text("·").foregroundStyle(.white.opacity(0.5))
                Text(String(year))
            }
            if let duration = current.formattedDuration {
                Text("·").foregroundStyle(.white.opacity(0.5))
                Text(duration)
            }
            ForEach(current.genres.prefix(2), id: \.self) { genre in
                Text("·").foregroundStyle(.white.opacity(0.5))
                Text(genre)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.85))
    }

    @ViewBuilder
    private var progressInfo: some View {
        if let fraction = current.playbackFraction, current.resumeSeconds > 0 {
            VStack(alignment: .leading, spacing: 6) {
                ProgressBar(fraction: fraction).frame(width: 320)
                Text("Resume at \(Self.clock(current.resumeSeconds)) · \(Int(fraction * 100))% listened")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 14) {
            PlayButton(title: current.resumeSeconds > 0 ? "Resume" : "Listen") { play(fromStart: false) }
                .keyboardShortcut(.defaultAction) // Return plays

            if current.resumeSeconds > 0 {
                DetailCircleButton(systemName: "arrow.counterclockwise", caption: "Restart", help: "Listen from the beginning") {
                    play(fromStart: true)
                }
            }

            DetailCircleButton(
                systemName: current.isWatched ? "checkmark.circle.fill" : "checkmark",
                tint: current.isWatched ? Theme.Colors.watched : .white,
                caption: "Listened",
                help: current.isWatched ? "Mark as not listened" : "Mark as listened",
                action: toggleWatched
            )

            DownloadButton(item: current)
        }
        .padding(.top, 6)
    }

    private func play(fromStart: Bool) { model.play(current, fromStart: fromStart) }
    private func toggleWatched() { Task { await model.toggleWatched(current) } }

    /// 3725 s -> "1 h 02 min 05 s".
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d h %02d min %02d s", h, m, s) : String(format: "%d min %02d s", m, s)
    }
}

/// Page of an item that groups others (author, book series, album, folder): its content as a grid.
struct FolderDetailView: View {
    @Environment(AppModel.self) private var model
    let folder: Movie

    @State private var children: [Movie] = []
    @State private var isLoading = true

    private var current: Movie { model.movie(id: folder.id) ?? folder }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(current.name)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if let overview = current.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(5)
                        .frame(maxWidth: 720, alignment: .leading)
                }

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if children.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(EmptyStateText.message(
                            isOffline: model.isServerUnreachable,
                            offline: "Offline: the content of this folder has not been saved on this Mac.",
                            online: "This folder is empty."))
                            .foregroundStyle(.white.opacity(0.6))
                        Button("Try again") { Task { await reloadChildren() } }
                    }
                    .padding(.top, 20)
                } else {
                    Text(children.count > 1 ? "\(children.count) items" : "1 item")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20, alignment: .top)], spacing: 24) {
                        ForEach(children, id: \.id) { child in
                            RouteLink(value: Route.movie(child.id)) {
                                PosterCard(movie: child)
                            }
                            .buttonStyle(CardButtonStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.screenMargin)
            .padding(.top, 40)
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { detailBackground.ignoresSafeArea() }
        .task(id: folder.id) { await reloadChildren() }
    }

    private func reloadChildren() async {
        isLoading = true
        children = await model.children(of: folder.id)
        isLoading = false
    }
}
