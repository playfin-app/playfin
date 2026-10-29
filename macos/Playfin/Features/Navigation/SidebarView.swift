import SwiftUI

/// Main sidebar (PlxNative / Plex style).
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var bindableModel = model

        List(selection: $bindableModel.selectedSection) {
            Section {
                Label {
                    HStack {
                        Text("Home")
                        Spacer()
                    }
                } icon: {
                    Image(systemName: "house.fill")
                }
                .sidebarRow(.home)
            }

            Section("Libraries") {
                if model.libraries.isEmpty {
                    Label {
                        HStack {
                            Text("Movies")
                            Spacer()
                            if !model.movies.isEmpty {
                                Text("\(model.movies.count)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.quaternary))
                            }
                        }
                    } icon: {
                        Image(systemName: "film.stack.fill")
                    }
                    .sidebarRow(.movies)
                } else {
                    ForEach(model.libraries, id: \.id) { lib in
                        Label {
                            HStack {
                                Text(lib.name)
                                Spacer()
                            }
                        } icon: {
                            Image(systemName: iconForCollectionType(lib.collectionType))
                        }
                        .sidebarRow(.library(lib.id))
                    }
                }
            }

            Section("Discover") {
                Label("Search", systemImage: "magnifyingglass")
                    .sidebarRow(.search)
                Label("Favourites", systemImage: "heart")
                    .sidebarRow(.favorites)
                // Always visible, even offline: this is what can be watched without a server.
                Label {
                    HStack {
                        Text("Downloads")
                        Spacer()
                        if model.downloads.activeCount > 0 {
                            Text("\(model.downloads.activeCount)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.Colors.accent))
                                .accessibilityLabel("\(model.downloads.activeCount) downloads in progress")
                        }
                    }
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
                .sidebarRow(.downloads)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        .safeAreaInset(edge: .bottom) {
            SidebarBottomBar()
        }
    }
}

/// Selectable sidebar row. A click always shows the first page of its section, even when the row is
/// already selected (the list does not report a click on the selected row, hence the extra gesture).
private struct SidebarRow: ViewModifier {
    @Environment(AppModel.self) private var model
    let section: AppModel.SidebarSection

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { model.showSection(section) })
    }
}

private extension View {
    func sidebarRow(_ section: AppModel.SidebarSection) -> some View {
        modifier(SidebarRow(section: section)).tag(section)
    }
}

/// Sidebar footer with server status, refresh and sign-out.
struct SidebarBottomBar: View {
    @Environment(AppModel.self) private var model

    @State private var isRefreshing = false
    @State private var confirmSignOut = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.isServerUnreachable ? Theme.Colors.unreachable : Theme.Colors.reachable)
                        .frame(width: 7, height: 7)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.isServerUnreachable ? "Offline" : "Connected")
                            .font(.caption.bold())
                            .foregroundStyle(.primary)

                        Text(model.serverHost)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .help("Server: \(model.serverHost) (\(model.isServerUnreachable ? "Offline" : "Connected") · Playfin Core v\(model.rustCoreVersion))")

                Spacer()

                Button {
                    Task {
                        isRefreshing = true
                        await model.refresh()
                        isRefreshing = false
                    }
                } label: {
                    // Native spinner while refreshing: a `repeatForever` rotation could keep running
                    // invisibly once the refresh was over, and redraw the window on every frame.
                    Group {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isRefreshing ? .primary : .secondary)
                .disabled(isRefreshing)
                .help("Refresh the library")
                .accessibilityLabel("Refresh the library")

                Button {
                    confirmSignOut = true
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Sign out")
                .accessibilityLabel("Sign out")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                if let profile = model.activeProfile { model.signOut(profile) } else { model.logout() }
            }
        } message: {
            Text("This profile's token is deleted and its cache cleared. Downloads stay on disk.")
        }
    }
}

private func iconForCollectionType(_ type: String?) -> String {
    switch type?.lowercased() {
    case "movies": return "film"
    case "tvshows": return "tv"
    case "music": return "music.note"
    case "musicvideos": return "music.note.tv"
    case "boxsets": return "square.stack"
    case "homevideos": return "video"
    default: return "folder"
    }
}
