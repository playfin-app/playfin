import Foundation

/// Settings that determine what the grid shows. Used as a key: when it changes, we recompute.
struct GridQuery: Hashable, Sendable {
    var search = ""
    var watchFilter: WatchFilter = .all
    var genre: String?
    /// Sorting done locally (Movies screen). `nil`: the received order is kept (already sorted by the server).
    var localSort: MovieSortOption?
}

/// Content ready to display for a grid: computed once per change, never in `body`.
struct GridContent: Sendable {
    var filtered: [Movie] = []
    var sections: [(letter: String, movies: [Movie])] = []
    var activeLetters: Set<String> = []
    var genres: [(genre: String, count: Int)] = []
    /// Shape of every card of the grid (from the whole library: it does not change with the filters).
    var cardAspectRatio: Double = 2.0 / 3.0
    var filteredIds: [String] { filtered.map(\.id) }
}

enum GridContentBuilder {
    /// Filters, sorts, groups by letter and counts genres in a single pass.
    static func build(items: [Movie], query: GridQuery) -> GridContent {
        var list = items

        let search = query.search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            list = list.filter {
                $0.name.localizedStandardContains(search) ||
                $0.genres.contains { g in g.localizedStandardContains(search) } ||
                ($0.overview?.localizedStandardContains(search) ?? false) ||
                String($0.productionYear ?? 0).contains(search)
            }
        }

        switch query.watchFilter {
        case .all: break
        case .unwatched: list = list.filter { !$0.isWatched && !$0.isInProgress }
        case .inProgress: list = list.filter { $0.isInProgress }
        case .watched: list = list.filter { $0.isWatched }
        }

        if let genre = query.genre, !genre.isEmpty {
            list = list.filter { $0.genres.contains(genre) }
        }

        if let sort = query.localSort { list = sorted(list, by: sort) }

        // A single read of the letter per item (the computation folds accents: expensive).
        var grouped: [String: [Movie]] = [:]
        for movie in list {
            let letter = movie.sectionLetter
            grouped[letter, default: []].append(movie)
        }
        let letters = grouped.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }

        var counts: [String: Int] = [:]
        for movie in items { for g in movie.genres { counts[g, default: 0] += 1 } }

        return GridContent(
            filtered: list,
            sections: letters.map { ($0, grouped[$0] ?? []) },
            activeLetters: Set(letters),
            genres: counts.keys.sorted().map { ($0, counts[$0] ?? 0) },
            cardAspectRatio: Movie.commonCardAspectRatio(of: items)
        )
    }

    static func sorted(_ list: [Movie], by sort: MovieSortOption) -> [Movie] {
        switch sort {
        case .titleAsc:
            return list.sorted { $0.effectiveSortName.localizedStandardCompare($1.effectiveSortName) == .orderedAscending }
        case .titleDesc:
            return list.sorted { $0.effectiveSortName.localizedStandardCompare($1.effectiveSortName) == .orderedDescending }
        case .dateAdded:
            return list.sorted { ($0.dateCreated ?? "") > ($1.dateCreated ?? "") }
        case .yearDesc:
            return list.sorted { ($0.productionYear ?? 0) > ($1.productionYear ?? 0) }
        case .yearAsc:
            return list.sorted { ($0.productionYear ?? Int32.max) < ($1.productionYear ?? Int32.max) }
        case .ratingDesc:
            return list.sorted { ($0.communityRating ?? 0) > ($1.communityRating ?? 0) }
        case .durationDesc:
            return list.sorted { ($0.runTimeTicks ?? 0) > ($1.runTimeTicks ?? 0) }
        }
    }
}
