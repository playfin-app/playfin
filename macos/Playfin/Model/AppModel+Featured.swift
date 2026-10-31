import Foundation
import SwiftUI

/// Titles of the home banner: movies and series picked at random in the library, a new choice every 30 minutes.
/// "Continue watching" already shows what is in progress: the banner shows something else.
extension AppModel {
    nonisolated static let featuredLifetime: TimeInterval = 30 * 60
    static let featuredCount = 10
    /// Random titles asked to the server: enough to keep 10 after setting aside the ones without a background
    /// image, already watched or in progress.
    static let featuredCandidates: UInt32 = 60

    /// A choice of banner titles, kept per profile (`UserDefaults`): the same titles come back while it is recent,
    /// even after a relaunch.
    struct FeaturedChoice: Codable, Equatable {
        var ids: [String]
        var chosenAt: Date

        func isFresh(at now: Date = Date()) -> Bool {
            let age = now.timeIntervalSince(chosenAt)
            return age >= 0 && age < AppModel.featuredLifetime
        }
    }

    /// Picks the banner titles among random candidates: only those with a background image, never those in
    /// progress, unwatched first (the watched ones only complete a small library).
    static func pickFeatured(from candidates: [Movie], excluding excludedIds: Set<String>) -> [Movie] {
        var seen = Set<String>()
        let usable = candidates.filter {
            !$0.backdropImageTags.isEmpty && !excludedIds.contains($0.id) && seen.insert($0.id).inserted
        }
        let unwatched = usable.filter { !$0.isWatched }
        let watched = usable.filter { $0.isWatched }
        return Array((unwatched + watched).prefix(featuredCount))
    }

    /// Seconds before the current choice must be renewed (0 if there is none).
    var featuredTimeLeft: TimeInterval {
        guard let saved = savedFeaturedChoice else { return 0 }
        return max(0, Self.featuredLifetime - Date().timeIntervalSince(saved.chosenAt))
    }

    /// Shows the saved choice while it is recent, otherwise picks new titles. Offline, the titles shown stay.
    /// A failure does not end `isChoosingFeatured`: at launch the server address may not be chosen yet, and the
    /// banner keeps waiting rather than falling back to other titles (`openSession` ends the wait).
    func loadFeatured() async {
        // One choice at a time: otherwise two random choices, and the banner would change twice.
        while let running = featuredLoad { await running.value }
        let load = Task {
            await chooseFeatured()
            featuredLoad = nil
        }
        featuredLoad = load
        await load.value
    }

    private func chooseFeatured() async {
        guard let client else { return }

        if let saved = savedFeaturedChoice, saved.isFresh() {
            if featured.map(\.id) == saved.ids { return }
            let items = await featuredItems(saved.ids, client)
            guard self.client === client else { return }
            if items.count == saved.ids.count {
                showFeatured(items)
                return
            }
            // Some titles are no longer on the server: a new choice.
        }

        guard let page = try? await client.libraryItems(
            parentId: nil, startIndex: 0, limit: Self.featuredCandidates,
            sortBy: "Random", sortOrder: nil, includeItemTypes: "Movie,Series"
        ), self.client === client else { return }

        // What is in progress is already in "Continue watching" and "Up next" (a series by its episodes).
        let inProgress = Set(resume.map(\.id) + (resume + nextUp).compactMap(\.seriesId))
        let picked = Self.pickFeatured(from: page.items, excluding: inProgress)
        guard !picked.isEmpty else { return }
        showFeatured(picked)
        savedFeaturedChoice = FeaturedChoice(ids: picked.map(\.id), chosenAt: Date())
    }

    private func showFeatured(_ items: [Movie]) {
        remember(items)
        withAnimation(Theme.Motion.hero) { featured = items }
        isChoosingFeatured = false
    }

    /// The saved titles, in their order: already known ones at once, the others asked to the server together.
    private func featuredItems(_ ids: [String], _ client: JellyfinClient) async -> [Movie] {
        var found: [String: Movie] = [:]
        for id in ids { found[id] = movie(id: id) }
        let missing = ids.filter { found[$0] == nil }
        await withTaskGroup(of: Movie?.self) { group in
            for id in missing {
                group.addTask { try? await client.itemDetails(itemId: id) }
            }
            for await item in group {
                if let item { found[item.id] = item }
            }
        }
        return ids.compactMap { found[$0] }
    }

    private var featuredKey: String { "Playfin_Featured_\(activeProfileKey ?? "default")" }

    var savedFeaturedChoice: FeaturedChoice? {
        get {
            Self.userDefaults.data(forKey: featuredKey).flatMap { try? JSONDecoder().decode(FeaturedChoice.self, from: $0) }
        }
        set {
            Self.userDefaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: featuredKey)
        }
    }
}
