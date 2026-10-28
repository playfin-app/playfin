import SwiftUI

/// High-performance paged grid (60/120 Hz) to browse any Jellyfin library.
/// Supports paging in batches of 100, server-side sorting, filtering by status/genre,
/// A–Z jumping and keyboard navigation.
struct LibraryGridView: View {
    @Environment(AppModel.self) private var model
    let libraryId: String

    @State private var search = ""
    // Remembered per library (see `LibraryPreferences`); the view is rebuilt for each library (`.id(libId)`).
    @State private var sortOption: MovieSortOption
    @State private var watchFilter: WatchFilter
    @State private var selectedGenre: String?

    init(libraryId: String) {
        self.libraryId = libraryId
        let saved = LibraryPreferences.load(libraryId: libraryId)
        _sortOption = State(initialValue: saved.sort)
        _watchFilter = State(initialValue: saved.watchFilter)
        _selectedGenre = State(initialValue: saved.genre)
    }

    private var preferences: LibraryPreferences {
        LibraryPreferences(sort: sortOption, watchFilter: watchFilter, genre: selectedGenre)
    }

    private var showsLetterSections: Bool {
        LibraryPreferences.showsLetterSections(
            sort: sortOption, search: search, genre: selectedGenre, itemCount: filteredItems.count)
    }

    private var sortParameters: (sortBy: String, sortOrder: String) { sortOption.serverParameters }

    /// Content computed outside `body` (see `GridContentBuilder`); `nil` until the first computation is done.
    @State private var content: GridContent?

    private var allGenresWithCounts: [(genre: String, count: Int)] { content?.genres ?? [] }
    private var filteredItems: [Movie] { content?.filtered ?? [] }
    private var groupedLetterSections: [(letter: String, movies: [Movie])] { content?.sections ?? [] }
    private var activeLetters: Set<String> { content?.activeLetters ?? [] }

    private var gridQuery: GridQuery {
        GridQuery(search: search, watchFilter: watchFilter, genre: selectedGenre, localSort: nil)
    }

    private var hasActiveFilters: Bool {
        watchFilter != .all || selectedGenre != nil || !search.isEmpty
    }

    @AppStorage("libraryCardSize") private var cardSizeRaw = CardSize.medium.rawValue

    private var cardSize: CardSize { CardSize(rawValue: cardSizeRaw) ?? .medium }

    private var columns: [GridItem] {
        let range = cardSize.columnRange
        return [GridItem(.adaptive(minimum: range.min, maximum: range.max), spacing: 20)]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    FilterToolbar(
                        totalCount: Int(model.libraryTotalCount > 0 ? model.libraryTotalCount : UInt32(model.libraryItems.count)),
                        filteredCount: filteredItems.count,
                        sortOption: $sortOption,
                        watchFilter: $watchFilter,
                        selectedGenre: $selectedGenre,
                        genres: allGenresWithCounts,
                        hasActiveFilters: hasActiveFilters,
                        onResetFilters: {
                            watchFilter = .all
                            selectedGenre = nil
                            search = ""
                        }
                    )

                    if content == nil || (model.isLoadingLibrary && model.libraryItems.isEmpty) {
                        VStack(spacing: 16) {
                            ProgressView()
                                .controlSize(.regular)
                            Text("Loading the library…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = model.libraryLoadError, model.libraryItems.isEmpty {
                        ErrorStateView(
                            title: model.isServerUnreachable ? "Library not saved" : "Unable to load",
                            message: model.isServerUnreachable
                                ? "The server is unreachable and this library has not been saved on this Mac yet."
                                : error,
                            systemImage: model.isServerUnreachable ? "wifi.slash" : "exclamationmark.triangle",
                            retry: { Task { await reloadWithSort(force: true) } }
                        )
                    } else if filteredItems.isEmpty {
                        ContentUnavailableView {
                            Label(
                                hasActiveFilters ? "No matching item" : "Empty library",
                                systemImage: hasActiveFilters ? "line.3.horizontal.decrease.circle" : "folder"
                            )
                        } description: {
                            Text(
                                hasActiveFilters
                                    ? "Change your filters or try another keyword."
                                    : "This library contains no item on the server."
                            )
                        } actions: {
                            if hasActiveFilters {
                                Button("Reset filters") {
                                    watchFilter = .all
                                    selectedGenre = nil
                                    search = ""
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            if showsLetterSections {
                                LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
                                    ForEach(groupedLetterSections, id: \.letter) { section in
                                        Section {
                                            LazyVGrid(columns: columns, spacing: 24) {
                                                ForEach(section.movies, id: \.id) { movie in
                                                    gridItemCard(for: movie)
                                                }
                                            }
                                        } header: {
                                            LetterSectionHeader(letter: section.letter, count: section.movies.count)
                                                .id("letter_\(section.letter)")
                                        }
                                    }
                                }
                                .padding(.horizontal, Theme.Spacing.screenMargin)
                                .padding(.trailing, 28) // room for the alphabet bar
                                .padding(.vertical, 16)
                            } else {
                                LazyVGrid(columns: columns, spacing: 24) {
                                    ForEach(filteredItems, id: \.id) { movie in
                                        gridItemCard(for: movie)
                                    }
                                }
                                .padding(.horizontal, Theme.Spacing.screenMargin)
                                .padding(.vertical, 16)
                            }

                            // Loading indicator for the next page
                            if model.isLoadingMoreLibraryItems {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Loading more…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 20)
                            } else if model.libraryItems.count >= Int(model.libraryTotalCount) && model.libraryTotalCount > 0 {
                                Text("\(model.libraryTotalCount) items in total")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.vertical, 24)
                            }
                        }
                    }
                }

                // Vertical alphabet bar for quick jumping
                if showsLetterSections {
                    AlphabetJumpBar(activeLetters: activeLetters) { letter in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo("letter_\(letter)", anchor: .top)
                        }
                    }
                    .padding(.trailing, 6)
                }
            }
        }
        .searchable(text: $search, prompt: "Search this library…")
        .toolbar {
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
        .task(id: libraryId) {
            await loadInitialItems()
        }
        .task(id: ContentKey(query: gridQuery, revision: model.libraryRevision, loadedLibraryId: model.loadedLibraryId)) {
            // Short delay while typing: do not refilter on every letter.
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            // Never the items of another library (the old list stays in memory for a moment).
            let items = model.loadedLibraryId == libraryId ? model.libraryItems : []
            let query = gridQuery
            let built = await Task.detached(priority: .userInitiated) {
                GridContentBuilder.build(items: items, query: query)
            }.value
            guard !Task.isCancelled else { return }
            content = built
        }
        .onChange(of: sortOption) { _, _ in
            Task {
                await reloadWithSort()
            }
        }
        .onChange(of: preferences) { _, value in value.save(libraryId: libraryId) }
    }

    private struct ContentKey: Hashable {
        let query: GridQuery
        let revision: Int
        let loadedLibraryId: String?
    }

    @ViewBuilder
    private func gridItemCard(for movie: Movie) -> some View {
        NavigationLink(value: Route.movie(movie.id)) {
            PosterCard(movie: movie, imageHeight: cardSize.imageHeight, aspectRatio: content?.cardAspectRatio)
        }
        .buttonStyle(CardButtonStyle())
    }

    private func loadInitialItems() async {
        let params = sortParameters
        await model.loadLibraryItems(
            libraryId: libraryId,
            reset: true,
            sortBy: params.sortBy,
            sortOrder: params.sortOrder
        )
    }

    private func reloadWithSort(force: Bool = false) async {
        let params = sortParameters
        await model.loadLibraryItems(
            libraryId: libraryId,
            reset: true,
            sortBy: params.sortBy,
            sortOrder: params.sortOrder,
            force: force
        )
    }
}
