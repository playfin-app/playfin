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
    @State private var homePath = NavigationPath()
    @State private var moviesPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var downloadsPath = NavigationPath()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                if model.isServerUnreachable {
                    OfflineBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Group {
                    switch model.selectedSection {
                    case .home:
                        NavigationStack(path: $homePath) {
                            HomeView()
                                // Covered as soon as a page is opened over it.
                                .environment(\.isPageVisible, homePath.isEmpty)
                                .navigationTitle("Home")
                                .navigationDestination(for: Route.self) { route in
                                    destinationView(for: route)
                                }
                        }
                    case .movies:
                        NavigationStack(path: $moviesPath) {
                            MoviesGridView()
                                .environment(\.isPageVisible, moviesPath.isEmpty)
                                .navigationTitle("Movies")
                                .navigationDestination(for: Route.self) { route in
                                    destinationView(for: route)
                                }
                        }
                    case .library(let libId):
                        NavigationStack(path: $libraryPath) {
                            LibraryGridView(libraryId: libId)
                                .environment(\.isPageVisible, libraryPath.isEmpty)
                                .navigationTitle(model.libraries.first(where: { $0.id == libId })?.name ?? "Library")
                                .navigationDestination(for: Route.self) { route in
                                    destinationView(for: route)
                                }
                        }
                        // New library = new stack (neither the old grid for a moment, nor its filters).
                        .id(libId)
                    case .search:
                        NavigationStack(path: $searchPath) {
                            SearchView()
                                .environment(\.isPageVisible, searchPath.isEmpty)
                                .navigationTitle("Search")
                                .navigationDestination(for: Route.self) { route in
                                    destinationView(for: route)
                                }
                        }
                    case .downloads:
                        NavigationStack(path: $downloadsPath) {
                            DownloadsView()
                                .environment(\.isPageVisible, downloadsPath.isEmpty)
                                .navigationTitle("Downloads")
                                .navigationDestination(for: Route.self) { route in
                                    destinationView(for: route)
                                }
                        }
                    }
                }
            }
            .onChange(of: model.selectedSection) { _, _ in
                libraryPath = NavigationPath()
            }
            // Escape: back to the previous page, whatever has the keyboard focus.
            .background(EscapeToGoBack { goBack() })
            .animation(.easeInOut(duration: 0.25), value: model.isServerUnreachable)
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
    }

    /// Closes the current page of the visible section. False when there is nothing to close (or during playback).
    private func goBack() -> Bool {
        guard model.playback == nil else { return false }
        switch model.selectedSection {
        case .home: return pop(&homePath)
        case .movies: return pop(&moviesPath)
        case .library: return pop(&libraryPath)
        case .search: return pop(&searchPath)
        case .downloads: return pop(&downloadsPath)
        }
    }

    private func pop(_ path: inout NavigationPath) -> Bool {
        guard !path.isEmpty else { return false }
        path.removeLast()
        return true
    }

    /// A page opened by navigation (movie, series, audiobook, folder…).
    private func destinationView(for route: Route) -> some View {
        routeContent(for: route)
            // Set explicitly: not the value of the root it covers.
            .environment(\.isPageVisible, true)
    }

    @ViewBuilder
    private func routeContent(for route: Route) -> some View {
        switch route {
        case .movie(let id):
            // The destination reads no model data here: otherwise every update (detailed record loaded,
            // item watched…) recomputed the destination, and the navigation stack replayed the transition
            // (the home page reappeared for a moment). `ItemLoaderView` is what reads the item.
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
    /// False when another page is opened over this one: SwiftUI keeps a covered page alive (scroll position…)
    /// without telling it, so its periodic work must pause by itself. During playback, a page that works
    /// periodically also reads `model.playback` (an environment value changed at the root would make the whole
    /// interface walk through it at every open and close of the player).
    @Entry var isPageVisible = true
}
