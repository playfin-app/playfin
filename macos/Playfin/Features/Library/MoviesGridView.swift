import SwiftUI

enum MovieSortOption: String, CaseIterable, Identifiable {
    case titleAsc = "Title (A → Z)"
    case titleDesc = "Title (Z → A)"
    case dateAdded = "Recently added"
    case yearDesc = "Year (newest)"
    case yearAsc = "Year (oldest)"
    case ratingDesc = "Top rated"
    case durationDesc = "Longest"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .titleAsc, .titleDesc: return "arrow.up.arrow.down"
        case .dateAdded: return "clock.arrow.circlepath"
        case .yearDesc, .yearAsc: return "calendar"
        case .ratingDesc: return "star.fill"
        case .durationDesc: return "hourglass"
        }
    }
}

extension MovieSortOption {
    /// `SortBy` / `SortOrder` parameters of the Jellyfin API for this sort.
    var serverParameters: (sortBy: String, sortOrder: String) {
        switch self {
        case .titleAsc: return ("SortName", "Ascending")
        case .titleDesc: return ("SortName", "Descending")
        case .dateAdded: return ("DateCreated", "Descending")
        case .yearDesc: return ("PremiereDate", "Descending")
        case .yearAsc: return ("PremiereDate", "Ascending")
        case .ratingDesc: return ("CommunityRating", "Descending")
        case .durationDesc: return ("Runtime", "Descending")
        }
    }
}

/// Size of the posters in the grid (choice is remembered).
enum CardSize: String, CaseIterable, Identifiable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"

    var id: String { rawValue }

    /// Minimum and maximum width of a column.
    var columnRange: (min: CGFloat, max: CGFloat) {
        switch self {
        case .small: return (110, 140)
        case .medium: return (155, 200)
        case .large: return (210, 270)
        }
    }

    /// Image height requested from the server for this poster size (Retina screen: ×2).
    var imageHeight: UInt32 {
        switch self {
        case .small: return 300
        case .medium: return 450
        case .large: return 650
        }
    }

    var icon: String {
        switch self {
        case .small: return "square.grid.3x3"
        case .medium: return "square.grid.2x2"
        case .large: return "square"
        }
    }
}

enum WatchFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case unwatched = "Unwatched"
    case inProgress = "In progress"
    case watched = "Watched"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "line.3.horizontal.decrease.circle"
        case .unwatched: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .watched: return "checkmark.circle.fill"
        }
    }
}

/// Sort and filters of each library, kept between visits and launches.
struct LibraryPreferences: Equatable {
    var sort: MovieSortOption = .titleAsc
    var watchFilter: WatchFilter = .all
    var genre: String?

    /// Below this number of items, no letter sections: they would hold one or two posters each.
    static let minimumItemsForLetterSections = 50

    private static func key(_ libraryId: String, _ name: String) -> String { "library.\(libraryId).\(name)" }

    @MainActor static func load(libraryId: String, from defaults: UserDefaults = AppModel.userDefaults) -> LibraryPreferences {
        LibraryPreferences(
            sort: defaults.string(forKey: key(libraryId, "sort")).flatMap(MovieSortOption.init(rawValue:)) ?? .titleAsc,
            watchFilter: defaults.string(forKey: key(libraryId, "watchFilter")).flatMap(WatchFilter.init(rawValue:)) ?? .all,
            genre: defaults.string(forKey: key(libraryId, "genre"))
        )
    }

    @MainActor func save(libraryId: String, to defaults: UserDefaults = AppModel.userDefaults) {
        defaults.set(sort.rawValue, forKey: Self.key(libraryId, "sort"))
        defaults.set(watchFilter.rawValue, forKey: Self.key(libraryId, "watchFilter"))
        defaults.set(genre, forKey: Self.key(libraryId, "genre"))
    }

    /// Letter sections and A–Z bar: title order, no search or genre, and enough items to be worth it.
    static func showsLetterSections(sort: MovieSortOption, search: String, genre: String?, itemCount: Int) -> Bool {
        sort == .titleAsc && search.isEmpty && genre == nil && itemCount >= minimumItemsForLetterSections
    }
}

/// Movie library grid with sorting, advanced filters and an alphabet jump bar.
struct MoviesGridView: View {
    @Environment(AppModel.self) private var model

    @State private var search = ""
    @State private var sortOption: MovieSortOption = .titleAsc
    @State private var watchFilter: WatchFilter = .all
    @State private var selectedGenre: String? = nil

    @State private var content: GridContent?

    private var allGenresWithCounts: [(genre: String, count: Int)] { content?.genres ?? [] }
    private var filteredMovies: [Movie] { content?.filtered ?? [] }
    private var groupedLetterSections: [(letter: String, movies: [Movie])] { content?.sections ?? [] }
    private var activeLetters: Set<String> { content?.activeLetters ?? [] }

    private var gridQuery: GridQuery {
        GridQuery(
            search: search, watchFilter: watchFilter,
            genre: selectedGenre ?? model.selectedGenreFilter, localSort: sortOption
        )
    }

    private struct ContentKey: Hashable {
        let query: GridQuery
        let revision: Int
        /// End of a load that left the list empty: built then, not stuck on the loading view.
        let isLoading: Bool
    }

    private var hasActiveFilters: Bool {
        watchFilter != .all || selectedGenre != nil || model.selectedGenreFilter != nil || !search.isEmpty
    }

    @AppStorage("libraryCardSize") private var cardSizeRaw = CardSize.medium.rawValue

    private var showsLetterSections: Bool {
        LibraryPreferences.showsLetterSections(sort: sortOption, search: search, genre: nil, itemCount: filteredMovies.count)
    }

    private var columns: [GridItem] {
        let range = (CardSize(rawValue: cardSizeRaw) ?? .medium).columnRange
        return [GridItem(.adaptive(minimum: range.min, maximum: range.max), spacing: 20)]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    FilterToolbar(
                        totalCount: model.movies.count,
                        filteredCount: filteredMovies.count,
                        sortOption: $sortOption,
                        watchFilter: $watchFilter,
                        selectedGenre: Binding(
                            get: { selectedGenre ?? model.selectedGenreFilter },
                            set: { newValue in
                                selectedGenre = newValue
                                model.selectedGenreFilter = newValue
                            }
                        ),
                        genres: allGenresWithCounts,
                        hasActiveFilters: hasActiveFilters,
                        onResetFilters: {
                            watchFilter = .all
                            selectedGenre = nil
                            model.selectedGenreFilter = nil
                            search = ""
                        },
                        search: $search,
                        searchPrompt: "Search movies…"
                    )

                    // Still loading with nothing to show: not "No matching movie" for a split second.
                    if content == nil {
                        LoadingStateView()
                    } else if filteredMovies.isEmpty {
                        ContentUnavailableView {
                            Label("No matching movie", systemImage: "film.stack")
                        } description: {
                            Text("Change your filters or try another search term.")
                        } actions: {
                            if hasActiveFilters {
                                Button("Reset filters") {
                                    watchFilter = .all
                                    selectedGenre = nil
                                    model.selectedGenreFilter = nil
                                    search = ""
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            if showsLetterSections {
                                // A single grid with sections: a lazy grid inside a lazy stack could re-measure itself
                                // endlessly and freeze the app.
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
                                    ForEach(groupedLetterSections, id: \.letter) { section in
                                        Section {
                                            ForEach(section.movies, id: \.id) { movie in
                                                RouteLink(value: Route.movie(movie.id)) {
                                                    PosterCard(movie: movie, imageHeight: (CardSize(rawValue: cardSizeRaw) ?? .medium).imageHeight)
                                                }
                                                .buttonStyle(CardButtonStyle())
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
                                    ForEach(filteredMovies, id: \.id) { movie in
                                        RouteLink(value: Route.movie(movie.id)) {
                                            PosterCard(movie: movie, imageHeight: (CardSize(rawValue: cardSizeRaw) ?? .medium).imageHeight)
                                        }
                                        .buttonStyle(CardButtonStyle())
                                    }
                                }
                                .padding(.horizontal, Theme.Spacing.screenMargin)
                                .padding(.vertical, 16)
                            }
                        }
                    }
                }

                // Vertical alphabet bar (PlxNative / Plex style)
                if showsLetterSections {
                    AlphabetJumpBar(activeLetters: activeLetters) { letter in
                        withAnimation(Theme.Motion.standard) {
                            proxy.scrollTo("letter_\(letter)", anchor: .top)
                        }
                    }
                    .padding(.trailing, 6)
                }
            }
        }
        .animation(Theme.Motion.fade, value: content == nil)
        .onAppear {
            if content == nil, let cached = model.gridCache["movies"], cached.query == gridQuery {
                content = cached.content
            }
        }
        .task { await model.loadMoviesIfNeeded() }
        .task(id: ContentKey(query: gridQuery, revision: model.moviesRevision, isLoading: model.isLoadingMovies)) {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            // Still loading with nothing yet: the grid already shown (or the loading view) stays.
            if model.isLoadingMovies && model.movies.isEmpty { return }
            let items = model.movies
            let query = gridQuery
            let built = await Task.detached(priority: .userInitiated) {
                GridContentBuilder.build(items: items, query: query)
            }.value
            guard !Task.isCancelled else { return }
            content = built
            model.gridCache["movies"] = AppModel.CachedGrid(query: query, content: built)
        }
    }
}

/// Header pinned while scrolling, for each letter.
struct LetterSectionHeader: View {
    let letter: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(letter)
                .font(.title2.bold())
                .foregroundStyle(.primary)

            Text("(\(count))")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.vertical, 6)
        .background(Theme.Colors.background)
    }
}

/// Filter and options bar above the grid.
struct FilterToolbar: View {
    let totalCount: Int
    let filteredCount: Int
    @Binding var sortOption: MovieSortOption
    @Binding var watchFilter: WatchFilter
    @Binding var selectedGenre: String?
    let genres: [(genre: String, count: Int)]
    let hasActiveFilters: Bool
    let onResetFilters: () -> Void
    @Binding var search: String
    let searchPrompt: String
    @AppStorage("libraryCardSize") private var cardSizeRaw = CardSize.medium.rawValue

    private var cardSize: CardSize { CardSize(rawValue: cardSizeRaw) ?? .medium }
    @Environment(\.pageMargins) private var margins
    @Environment(\.hasWindowControlsOverPage) private var hasWindowControlsOverPage

    /// Width taken by the window buttons and the sidebar button at the top left when the sidebar is hidden.
    private static let windowControlsWidth: CGFloat = 165

    var body: some View {
        HStack(spacing: 12) {
            // Watch status
            Menu {
                ForEach(WatchFilter.allCases) { filter in
                    Button {
                        watchFilter = filter
                    } label: {
                        HStack {
                            Text(filter.rawValue)
                            if watchFilter == filter {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label(watchFilter.rawValue, systemImage: watchFilter.icon)
            }
            .menuStyle(.borderedButton)
            .fixedSize() // never a truncated label

            // Genre
            Menu {
                Button {
                    selectedGenre = nil
                } label: {
                    HStack {
                        Text("All genres")
                        if selectedGenre == nil { Image(systemName: "checkmark") }
                    }
                }
                Divider()
                ForEach(genres, id: \.genre) { g in
                    Button {
                        selectedGenre = g.genre
                    } label: {
                        HStack {
                            Text("\(g.genre) (\(g.count))")
                            if selectedGenre == g.genre { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Label(selectedGenre ?? "All genres", systemImage: "tag")
            }
            .menuStyle(.borderedButton)
            .fixedSize() // never a truncated label

            // Tri
            Menu {
                ForEach(MovieSortOption.allCases) { option in
                    Button {
                        sortOption = option
                    } label: {
                        HStack {
                            Text(option.rawValue)
                            if sortOption == option { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Label(sortOption.rawValue, systemImage: sortOption.icon)
            }
            .menuStyle(.borderedButton)
            .fixedSize() // never a truncated label

            // Poster size
            Menu {
                ForEach(CardSize.allCases) { size in
                    Button {
                        cardSizeRaw = size.rawValue
                    } label: {
                        HStack {
                            Text(size.rawValue)
                            if cardSize == size { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Label(cardSize.rawValue, systemImage: cardSize.icon)
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .help("Poster size")

            if hasActiveFilters {
                Button("Reset", action: onResetFilters)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Item counter (disappears first when the window is narrow)
            Text(hasActiveFilters ? "\(filteredCount) of \(totalCount)" : "\(totalCount) items")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)

            GridSearchField(text: $search, prompt: searchPrompt)
        }
        .padding(.horizontal, Theme.Spacing.screenMargin)
        // At the very top of the window, in the toolbar's place (it is empty there), clear of the window buttons
        // when the sidebar is hidden. In full screen, there is no toolbar: simply at the top.
        .padding(.leading, hasWindowControlsOverPage ? max(0, Self.windowControlsWidth - Theme.Spacing.screenMargin) : 0)
        .frame(minHeight: margins.top > 0 ? margins.top : nil)
        .padding(.vertical, margins.top > 0 ? 0 : 10)
        .background(Theme.Colors.background)
        .padding(.top, -margins.top)
        // Over the grid: its scroll area reaches the top of the window too, and would take the clicks.
        .zIndex(1)
    }
}

/// Search field of the grids, at the right of their filter row.
struct GridSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(width: 240)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

/// Adaptive vertical alphabet jump bar (A-Z) that scales dynamically to fit available window height.
struct AlphabetJumpBar: View {
    let activeLetters: Set<String>
    let onSelectLetter: (String) -> Void

    private let alphabet: [String] = ["#"] + (65...90).map { String(UnicodeScalar($0)) }

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.height
            // Dynamically scale letter buttons and spacing to avoid overflowing compact windows
            let verticalPadding: CGFloat = available < 420 ? 8 : 16
            let usableHeight = max(180, available - verticalPadding)
            let itemHeight = min(15, max(8.5, (usableHeight - 26 * 1.5) / 27))
            let fontSize = min(10.5, max(7.5, itemHeight - 2.5))
            let spacing: CGFloat = available < 420 ? 1 : 2

            VStack(spacing: spacing) {
                ForEach(alphabet, id: \.self) { letter in
                    let isActive = activeLetters.contains(letter)
                    Button {
                        if isActive { onSelectLetter(letter) }
                    } label: {
                        Text(letter)
                            .font(.system(size: fontSize, weight: isActive ? .bold : .regular))
                            .foregroundStyle(isActive ? .primary : .tertiary)
                            .frame(width: 18, height: itemHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isActive)
                }
            }
            .padding(.vertical, verticalPadding / 2)
            .padding(.horizontal, 2)
            .background(Capsule().fill(Theme.Colors.surface))
            .shadow(color: .black.opacity(0.18), radius: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(width: 22)
    }
}
