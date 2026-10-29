import SwiftUI
import AppKit

/// PlxNative-style home: a large visual that changes by itself, then horizontal rows
/// (Continue, Up next, then "Recently added" for each library).
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.pageMargins) private var margins

    var body: some View {
        Group {
            if model.heroMovies.isEmpty && !model.isChoosingFeatured {
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
                        if model.heroMovies.isEmpty {
                            // The first titles of the banner are on their way: their place is kept.
                            Color.clear.containerRelativeFrame(.vertical) { height, _ in HeroBanner.height(in: height) }
                        } else {
                            HeroBanner(movies: model.heroMovies)
                        }

                        rows
                            // The banner runs under the sidebar; the rows stay beside it.
                            .padding(.leading, margins.leading)
                    }
                    .padding(.bottom, 40)
                }
                // From the top edge and the left edge of the window, like the Apple TV app: the banner runs under
                // the sidebar, and its height is worked out from the whole window.
                .ignoresSafeArea(edges: [.top, .leading])
            }
        }
        .background(Theme.Colors.background)
        // Banner titles: the current choice at once, then a new one every 30 minutes while the app is active.
        .task(id: scenePhase == .active) {
            await model.loadFeatured()
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                // At least a minute between two tries (offline, the choice cannot be renewed).
                try? await Task.sleep(for: .seconds(max(60, model.featuredTimeLeft + 1)))
                guard !Task.isCancelled else { return }
                await model.loadFeatured()
            }
        }
    }

    /// The rows under the banner.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 30) {
            if !model.resume.isEmpty {
                continueRow("Continue watching", items: model.resume)
            }
            if !model.nextUp.isEmpty {
                continueRow("Up next", items: model.nextUp)
            }
            if !model.favorites.isEmpty {
                // Like the other rows: at most ~20 cards (this stack is not lazy). All of them are under Favourites.
                posterRow("Favourites", items: Array(model.favorites.prefix(20)))
            }
            if model.latestByLibrary.isEmpty {
                if !model.latest.isEmpty { posterRow("Recently added", items: model.latest, opensSeries: true) }
            } else {
                ForEach(model.latestByLibrary, id: \.library.id) { row in
                    posterRow("Recently added in \(row.library.name)", items: row.items, opensSeries: true)
                }
            }
        }
    }

    private func continueRow(_ title: String, items: [Movie]) -> some View {
        Shelf(title: title, cardWidth: Theme.Layout.continueWidth) {
            ForEach(items, id: \.id) { movie in
                RouteLink(value: Route.movie(movie.id)) {
                    ShelfCard(base: Theme.Layout.continueWidth) { ContinueCard(movie: movie, width: $0) }
                }
                .buttonStyle(CardButtonStyle())
            }
        }
    }

    /// `opensSeries`: an episode or a season opens its series ("Recently added", see `Movie.seriesPageId`).
    private func posterRow(_ title: String, items: [Movie], opensSeries: Bool = false) -> some View {
        let ratio = Movie.commonCardAspectRatio(of: items)
        return Shelf(title: title, cardWidth: Theme.Layout.posterWidth) {
            ForEach(items, id: \.id) { movie in
                RouteLink(value: Route.movie(opensSeries ? movie.seriesPageId : movie.id)) {
                    ShelfCard(base: Theme.Layout.posterWidth) {
                        PosterCard(movie: movie, imageHeight: 450, aspectRatio: ratio).frame(width: $0)
                    }
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
    /// Usual width of the cards. Given: the cards are resized a little so that a whole number of them fills the row
    /// (none cut by the window edge), and the arrows move by whole pages of cards. The cards read their width with
    /// `ShelfCard`.
    var cardWidth: CGFloat?
    @ViewBuilder let content: Content
    @StateObject private var scroller = ShelfScroller()
    @State private var rowWidth: CGFloat = 0
    @Environment(\.isPageVisible) private var isPageVisible

    private static var spacing: CGFloat { 18 }

    private var fit: ShelfFit? {
        cardWidth.map { ShelfFit(base: $0, available: rowWidth - 2 * horizontalPadding, spacing: Self.spacing) }
    }

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
                        LazyHStack(alignment: .top, spacing: Self.spacing) { content }
                    } else {
                        HStack(alignment: .top, spacing: Self.spacing) { content }
                    }
                }
                    .environment(\.shelfCardWidth, fit?.cardWidth)
                    .padding(.horizontal, horizontalPadding)
                    // Room for the hover zoom, otherwise the row clips it.
                    .padding(.vertical, 12)
                    .background(ScrollViewFinder(scroller: scroller))
            }
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { rowWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, width in rowWidth = width }
        })
        .onChange(of: fit, initial: true) { _, fit in scroller.page = fit.map { ($0.stride, $0.cardsPerRow) } }
        .onChange(of: isPageVisible, initial: true) { _, visible in scroller.isActive = visible }
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
    /// Fitted rows (see `Shelf.cardWidth`): distance from one card to the next and cards per page. The arrows then
    /// move by whole pages and stop on a card edge.
    var page: (stride: CGFloat, cards: Int)?
    /// False while the row's page is covered by another one: the wheel then goes to the page on top.
    var isActive = true

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
                guard let self, self.isActive, let scrollView = self.scrollView, event.window === scrollView.window,
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
        let wanted = page.map { ShelfFit.pageTarget(from: start, direction: direction, stride: $0.stride, cards: $0.cards,
                                                     origin: minX(of: scrollView)) }
            ?? start + direction * clip.bounds.width * 0.8
        let target = min(max(minX(of: scrollView), wanted), maxX(of: scrollView))
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

/// Card width of a fitted row (pure functions, tested): the whole number of cards closest to their usual width
/// fills the row exactly, so no card is cut by the window edge.
struct ShelfFit: Equatable {
    let cardsPerRow: Int
    let cardWidth: CGFloat
    let stride: CGFloat

    init(base: CGFloat, available: CGFloat, spacing: CGFloat) {
        let room = max(available, base)
        let count = max(1, Int(((room + spacing) / (base + spacing)).rounded()))
        cardsPerRow = count
        cardWidth = ((room - CGFloat(count - 1) * spacing) / CGFloat(count)).rounded(.down)
        stride = cardWidth + spacing
    }

    /// Next page: whole cards further, on a card edge (positions measured from `origin`, the first card).
    static func pageTarget(from x: CGFloat, direction: CGFloat, stride: CGFloat, cards: Int, origin: CGFloat) -> CGFloat {
        let index = ((x - origin) / stride).rounded() + direction * CGFloat(cards)
        return origin + max(0, index) * stride
    }
}

private struct ShelfCardWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// Width of the cards in a fitted `Shelf` (nil elsewhere).
    var shelfCardWidth: CGFloat? {
        get { self[ShelfCardWidthKey.self] }
        set { self[ShelfCardWidthKey.self] = newValue }
    }
}

/// A card of a fitted `Shelf`: gives the width chosen by the row (or the usual one before the row is measured).
struct ShelfCard<Content: View>: View {
    let base: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content
    @Environment(\.shelfCardWidth) private var width

    var body: some View { content(width ?? base) }
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
    @Environment(\.isPageVisible) private var isPageVisible
    @Environment(\.pageMargins) private var margins

    private func backdropURL(_ movie: Movie) -> URL? { model.imageURL(movie, .backdrop, height: 1440) }
    @Environment(\.scenePhase) private var scenePhase

    /// About 70 % of the window, never under 400 pt: the image fills most of the screen, the first row shows below.
    static func height(in windowHeight: CGFloat) -> CGFloat { max(400, windowHeight * 0.7) }

    private var current: Movie { movies[min(index, movies.count - 1)] }
    private var movieIds: [String] { movies.map(\.id) }

    /// Next (1) or previous (-1) title, going round.
    private func step(by offset: Int) {
        guard movies.count > 1 else { return }
        withAnimation(Theme.Motion.hero) { index = (index + offset + movies.count) % movies.count }
    }

    private func heroArrow(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 44, height: 88)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    var body: some View {
        let movie = current
        Color.clear
            // Height proportional to the window (see `height(in:)`): full screen = cinematic visual
            .containerRelativeFrame(.vertical) { height, _ in Self.height(in: height) }
            .frame(maxWidth: .infinity)
            .overlay {
                AsyncArtwork(
                    url: backdropURL(movie),
                    blurHash: movie.backdropBlurHash,
                    targetBlurHashSize: CGSize(width: 64, height: 36),
                    content: { image in
                        // Fills the banner, aligned on its top edge: what is cropped is the bottom, under the
                        // gradient and the text (centred across when the window is narrow).
                        image.resizable().scaledToFill()
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                    },
                    placeholder: { Theme.Colors.background }
                )
                .id(movie.id)
                .transition(.opacity)
            }
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
                        RouteLink(value: Route.movie(movie.id)) {
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
                // The image runs under the sidebar, the text stays beside it.
                .padding(.leading, margins.leading)
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
            // Previous / next title, like the Apple TV app: arrows on the sides (shown under the pointer)…
            .overlay {
                if movies.count > 1 {
                    HStack {
                        heroArrow("chevron.left", help: "Previous") { step(by: -1) }
                        Spacer()
                        heroArrow("chevron.right", help: "Next") { step(by: 1) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.leading, margins.leading)
                    .opacity(isHovered ? 1 : 0)
                    .animation(Theme.Motion.hover, value: isHovered)
                }
            }
            // …and a two-finger swipe over the banner (not over the sidebar, which covers its left part).
            .background(
                HorizontalSwipeReader(isActive: isPageVisible && movies.count > 1) { step(by: $0) }
                    .padding(.leading, margins.leading)
            )
            .onHover { isHovered = $0 }
            // New titles (every 30 minutes): from the first one.
            .onChange(of: movieIds) { _, _ in index = 0 }
            // Preloads the next image: the fade goes to the real image, not to a BlurHash then the image.
            .task(id: index) {
                guard movies.count > 1 else { return }
                let next = movies[(index + 1) % movies.count]
                if let url = backdropURL(next) {
                    _ = try? await ImageCache.shared.loadImage(forKey: ImageCache.shared.cacheKey(for: url), from: url)
                }
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
    var width: CGFloat = Theme.Layout.continueWidth
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
                .frame(width: width, height: width * 9 / 16)
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
        .frame(width: width, alignment: .leading)
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
            RouteLink("Details", value: Route.movie(movie.id))
        }
    }
}

/// What a trackpad gesture turned out to be (see `HorizontalSwipeReader`).
private enum SwipeDecision { case undecided, horizontal, vertical }

/// A two-finger horizontal swipe over this view: `onSwipe(1)` towards the next item (fingers to the left), `-1`
/// towards the previous one. One step per gesture; vertical gestures keep scrolling the page.
struct HorizontalSwipeReader: NSViewRepresentable {
    let isActive: Bool
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak coordinator] event in
            let used = MainActor.assumeIsolated { coordinator?.handle(event) ?? false }
            return used ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onSwipe = onSwipe
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var isActive = false
        var onSwipe: (Int) -> Void = { _ in }
        /// Movement of the current gesture, until it is clearly horizontal (or vertical).
        private var travel = CGSize.zero
        private var decision = SwipeDecision.undecided

        /// True when the event belongs to a horizontal swipe over the view (it then goes no further).
        func handle(_ event: NSEvent) -> Bool {
            if event.phase == .began {
                travel = .zero
                decision = .undecided
            }
            // Only the fingers on the trackpad (not the momentum after them, nor a mouse wheel).
            guard isActive, event.phase == .began || event.phase == .changed,
                  let view, let window = view.window, event.window === window, !view.isHiddenOrHasHiddenAncestor,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            else { return decision == .horizontal && event.momentumPhase != [] }

            switch decision {
            case .vertical:
                return false
            case .horizontal:
                return true
            case .undecided:
                travel.width += event.scrollingDeltaX
                travel.height += event.scrollingDeltaY
                guard abs(travel.width) + abs(travel.height) > 12 else { return false }
                guard abs(travel.width) > abs(travel.height) * 1.5 else {
                    decision = .vertical
                    return false
                }
                decision = .horizontal
                // Content moving right (fingers to the right): the previous item.
                onSwipe(travel.width > 0 ? -1 : 1)
                return true
            }
        }
    }
}
