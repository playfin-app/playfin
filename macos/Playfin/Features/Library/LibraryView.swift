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
    /// Search field of the movie grids: in the toolbar here, the grids being in their own views (see `PageHost`).
    @State private var gridSearch = ""
    @AppStorage("libraryCardSize") private var cardSizeRaw = CardSize.medium.rawValue
    @Environment(\.scenePhase) private var scenePhase

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
            .navigationTitle(title)
            .background { gridSearchField }
            .toolbar {
                if pages.isEmpty, case .library = section {
                    ToolbarItem {
                        Picker("Poster size", selection: $cardSizeRaw) {
                            ForEach(CardSize.allCases) { size in
                                Label(size.rawValue, systemImage: size.icon).tag(size.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .help("Poster size")
                    }
                }
                if !pages.isEmpty {
                    ToolbarItem(placement: .navigation) {
                        Button { _ = goBack() } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .help("Back")
                    }
                }
            }
            .onAppear { displayedSection = model.selectedSection }
            // The new section opens on its first page, with a fade.
            .onChange(of: model.selectedSection) { _, newSection in
                guard newSection != displayedSection else { return }
                withAnimation(Theme.Motion.page) {
                    displayedSection = newSection
                    pages = []
                    gridSearch = ""
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
        .navigationSplitViewStyle(.balanced)
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
                let margins = Self.margins(of: safeFrame, in: full.frame(in: .global))
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
    static func margins(of safe: CGRect, in full: CGRect) -> EdgeInsets {
        EdgeInsets(
            top: max(0, safe.minY - full.minY),
            leading: max(0, safe.minX - full.minX),
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
                // Opaque: nothing of the page below shows through.
                .background(Theme.Colors.background.ignoresSafeArea())
                // The page is in its own view: what it reads from its surroundings is passed here.
                .environment(model)
                .environment(\.isPageVisible, isTop)
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

    /// The search field of the movie grids, only while one of them is on top.
    @ViewBuilder
    private var gridSearchField: some View {
        if pages.isEmpty {
            switch section {
            case .movies: Color.clear.searchable(text: $gridSearch, prompt: "Search movies…")
            case .library: Color.clear.searchable(text: $gridSearch, prompt: "Search this library…")
            default: EmptyView()
            }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        switch section {
        case .home: HomeView()
        case .movies: MoviesGridView(search: $gridSearch)
        case .library(let libId): LibraryGridView(libraryId: libId, search: $gridSearch)
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
}
