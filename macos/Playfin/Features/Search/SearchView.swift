import SwiftUI

/// A group of results (Movies, Series, Audiobooks…).
struct SearchSection: Identifiable {
    let title: String
    let items: [Movie]
    var id: String { title }
}

/// Sorts a search's results by type, in a fixed order (pure function, tested).
enum SearchGrouping {
    static func sections(from items: [Movie]) -> [SearchSection] {
        let groups: [(title: String, types: [String])] = [
            ("Movies", ["Movie"]), ("Series", ["Series"]), ("Episodes", ["Episode"]),
            ("Audiobooks", ["AudioBook"]), ("Music", ["Audio", "MusicAlbum", "MusicArtist"]),
            ("Collections", ["BoxSet"])
        ]
        var used = Set<String>()
        var result: [SearchSection] = []
        for group in groups {
            let matching = items.filter { item in
                group.types.contains { item.itemType?.caseInsensitiveCompare($0) == .orderedSame }
            }
            matching.forEach { used.insert($0.id) }
            if !matching.isEmpty { result.append(SearchSection(title: group.title, items: matching)) }
        }
        let others = items.filter { !used.contains($0.id) }
        if !others.isEmpty { result.append(SearchSection(title: "Other", items: others)) }
        return result
    }
}

/// Search screen: queries the server across all libraries (movies, series, episodes, audiobooks,
/// music, collections). Without a server, falls back to the movies already saved.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    @State private var sections: [SearchSection] = []
    @State private var isSearching = false
    @State private var isLocalFallback = false
    @State private var searchError: String?
    @State private var availableGenres: [String] = []

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if trimmedQuery.isEmpty {
                explorationView
            } else if let searchError {
                ContentUnavailableView {
                    Label("Search failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(searchError)
                } actions: {
                    Button("Try again") { Task { await runSearch(trimmedQuery) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sections.isEmpty && !isSearching {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsView
            }
        }
        .background(Theme.Colors.background)
        .task { await model.loadMoviesIfNeeded() }
        .task(id: trimmedQuery) {
            let key = trimmedQuery
            guard !key.isEmpty else {
                sections = []; searchError = nil; isSearching = false
                return
            }
            // Short delay: not one request per typed letter. `task(id:)` cancels the previous search.
            // The indicator shows as soon as typing starts (no "No results" while waiting).
            isSearching = true
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await runSearch(key)
        }
        .task(id: model.moviesRevision) { availableGenres = MovieSearch.genres(in: model.movies) }
    }

    private func runSearch(_ key: String) async {
        isSearching = true
        let outcome = await model.search(key)
        guard !Task.isCancelled, key == trimmedQuery else { return }
        isSearching = false
        switch outcome {
        case .results(let items):
            sections = SearchGrouping.sections(from: items); isLocalFallback = false; searchError = nil
        case .localOnly(let items):
            sections = SearchGrouping.sections(from: items); isLocalFallback = true; searchError = nil
        case .failed(let message):
            sections = []; searchError = message
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField("Search for a movie, a series, an audiobook…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                // ⌘F or click on "Search": one can type right away.
                .onAppear { fieldFocused = true }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            }
            if isSearching || model.isLoadingMovies {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Colors.surface))
        .padding(.horizontal, Theme.Spacing.screenMargin)
        .padding(.vertical, 16)
    }

    private var explorationView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if !availableGenres.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Browse by genre").font(Theme.Typography.section)
                        FlowLayout(spacing: 10) {
                            ForEach(availableGenres, id: \.self) { genre in
                                Button {
                                    model.selectedGenreFilter = genre
                                    model.selectedSection = .movies
                                } label: {
                                    Text(genre)
                                        .font(.subheadline.weight(.medium))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(Capsule().fill(Theme.Colors.surface))
                                }
                                .buttonStyle(PressableButtonStyle())
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.screenMargin)
                }
                if !model.latest.isEmpty {
                    Shelf(title: "Recently added") {
                        ForEach(model.latest.prefix(12), id: \.id) { movie in
                            NavigationLink(value: Route.movie(movie.id)) {
                                PosterCard(movie: movie).frame(width: Theme.Layout.posterWidth)
                            }
                            .buttonStyle(CardButtonStyle())
                        }
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
    }

    private var resultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if isLocalFallback {
                    Label("Server unreachable: results limited to the movies saved on this Mac.", systemImage: "wifi.slash")
                        .font(.callout).foregroundStyle(Theme.Colors.warning)
                }
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 14) {
                        Text("\(section.title) (\(section.items.count))").font(.title2.bold())
                        if section.title == "Episodes" {
                            ForEach(section.items, id: \.id) { episode in
                                NavigationLink(value: Route.movie(episode.id)) {
                                    OverviewResultRow(movie: episode, highlight: trimmedQuery)
                                }
                                .buttonStyle(CardButtonStyle())
                            }
                        } else {
                            // Fixed width: a poster keeps the same size whether there are one or twenty results.
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: Theme.Layout.posterWidth, maximum: Theme.Layout.posterWidth), spacing: 20)],
                                alignment: .leading, spacing: 24
                            ) {
                                ForEach(section.items, id: \.id) { item in
                                    NavigationLink(value: Route.movie(item.id)) {
                                        PosterCard(movie: item)
                                    }
                                    .buttonStyle(CardButtonStyle())
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.screenMargin)
            .padding(.vertical, Theme.Spacing.lg)
        }
    }
}

/// Local search in the list of saved movies (offline fallback; pure functions, tested).
enum MovieSearch {
    static func genres(in movies: [Movie]) -> [String] {
        Set(movies.flatMap(\.genres)).sorted()
    }

    static func titleMatches(in movies: [Movie], query: String) -> [Movie] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return movies.filter {
            $0.name.localizedStandardContains(query) || $0.genres.contains { g in g.localizedStandardContains(query) }
                || ($0.overview?.localizedStandardContains(query) ?? false)
        }
    }
}

/// Horizontal card for a result found in the synopsis.
struct OverviewResultRow: View {
    @Environment(AppModel.self) private var model
    let movie: Movie
    let highlight: String
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            AsyncArtwork(
                url: model.imageURL(movie, .primary, height: 180),
                blurHash: movie.primaryBlurHash,
                contentMode: .fill
            )
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(movie.name)
                    .font(.headline)

                Text(movie.infoLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let overview = movie.overview {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
