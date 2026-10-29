import SwiftUI

/// Main sidebar (PlxNative / Plex style).
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isWindowFullScreen) private var isFullScreen

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
        // Full screen hides the toolbar and its window buttons: close and leave full screen are here, in the
        // sidebar that comes over the page when the pointer reaches the left edge.
        .safeAreaInset(edge: .top) {
            if isFullScreen { FullScreenWindowButtons() }
        }
        .safeAreaInset(edge: .bottom) {
            SidebarBottomBar()
        }
        // Full screen: the room kept at the top for the toolbar stays empty (it is hidden); the window buttons
        // take its place.
        .ignoresSafeArea(.container, edges: isFullScreen ? .top : [])
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

/// Full screen, where the toolbar is hidden: the window buttons of macOS (red: close, green: leave full screen).
private struct FullScreenWindowButtons: View {
    var body: some View {
        HStack(spacing: 0) {
            StandardWindowButtons().fixedSize()
            Spacer()
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

/// The red and green buttons made by AppKit itself (`standardWindowButton`): same size and look as those of any
/// window, at the spacing of this window's own buttons.
private struct StandardWindowButtons: NSViewRepresentable {
    private static let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    func makeNSView(context: Context) -> NSStackView {
        let coordinator = context.coordinator
        var buttons: [NSView] = []
        if let close = NSWindow.standardWindowButton(.closeButton, for: Self.style) {
            close.target = coordinator
            close.action = #selector(Coordinator.close(_:))
            close.toolTip = "Close the window"
            buttons.append(close)
        }
        if let zoom = NSWindow.standardWindowButton(.zoomButton, for: Self.style) {
            zoom.target = coordinator
            zoom.action = #selector(Coordinator.leaveFullScreen(_:))
            zoom.toolTip = "Leave full screen"
            buttons.append(zoom)
        }
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 6
        coordinator.stack = stack
        return stack
    }

    func updateNSView(_ stack: NSStackView, context: Context) {
        // The gap between the window's own red and yellow buttons (it changes with the macOS version).
        if let window = stack.window,
           let close = window.standardWindowButton(.closeButton),
           let minimize = window.standardWindowButton(.miniaturizeButton) {
            let gap = minimize.frame.minX - close.frame.maxX
            if gap > 0 { stack.spacing = gap }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        weak var stack: NSStackView?

        @objc func close(_ sender: Any?) { stack?.window?.performClose(nil) }
        @objc func leaveFullScreen(_ sender: Any?) { stack?.window?.toggleFullScreen(nil) }
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
