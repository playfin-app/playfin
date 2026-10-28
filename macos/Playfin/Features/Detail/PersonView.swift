import SwiftUI

/// Page of a person (actor, director): everything they appear in across the libraries, sorted into
/// Movies / Series / Other.
struct PersonView: View {
    @Environment(AppModel.self) private var model
    let personId: String
    let name: String

    @State private var items: [Movie] = []
    @State private var isLoading = true
    @State private var error: String?

    private var sections: [(title: String, items: [Movie])] {
        let movies = items.filter { $0.itemType == "Movie" }
        let series = items.filter(\.isSeries)
        let others = items.filter { $0.itemType != "Movie" && !$0.isSeries }
        return [("Movies", movies), ("Series", series), ("Other", others)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 20) {
                    AsyncArtwork(url: model.personImageURL(personId, height: 400), contentMode: .fill) {
                        Circle().fill(Theme.Colors.surface)
                            .overlay(Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary))
                    }
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        Text(name).font(Theme.Typography.detail).lineLimit(2)
                        if !isLoading {
                            Text(items.isEmpty ? "Nothing in your libraries" : "\(items.count) title\(items.count > 1 ? "s" : "") in your libraries")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 24)

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let error {
                    ErrorStateView(title: "Search failed", message: error, retry: { Task { await load() } })
                        .frame(height: 260)
                } else {
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(section.title).font(Theme.Typography.section)
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
            .padding(.bottom, 40)
        }
        .background(Theme.Colors.background)
        .navigationTitle(name)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            items = try await model.itemsWithPerson(personId)
        } catch {
            self.error = model.message(for: error)
        }
        isLoading = false
    }
}
