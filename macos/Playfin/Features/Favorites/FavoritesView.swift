import SwiftUI

/// "Favourites" page of the sidebar: every movie, series and episode with a heart.
struct FavoritesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.favorites.isEmpty {
                ContentUnavailableView {
                    Label("No favourites yet", systemImage: "heart")
                } description: {
                    Text("Use the heart on a movie or series page to find it here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // Fixed width: a poster keeps the same size whether there are one or twenty favourites.
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: Theme.Layout.posterWidth, maximum: Theme.Layout.posterWidth), spacing: 20)],
                        alignment: .leading, spacing: 24
                    ) {
                        ForEach(model.favorites, id: \.id) { item in
                            NavigationLink(value: Route.movie(item.id)) {
                                PosterCard(movie: item)
                            }
                            .buttonStyle(CardButtonStyle())
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.screenMargin)
                    .padding(.vertical, Theme.Spacing.lg)
                }
            }
        }
        .task {
            if let client = model.client { await model.loadFavorites(client) }
        }
    }
}
