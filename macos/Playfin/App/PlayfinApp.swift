import SwiftUI

@main
struct PlayfinApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Playfin") {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                EmptyView()
            } else {
                ContentView()
                    .environment(model)
                    .frame(minWidth: 950, minHeight: 650)
                    .preferredColorScheme(.dark)
                    .tint(Theme.Colors.accent)
            }
        }
        .commands {
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("Add a server address…") {
                    model.showAddAddress()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.screen != .library)
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard shortcuts") { model.showShortcutsHelp = true }
                    .keyboardShortcut("/", modifiers: [.command, .shift])
            }
            CommandMenu("Profiles") {
                ForEach(Array(model.profiles.prefix(9).enumerated()), id: \.element.id) { index, profile in
                    Button("\(profile.userName) — \(profile.serverName)") { model.switchProfile(profile) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.control, .command])
                }
                Divider()
                Button("Add a server…") { model.beginAddServer() }
            }
            CommandGroup(after: .sidebar) {
                Button("Home") {
                    model.selectedSection = .home
                }
                .keyboardShortcut("1", modifiers: .command)
                // The player has its own window: the page behind must not change during playback.
                .disabled(model.playback != nil)

                Button("Library") {
                    // The first movie library (otherwise the first one at all): it is in the sidebar.
                    let library = model.libraries.first { $0.collectionType == "movies" } ?? model.libraries.first
                    model.selectedSection = library.map { .library($0.id) } ?? .movies
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(model.playback != nil)

                Button("Search") {
                    model.selectedSection = .search
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.playback != nil)

                Button("Downloads") {
                    model.selectedSection = .downloads
                }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(model.playback != nil)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.Colors.accent)
        }
    }
}

/// Chooses the screen to show depending on the app state.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var playerWindow = PlayerWindowController()

    var body: some View {
        Group {
            switch model.screen {
            case .loading:
                ZStack {
                    Theme.Colors.background.ignoresSafeArea()
                    ProgressView().controlSize(.large)
                }
                .task { await model.start() }
            case .login:
                LoginView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Colors.background.ignoresSafeArea())
            case .library:
                LibraryView()
            }
        }
        .transition(.opacity)
        .animation(Theme.Motion.standard, value: model.screen)
        // The player has its own window (see `PlayerWindowController`): nothing here changes during playback.
        .background(HostWindowReader { playerWindow.hostWindow = $0 })
        // Each new item (next episode, another video started meanwhile) goes through `show`: the window title follows.
        .onChange(of: model.playback?.movie.id) { _, id in
            if id != nil { playerWindow.show(model: model) } else { playerWindow.close() }
        }
        .sheet(isPresented: Binding(
            get: { model.showShortcutsHelp },
            set: { model.showShortcutsHelp = $0 }
        )) {
            ShortcutsHelpView()
        }
        .sheet(isPresented: Binding(
            get: { model.promptSecondaryAddress },
            set: { model.promptSecondaryAddress = $0 }
        )) {
            SecondaryAddressSheet()
        }
        .alert("Profile storage corrupted", isPresented: Binding(
            get: { model.corruptProfileStorageError },
            set: { model.corruptProfileStorageError = $0 }
        )) {
            Button("Reset and repair", role: .destructive) {
                do {
                    try model.repairCorruptProfileStorage()
                } catch {
                    model.offlineAlertMessage = "Repair failed: \(error.localizedDescription)"
                }
            }
            Button("Cancel", role: .cancel) {
                model.corruptProfileStorageError = false
            }
        } message: {
            Text("The local profile storage is corrupted. Do you want to reset it? A backup will be kept.")
        }
    }
}
