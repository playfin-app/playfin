import SwiftUI

/// The pages one can navigate deeper into from a section.
enum Route: Hashable {
    case movie(String)
    /// Everything a person acts in (or directed), across the user's libraries.
    case person(id: String, name: String)
}

/// Main view organised around a sidebar (NavigationSplitView), PlxNative style.
struct LibraryView: View {
    @Environment(AppModel.self) private var model

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Pages opened over the first page of the visible section, the last one on top (see `OpenedPage`).
    @State private var pages: [OpenedPage] = []
    /// Section on screen. It follows `model.selectedSection` with a fade.
    @State private var displayedSection: AppModel.SidebarSection?
    /// While a page fades in, the one under it stays drawn: the two cross-fade.
    @State private var showsPageBelow = false
    @State private var swipe = SwipeBack()
    /// Key of the first page of the section for `SwipeBack` (the opened pages have their own).
    @State private var rootPageID = UUID()
    @Environment(\.scenePhase) private var scenePhase
    /// The window is in full screen (see `FullScreenReader`).
    @State private var isFullScreen = false
    /// Sidebar state before full screen, given back when leaving it.
    @State private var columnVisibilityBeforeFullScreen: NavigationSplitViewVisibility?

    private var section: AppModel.SidebarSection { displayedSection ?? model.selectedSection }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                if model.isServerUnreachable {
                    OfflineBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                ZStack {
                    // Another section: another stack, which fades in over the old one.
                    pageStack
                        .id(section)
                        .transition(.opacity)
                }
            }
            // Like the Apple TV app: no page title (the sidebar already says where one is) and no toolbar
            // background (it showed as a dark band once a grid had scrolled under it). The window keeps its
            // buttons and the sidebar button; in full screen, no toolbar at all (macOS gave it its own band).
            // The Back button is in the pages (see `PageBackButton`).
            .modifier(HiddenToolbarTitle(title: title))
            .toolbarBackground(.hidden, for: .windowToolbar)
            .toolbar(isFullScreen ? .hidden : .automatic, for: .windowToolbar)
            .onAppear { displayedSection = model.selectedSection }
            // The new section opens on its first page, with a fade.
            .onChange(of: model.selectedSection) { _, newSection in
                guard newSection != displayedSection else { return }
                withAnimation(Theme.Motion.page) {
                    displayedSection = newSection
                    pages = []
                }
            }
            // A click on the section already shown: back to its first page.
            .onChange(of: model.sectionRootRequests) { _, _ in
                guard model.selectedSection == section, !pages.isEmpty else { return }
                withAnimation(Theme.Motion.page) { pages = [] }
            }
            .onChange(of: model.goBackRequests) { _, _ in
                _ = goBack()
            }
            .onChange(of: model.openRequests) { _, _ in
                if let route = model.requestedRoute { open(route) }
            }
            .animation(Theme.Motion.standard, value: model.isServerUnreachable)
            // A single background for all screens: nothing changes tint while navigating.
            .background(Theme.Colors.background.ignoresSafeArea())
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { model.offlineAlertMessage != nil },
                    set: { if !$0 { model.offlineAlertMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.offlineAlertMessage ?? "")
            }
        }
        // The page keeps its size when the sidebar shows over it (full screen, see below).
        .navigationSplitViewStyle(.prominentDetail)
        // Full screen: the sidebar is hidden, and shows over the page when the pointer reaches the left edge.
        .onChange(of: isFullScreen) { _, fullScreen in
            if fullScreen {
                columnVisibilityBeforeFullScreen = columnVisibility
                columnVisibility = .detailOnly
            } else {
                columnVisibility = columnVisibilityBeforeFullScreen ?? .all
                columnVisibilityBeforeFullScreen = nil
            }
        }
        .background(FullScreenReader(isFullScreen: $isFullScreen))
        // Escape, two-finger swipe, mouse back button: back to the previous page. Placed outside the columns:
        // the detail column is rebuilt when pages change, and a view inside it could lose its window.
        .background(GoBackMonitor(
            canGoBack: { canGoBack },
            goBack: { goBack() },
            swipeBegan: { swipeBegan() },
            swipeMoved: { swipe.move(to: $0) },
            swipeEnded: { swipeEnded(goingBack: $0) }
        ))
    }

    /// The first page of the section, then the opened pages over it. Only the top one is shown and can be used;
    /// the one under it shows while a page fades in (`showsPageBelow`) and during a swipe.
    private var pageStack: some View {
        // The pages cover the column, under the toolbar and the sidebar too (like the page images). The margins
        // they must keep clear are read here and given to each page: left to work them out in their own view,
        // a hidden or new page had other margins for a moment, then moved into place.
        GeometryReader { safe in
            let safeFrame = safe.frame(in: .global)
            GeometryReader { full in
                // Full screen: the sidebar shows over the page, which keeps its layout.
                let margins = Self.margins(of: safeFrame, in: full.frame(in: .global), sidebarOverPage: isFullScreen)
                ZStack {
                    page(id: rootPageID, depth: 0, margins: margins) { rootView }
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        self.page(id: page.id, depth: index + 1, margins: margins) { routeContent(for: page.route) }
                            .transition(.opacity)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    /// Margins between the area pages may use (`safe`) and the whole column (`full`): toolbar, sidebar.
    /// `sidebarOverPage`: no margin for the sidebar, which then shows over the page.
    static func margins(of safe: CGRect, in full: CGRect, sidebarOverPage: Bool = false) -> EdgeInsets {
        EdgeInsets(
            top: max(0, safe.minY - full.minY),
            leading: sidebarOverPage ? 0 : max(0, safe.minX - full.minX),
            bottom: max(0, full.maxY - safe.maxY),
            trailing: max(0, full.maxX - safe.maxX)
        )
    }

    private func page(id: UUID, depth: Int, margins: EdgeInsets, @ViewBuilder content: () -> some View) -> some View {
        let isTop = depth == pages.count
        let isBelow = depth == pages.count - 1
        let isShown = isTop || (isBelow && (showsPageBelow || swipe.isActive))
        return PageHost(
            id: id,
            isShown: isShown,
            swipe: swipe,
            content: content()
                // An opened page has its Back button at the top left: it moves with the page during a swipe.
                .overlay(alignment: .topLeading) {
                    if depth > 0 { PageBackButton() }
                }
                // Opaque: nothing of the page below shows through.
                .background(Theme.Colors.background.ignoresSafeArea())
                // The page is in its own view: what it reads from its surroundings is passed here.
                .environment(model)
                .environment(\.isPageVisible, isTop)
                .environment(\.pageMargins, margins)
                // The window buttons and the sidebar button sit over the top left of the page when the sidebar is
                // hidden (in a window: in full screen, there is no toolbar).
                .environment(\.hasWindowControlsOverPage, !isFullScreen && margins.leading < 1)
                .environment(\.scenePhase, scenePhase)
                .tint(Theme.Colors.accent)
                .safeAreaPadding(margins)
        )
        // Only the fades are animated, never the page's size: a page appearing during an animation grew from
        // nothing to its size, and its content moved into place in front of the user.
        .transaction { $0.animation = nil }
        .allowsHitTesting(isTop && !swipe.isActive)
        .accessibilityHidden(!isTop)
    }

    @ViewBuilder
    private var rootView: some View {
        switch section {
        case .home: HomeView()
        case .movies: MoviesGridView()
        case .library(let libId): LibraryGridView(libraryId: libId)
        case .search: SearchView()
        case .favorites: FavoritesView()
        case .downloads: DownloadsView()
        }
    }

    private var title: String {
        if let page = pages.last {
            switch page.route {
            case .movie(let id): return model.movie(id: id)?.name ?? ""
            case .person(_, let name): return name
            }
        }
        switch section {
        case .home: return "Home"
        case .movies: return "Movies"
        case .library(let libId): return model.libraries.first(where: { $0.id == libId })?.name ?? "Library"
        case .search: return "Search"
        case .favorites: return "Favourites"
        case .downloads: return "Downloads"
        }
    }

    /// True when the visible section has a page to close (never during playback).
    private var canGoBack: Bool {
        model.playback == nil && !pages.isEmpty && !swipe.isActive
    }

    /// Opens a page over the current one: it fades in, the current one staying drawn under it meanwhile.
    private func open(_ route: Route) {
        guard model.playback == nil, !swipe.isActive else { return }
        showsPageBelow = true
        withAnimation(Theme.Motion.page) {
            pages.append(OpenedPage(route: route))
        } completion: {
            showsPageBelow = false
        }
    }

    /// Closes the current page: it fades out over the previous one. False when there is nothing to close
    /// (or during playback).
    private func goBack() -> Bool {
        guard canGoBack else { return false }
        withAnimation(Theme.Motion.page) { _ = pages.popLast() }
        return true
    }

    private func swipeBegan() {
        guard let top = pages.last else { return }
        let below = pages.count >= 2 ? pages[pages.count - 2].id : rootPageID
        swipe.begin(top: top.id, below: below)
    }

    /// `goingBack`: the page has left on the right, the previous one is already in its place.
    private func swipeEnded(goingBack: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if goingBack { _ = pages.popLast() }
            swipe.finish(pageClosed: goingBack)
        }
    }

    @ViewBuilder
    private func routeContent(for route: Route) -> some View {
        switch route {
        case .movie(let id):
            // `ItemLoaderView` is what reads the item: this page is not rebuilt each time the model changes.
            ItemLoaderView(id: id)
        case .person(let id, let name):
            PersonView(personId: id, name: name)
        }
    }
}

/// The window keeps its title (Window menu, Mission Control), but the toolbar does not show it. On macOS 14,
/// which cannot hide it, the title is left empty.
private struct HiddenToolbarTitle: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.navigationTitle(title).toolbar(removing: .title)
        } else {
            content.navigationTitle("")
        }
    }
}

/// Follows whether the window of this view is in full screen.
private struct FullScreenReader: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.view = view
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            let center = NotificationCenter.default
            coordinator.observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak coordinator] note in
                MainActor.assumeIsolated {
                    guard let coordinator, let window = note.object as? NSWindow, window === coordinator.view?.window else { return }
                    coordinator.isFullScreen.wrappedValue = name == NSWindow.didEnterFullScreenNotification
                }
            })
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isFullScreen = $isFullScreen
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.observers.forEach(NotificationCenter.default.removeObserver)
        coordinator.observers = []
    }

    func makeCoordinator() -> Coordinator { Coordinator(isFullScreen: $isFullScreen) }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var isFullScreen: Binding<Bool>
        var observers: [NSObjectProtocol] = []

        init(isFullScreen: Binding<Bool>) {
            self.isFullScreen = isFullScreen
        }
    }
}

/// Loads the record of an item that is not in memory yet, then shows the right page.
struct ItemLoaderView: View {
    @Environment(AppModel.self) private var model
    let id: String
    @State private var failed = false

    var body: some View {
        Group {
            if let movie = model.movie(id: id) {
                if movie.isSeries {
                    SeriesDetailView(series: movie)
                } else if movie.isAudio {
                    AudioBookDetailView(item: movie)
                } else if movie.isContainer {
                    FolderDetailView(folder: movie)
                } else {
                    MovieDetailView(movie: movie)
                }
            } else if failed {
                ErrorStateView(
                    title: "Item not found",
                    message: "This item is no longer available, or the server is not responding.",
                    systemImage: "questionmark.folder",
                    retry: { failed = false; Task { await load() } }
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private func load() async {
        await model.loadDetails(of: id)
        if model.movie(id: id) == nil { failed = true }
    }
}

extension EnvironmentValues {
    /// False when another page is opened over this one: a covered page stays alive (scroll position…, see
    /// `OpenedPage`), so its periodic work must pause by itself. During playback, a page that works
    /// periodically also reads `model.playback` (an environment value changed at the root would make the whole
    /// interface walk through it at every open and close of the player).
    @Entry var isPageVisible = true
    /// Margins of the pages (sidebar, top of the window): for what goes under them on purpose, like the home
    /// banner, while its text stays clear.
    @Entry var pageMargins = EdgeInsets()
    @Entry var hasWindowControlsOverPage = false
}
