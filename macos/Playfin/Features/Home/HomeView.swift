import SwiftUI
import AppKit

/// PlxNative-style home: a large visual that changes by itself, then horizontal rows
/// (Continue, Up next, then "Recently added" for each library).
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.heroMovies.isEmpty {
                ErrorStateView(
                    title: model.isServerUnreachable ? "No saved content" : "Nothing to show yet",
                    message: EmptyStateText.message(
                        isOffline: model.isServerUnreachable,
                        offline: "The server is unreachable. Downloaded items remain available in "
                            + "Downloads.",
                        online: "Add movies or series to your Jellyfin library, then refresh."),
                    systemImage: model.isServerUnreachable ? "wifi.slash" : "film",
                    retry: { Task { await model.retryConnection() } })
            } else {
                ScrollView {
                    // Not lazy (a few rows of at most ~20 cards): the prefetch of a LazyVStack never settled
                    // here during playback and froze the app (two `sample`s of the frozen app).
                    VStack(alignment: .leading, spacing: 30) {
                        HeroBanner(movies: model.heroMovies)

                        if !model.resume.isEmpty {
                            continueRow("Continue watching", items: model.resume)
                        }
                        if !model.nextUp.isEmpty {
                            continueRow("Up next", items: model.nextUp)
                        }
                        if model.latestByLibrary.isEmpty {
                            if !model.latest.isEmpty { posterRow("Recently added", items: model.latest) }
                        } else {
                            ForEach(model.latestByLibrary, id: \.library.id) { row in
                                posterRow("Recently added in \(row.library.name)", items: row.items)
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .background(Theme.Colors.background)
    }

    private func continueRow(_ title: String, items: [Movie]) -> some View {
        Shelf(title: title) {
            ForEach(items, id: \.id) { movie in
                NavigationLink(value: Route.movie(movie.id)) {
                    ContinueCard(movie: movie)
                }
                .buttonStyle(CardButtonStyle())
            }
        }
    }

    private func posterRow(_ title: String, items: [Movie]) -> some View {
        let ratio = Movie.commonCardAspectRatio(of: items)
        return Shelf(title: title) {
            ForEach(items, id: \.id) { movie in
                NavigationLink(value: Route.movie(movie.id)) {
                    PosterCard(movie: movie, imageHeight: 450, aspectRatio: ratio)
                        .frame(width: Theme.Layout.posterWidth)
                }
                .buttonStyle(CardButtonStyle())
            }
        }
    }
}

/// A row that scrolls horizontally, with its title and arrows. A mouse wheel makes it
/// scroll sideways.
struct Shelf<Content: View>: View {
    let title: String
    var horizontalPadding: CGFloat = Theme.Spacing.screenMargin
    var titleColor: Color = .primary
    /// Lazy only for cards of a fixed size (episodes: a season can hold hundreds). A lazy row takes the
    /// height of the cards it has loaded: with cards of different heights (posters 2:3, albums 1:1…), its
    /// prefetch changed the row height on every pass, the home was laid out again in an endless loop
    /// and the app froze.
    var isLazy = false
    @ViewBuilder let content: Content
    @StateObject private var scroller = ShelfScroller()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(Theme.Typography.section).foregroundStyle(titleColor).lineLimit(1)
                Spacer()
                HStack(spacing: 6) {
                    arrowButton(systemName: "chevron.left", enabled: scroller.canScrollBack, help: "Previous") {
                        scroller.scroll(by: -1)
                    }
                    arrowButton(systemName: "chevron.right", enabled: scroller.canScrollForward, help: "Next") {
                        scroller.scroll(by: 1)
                    }
                }
                .opacity(scroller.canScrollBack || scroller.canScrollForward ? 1 : 0)
            }
            .padding(.horizontal, horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if isLazy {
                        LazyHStack(alignment: .top, spacing: 18) { content }
                    } else {
                        HStack(alignment: .top, spacing: 18) { content }
                    }
                }
                    .padding(.horizontal, horizontalPadding)
                    // Room for the hover zoom, otherwise the row clips it.
                    .padding(.vertical, 12)
                    .background(ScrollViewFinder(scroller: scroller))
            }
        }
    }

    private func arrowButton(systemName: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(titleColor)
                .frame(width: 26, height: 26)
                .background(Circle().fill(titleColor.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Scrolls a horizontal row by one "page" at a time and tells whether one can still go each way.
@MainActor
final class ShelfScroller: ObservableObject {
    @Published var canScrollBack = false
    @Published var canScrollForward = false
    private weak var scrollView: NSScrollView?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var wheelMonitor: Any?
    private var pendingTargetX: CGFloat?

    func attach(_ scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        self.scrollView = scrollView

        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView?.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateState() }
        })
        if let document = scrollView.documentView {
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateState() }
            })
        }
        installWheelMonitor()
        updateState()
    }

    /// Mouse wheel over the row: it scrolls the row horizontally (a mouse has no
    /// horizontal scrolling). The trackpad keeps its native behaviour. At the ends, the page scrolls normally.
    private func installWheelMonitor() {
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let scrollView = self.scrollView, event.window === scrollView.window,
                      scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil)),
                      let delta = ShelfWheel.horizontalDelta(
                        deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                        isPrecise: event.hasPreciseScrollingDeltas
                      )
                else { return event }
                let clip = scrollView.contentView
                let current = clip.bounds.origin.x
                let target = min(max(self.minX(of: scrollView), current + delta), self.maxX(of: scrollView))
                guard abs(target - current) > 0.5 else { return event } // at the end: the page scrolls
                self.pendingTargetX = nil
                clip.setBoundsOrigin(NSPoint(x: target, y: clip.bounds.origin.y))
                scrollView.reflectScrolledClipView(clip)
                return nil
            }
        }
    }

    func updateState() {
        guard let scrollView else { return }
        let x = scrollView.contentView.bounds.origin.x
        // Only write if the value changes: a @Published notifies SwiftUI even for the same value,
        // which would redraw the whole row on every frame of the scroll.
        let back = x > minX(of: scrollView) + 1
        let forward = x < maxX(of: scrollView) - 1
        if back != canScrollBack { canScrollBack = back }
        if forward != canScrollForward { canScrollForward = forward }
    }

    /// Leftmost position: negative when the sidebar covers the content (automatic margin),
    /// otherwise the first poster would stay hidden underneath.
    private func minX(of scrollView: NSScrollView) -> CGFloat {
        -scrollView.contentView.contentInsets.left
    }

    private func maxX(of scrollView: NSScrollView) -> CGFloat {
        let documentWidth = scrollView.documentView?.frame.width ?? 0
        return max(minX(of: scrollView), documentWidth - scrollView.contentView.bounds.width + scrollView.contentView.contentInsets.right)
    }

    /// `direction`: -1 towards the left, 1 towards the right. Moves by 80% of the visible width.
    /// Quick clicks add up: we start from the current destination, not from the position on screen.
    func scroll(by direction: CGFloat) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let start = pendingTargetX ?? clip.bounds.origin.x
        let target = min(max(minX(of: scrollView), start + direction * clip.bounds.width * 0.8), maxX(of: scrollView))
        pendingTargetX = target
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            clip.animator().setBoundsOrigin(NSPoint(x: target, y: clip.bounds.origin.y))
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.pendingTargetX == target { self?.pendingTargetX = nil }
            }
        })
        scrollView.reflectScrolledClipView(clip)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
    }
}

/// Conversion of the mouse wheel into horizontal scrolling of the rows (pure function, tested).
enum ShelfWheel {
    /// Points travelled per wheel notch.
    static let pointsPerLine: CGFloat = 60

    /// Horizontal offset to apply, or nil if the event must keep its normal effect
    /// (trackpad, or gesture already horizontal).
    static func horizontalDelta(deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool) -> CGFloat? {
        guard !isPrecise, deltaY != 0, abs(deltaY) > abs(deltaX) else { return nil }
        return -deltaY * pointsPerLine
    }
}

/// Finds the `NSScrollView` that contains the row, so it can be scrolled with the arrows.
private struct ScrollViewFinder: NSViewRepresentable {
    let scroller: ShelfScroller

    func makeNSView(context: Context) -> NSView { FinderView(scroller: scroller) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FinderView: NSView {
        let scroller: ShelfScroller
        init(scroller: ShelfScroller) {
            self.scroller = scroller
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.enclosingScrollView else { return }
                MainActor.assumeIsolated { self.scroller.attach(scrollView) }
            }
        }
    }
}

/// Large visual at the top of the home (PlxNative style): full-bleed background, title logo, gradients to the
/// app background. Changes every 15 seconds, except on hover, with the window inactive or the home covered (player, page).
struct HeroBanner: View {
    @Environment(AppModel.self) private var model
    let movies: [Movie]
    @State private var index = 0
    @State private var isHovered = false
    /// Subject of each image (see `FocalPoint`), by item: the image is framed on it rather than on its centre.
    @State private var framings: [String: FocalPoint.Framing] = [:]
    @Environment(\.isPageVisible) private var isPageVisible

    /// Where the subject goes: in the upper part (the bottom fades into the rows and holds the text), a little to the
    /// right of the middle (the text is on the left).
    private static let subjectTarget = CGPoint(x: 0.62, y: 0.36)

    private func backdropURL(_ movie: Movie) -> URL? { model.imageURL(movie, .backdrop, height: 1440) }

    /// Analyses an image once and keeps its framing; the first time, the image glides to it.
    private func loadFraming(_ movie: Movie) async {
        guard framings[movie.id] == nil, let framing = await FocalPointCache.shared.framing(for: backdropURL(movie))
        else { return }
        withAnimation(.easeInOut(duration: 0.8)) { framings[movie.id] = framing }
    }
    @Environment(\.scenePhase) private var scenePhase

    private var current: Movie { movies[min(index, movies.count - 1)] }

    var body: some View {
        let movie = current
        Color.clear
            // Height proportional to the window (≈ 58%), never under 400 pt: full screen = cinematic visual
            .containerRelativeFrame(.vertical) { height, _ in max(400, height * 0.58) }
            .frame(maxWidth: .infinity)
            .overlay {
                let framing = framings[movie.id] ?? FocalPointCache.shared.cachedFraming(for: backdropURL(movie))
                AsyncArtwork(
                    url: backdropURL(movie),
                    blurHash: movie.backdropBlurHash,
                    targetBlurHashSize: CGSize(width: 64, height: 36),
                    content: { image in FocusedFillImage(image: image, framing: framing, target: Self.subjectTarget) },
                    placeholder: { Theme.Colors.background }
                )
                .id(movie.id)
                .transition(.opacity)
            }
            .task(id: movie.id) { await loadFraming(movie) }
            .clipped()
            // Gradient downwards to the app background (no seam with the rows)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.35),
                        .init(color: Theme.Colors.background.opacity(0.75), location: 0.78),
                        .init(color: Theme.Colors.background, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            // Gradient on the left: the text stays readable on a light image
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: Theme.Colors.background.opacity(0.85), location: 0),
                        .init(color: Theme.Colors.background.opacity(0.35), location: 0.45),
                        .init(color: .clear, location: 0.75)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    MovieLogoOrTitle(movie: movie, logoOwnerIsSeries: true, maxLogoHeight: 120, titleFont: Theme.Typography.hero)
                        .frame(maxWidth: 520, alignment: .leading)
                    if let subtitle = movie.episodeSubtitle {
                        Text(subtitle).font(.title3.weight(.semibold)).foregroundStyle(Theme.Colors.textSecondary).lineLimit(1)
                    }
                    Text(movie.infoLine).font(.callout).foregroundStyle(Theme.Colors.textSecondary).lineLimit(1)
                    if let overview = movie.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.body)
                            .foregroundStyle(Theme.Colors.textPrimary.opacity(0.9))
                            .lineLimit(2)
                            .frame(maxWidth: 620, alignment: .leading)
                    }
                    HStack(spacing: 12) {
                        PlayButton(title: movie.resumeSeconds > 0 ? "Resume" : "Play") {
                            model.play(movie, fromStart: false)
                        }
                        NavigationLink(value: Route.movie(movie.id)) {
                            Label("Details", systemImage: "info.circle")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 11)
                                .background(Capsule().fill(Color.white.opacity(0.18)))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                    .padding(.top, 4)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.screenMargin)
                .padding(.bottom, 28)
                .id(movie.id)
                .transition(.opacity)
            }
            .overlay(alignment: .bottomTrailing) {
                if movies.count > 1 {
                    HStack(spacing: 2) {
                        ForEach(movies.indices, id: \.self) { i in
                            Button {
                                withAnimation(Theme.Motion.hero) { index = i }
                            } label: {
                                Capsule()
                                    .fill(i == index ? Color.white : Color.white.opacity(0.35))
                                    .frame(width: i == index ? 18 : 7, height: 7)
                                    .frame(width: 24, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Item \(i + 1) of \(movies.count)")
                        }
                    }
                    .animation(Theme.Motion.standard, value: index)
                    .padding(.horizontal, Theme.Spacing.screenMargin)
                    .padding(.bottom, 32)
                }
            }
            .onHover { isHovered = $0 }
            // Preloads the next image and its framing: the fade goes to a real image already framed, not to a
            // BlurHash then a jump.
            .task(id: index) {
                guard movies.count > 1 else { return }
                let next = movies[(index + 1) % movies.count]
                if let url = backdropURL(next) {
                    _ = try? await ImageCache.shared.loadImage(forKey: ImageCache.shared.cacheKey(for: url), from: url)
                }
                if let framing = await FocalPointCache.shared.framing(for: backdropURL(next)) { framings[next.id] = framing }
            }
            // No rotation (neither decoding nor fade) if the home is covered (opened page), during playback or with
            // the window inactive: the loop only runs while all hold, and restarts when they change (an environment
            // value read inside a running task would stay at its value of the start).
            .task(id: isPageVisible && scenePhase == .active && model.playback == nil) {
                guard isPageVisible, scenePhase == .active, model.playback == nil else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled, !isHovered, movies.count > 1 else { continue }
                    withAnimation(Theme.Motion.hero) { index = (index + 1) % movies.count }
                }
            }
    }
}

/// 16:9 "Continue" / "Up next" card: thumbnail, progress, remaining time.
struct ContinueCard: View {
    @Environment(AppModel.self) private var model
    let movie: Movie
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                AsyncArtwork(
                    url: movie.itemType == "Episode"
                        ? model.episodeThumbnailURL(movie, height: 400)
                        : model.imageURL(movie, .backdrop, height: 400),
                    blurHash: movie.backdropBlurHash,
                    targetBlurHashSize: CGSize(width: 48, height: 27),
                    contentMode: .fill
                )
                .frame(width: Theme.Layout.continueWidth, height: Theme.Layout.continueWidth * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))

                if isHovered {
                    Color.black.opacity(0.3)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    PlayOverlayButton(item: movie, size: 40)
                }
            }
            .opacity(model.isServerUnreachable && !model.downloads.downloadedIds.contains(movie.id) ? 0.55 : 1.0)
            .overlay(alignment: .bottom) {
                if let fraction = movie.playbackFraction {
                    ProgressBar(fraction: fraction).padding(8)
                }
            }
            .overlay(alignment: .topLeading) { DownloadedBadge(itemId: movie.id).padding(6) }
            .scaleEffect(isHovered ? 1.03 : 1)
            .animation(Theme.Motion.hover, value: isHovered)

            Text(movie.displayTitle).font(.headline).lineLimit(1)
            Text(movie.episodeSubtitle ?? movie.remainingText ?? " ")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: Theme.Layout.continueWidth, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Resume playback", systemImage: "play.fill") {
                model.play(movie, fromStart: false)
            }
            Button("Play from the beginning", systemImage: "arrow.counterclockwise") {
                model.play(movie, fromStart: true)
            }
            Divider()
            WatchedMenuItems(movie: movie)
            Divider()
            NavigationLink("Details", value: Route.movie(movie.id))
        }
    }
}
