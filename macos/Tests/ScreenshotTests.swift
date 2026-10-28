import XCTest
import SwiftUI
@testable import Playfin

/// Renders a few screens to PNG for the README (`docs/screenshots/`), without a server or a system screenshot.
/// Only runs on demand: `RENDER_SCREENSHOTS=1` in the test environment.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["RENDER_SCREENSHOTS"], !path.isEmpty, path != "0" else {
            return nil
        }
        return URL(fileURLWithPath: path == "1" ? FileManager.default.currentDirectoryPath : path)
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String, to dir: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("rendering impossible") }
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    // MARK: Demo data (no server: images drawn and put in the memory cache)

    private func demoImage(_ seed: Int, size: CGSize, title: String) -> NSImage {
        let palette: [(NSColor, NSColor)] = [
            (.systemBlue, .systemPurple), (.systemOrange, .systemRed), (.systemTeal, .systemIndigo),
            (.systemPink, .systemPurple), (.systemGreen, .systemTeal), (.systemYellow, .systemOrange)
        ]
        let (a, b) = palette[seed % palette.count]
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: a.blended(withFraction: 0.35, of: .black) ?? a, ending: b.blended(withFraction: 0.55, of: .black) ?? b)?
            .draw(in: NSRect(origin: .zero, size: size), angle: -60)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size.width / 9, weight: .heavy),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        text.draw(at: NSPoint(x: size.width * 0.08, y: size.height * 0.1))
        image.unlockFocus()
        return image
    }

    private func demoMovie(_ index: Int, type: String = "Movie", name: String, series: String? = nil, played: Bool = false,
                           position: Int64 = 0) -> Movie {
        var movie = Movie(
            id: "demo-\(index)", name: name, sortName: nil, productionYear: Int32(2010 + index % 14), premiereDate: nil,
            runTimeTicks: 72_000_000_000, container: "mkv",
            overview: "A demo story to check the layout: title, multi-line summary, "
                + "buttons and rows. No data comes from a real server.",
            communityRating: 7.4, criticRating: nil, officialRating: "PG-13", genres: ["Adventure", "Drama"],
            dateCreated: nil, people: [], userData: UserData(playbackPositionTicks: position, played: played, playedPercentage: nil),
            seriesName: series, seriesId: series == nil ? nil : "demo-series", seasonId: nil, seasonName: nil,
            indexNumber: type == "Episode" ? Int32(index) : nil, parentIndexNumber: type == "Episode" ? 1 : nil, itemType: type,
            width: 3840, height: 2160, primaryBlurHash: nil, primaryImageAspectRatio: nil
        )
        movie.imageTags = [ImageTag(kind: "Primary", tag: "t\(index)")]
        movie.backdropImageTags = ["b\(index)"]
        return movie
    }

    private func seedImages(model: AppModel, items: [Movie]) {
        for (index, item) in items.enumerated() {
            for (kind, size) in [(ImageKind.primary, CGSize(width: 300, height: 450)), (.backdrop, CGSize(width: 1280, height: 720))] {
                for height: UInt32 in [360, 400, 450, 650, 1080, 1440] {
                    if let url = model.imageURL(item, kind, height: height) {
                        ImageCache.shared.store(image: demoImage(index, size: size, title: item.displayTitle), forKey: ImageCache.shared.cacheKey(for: url))
                    }
                    if let url = model.episodeThumbnailURL(item, height: height) {
                        ImageCache.shared.store(image: demoImage(index + 2, size: CGSize(width: 640, height: 360), title: item.name),
                                                forKey: ImageCache.shared.cacheKey(for: url))
                    }
                }
            }
        }
    }

    /// Home, a movie page and the Downloads screen with demo data: used to check
    /// the layout without a server (the files go to the requested folder, not into the repository).
    func testRenderLayoutChecks() throws {
        guard let dir = outputDirectory else { throw XCTSkip("RENDER_SCREENSHOTS not set") }
        let model = AppModel()
        model.client = JellyfinClient.restore(
            info: SessionInfo(serverUrl: "http://demo.example.com", serverId: "demo", userId: "demo", accessToken: "t"),
            cacheDir: FileManager.default.temporaryDirectory.appendingPathComponent("jn-demo").path
        )
        let movies = (1...8).map { demoMovie($0, name: ["Horizon", "The Shadows", "Odyssey", "Vertigo", "North", "Atlas", "Echo", "Light"][$0 - 1]) }
        let resume = [demoMovie(20, type: "Episode", name: "The Return", series: "The Explorers", position: 18_000_000_000),
                      demoMovie(21, name: "The Great Journey", position: 30_000_000_000)]
        model.resume = resume
        model.nextUp = [demoMovie(22, type: "Episode", name: "The Crossing", series: "The Explorers")]
        model.latest = movies
        model.remember(movies + resume + model.nextUp)
        seedImages(model: model, items: movies + resume + model.nextUp)
        model.screen = .library

        try render(
            NavigationStack { HomeView() }.environment(model),
            size: CGSize(width: 1280, height: 860), name: "check-home", to: dir
        )
        try render(
            NavigationStack { MovieDetailView(movie: movies[0]) }.environment(model),
            size: CGSize(width: 1280, height: 860), name: "check-movie", to: dir
        )
        try render(
            NavigationStack { DownloadsView() }.environment(model),
            size: CGSize(width: 1000, height: 600), name: "check-downloads", to: dir
        )

        // Player: controls over an image (the video), with tracks and position.
        let controller = PlayerController()
        controller.update(
            position: 1234, duration: 5400, isPaused: true, volume: 70, isMuted: false, speed: 1,
            audioTracks: [TrackItem(id: 1, type: "audio", title: "", language: "fre", isSelected: true, codec: "eac3", channels: 6)],
            subtitleTracks: [TrackItem(id: 2, type: "sub", title: "", language: "eng", isSelected: false)],
            selectedAudioId: 1, selectedSubtitleId: nil
        )
        let backdrop = demoImage(3, size: CGSize(width: 1280, height: 720), title: "")
        try render(
            ZStack {
                Image(nsImage: backdrop).resizable()
                PlayerControlsOverlay(
                    movie: resume[0], controller: controller, isVisible: true, onClose: {}, onToggleFullScreen: {},
                    isOverlayHovered: .constant(false), barHeight: .constant(0), isPopoverOpen: .constant(false)
                )
                VStack { Spacer(); HStack { Spacer(); UpNextCard(episode: model.nextUp[0], secondsLeft: 12, onPlay: {}, onDismiss: {}) }
                    .padding(.trailing, 32).padding(.bottom, 200) }
            }
            .environment(model),
            size: CGSize(width: 1280, height: 720), name: "check-player", to: dir
        )

        // Player windows: tracks (language page) and options.
        let groups = TrackGrouping.groups([
            TrackItem(id: 1, type: "sub", title: "", language: "eng", isSelected: true),
            TrackItem(id: 2, type: "sub", title: "SDH", language: "eng", isSelected: false, isHearingImpaired: true),
            TrackItem(id: 3, type: "sub", title: "", language: "fre", isSelected: false)
        ], preferred: ["fr"])
        try render(
            TrackPopover(kind: .subtitles, groups: groups, isActive: true, onSelect: { _ in }, onDisable: {})
                .background(Color(white: 0.16)),
            size: CGSize(width: 300, height: 230), name: "check-popover-tracks", to: dir
        )
        try render(
            OptionsPopover(controller: controller, close: {}).background(Color(white: 0.16)),
            size: CGSize(width: 340, height: 220), name: "check-popover-options", to: dir
        )

        // Settings > Profiles with a server with two addresses.
        AppPaths.supportDirectoryOverride = FileManager.default.temporaryDirectory.appendingPathComponent("jn-shot-\(UUID().uuidString)")
        defer { AppPaths.supportDirectoryOverride = nil }
        ProfileStore.setStorageDirectory(AppPaths.supportDirectoryOverride)
        defer { ProfileStore.setStorageDirectory(nil) }
        try ProfileStore.saveAll([ServerProfile(
            serverId: "demo", serverName: "Lounge", userId: "demo", userName: "Ana", userAvatarTag: nil,
            addresses: [
                ServerAddress(url: "http://192.0.2.10:8096", label: "Home", priority: 1, isLocal: true),
                ServerAddress(url: "https://jellyfin.example.com", label: "Remote", priority: 2, isLocal: false)
            ],
            isPrimary: true
        )])
        model.refreshProfiles()
        try render(
            ProfilesSettingsTab().environment(model).frame(width: 720, height: 760),
            size: CGSize(width: 720, height: 760), name: "check-settings-profiles", to: dir
        )
    }

    func testRenderReadmeScreenshots() throws {
        guard let dir = outputDirectory else { throw XCTSkip("RENDER_SCREENSHOTS not set") }
        let model = AppModel()
        try render(
            LoginView().environment(model).frame(width: 900, height: 640).background(Theme.Colors.background),
            size: CGSize(width: 900, height: 640), name: "login", to: dir
        )
        try render(
            PlayerCacheSettingsTab().environment(model).frame(width: 720, height: 620),
            size: CGSize(width: 720, height: 620), name: "settings-player-cache", to: dir
        )
        try render(
            PlaybackSettingsTab().environment(model).frame(width: 720, height: 620),
            size: CGSize(width: 720, height: 620), name: "settings-playback", to: dir
        )
        try render(
            ShortcutsHelpView().frame(width: 520).background(Theme.Colors.background),
            size: CGSize(width: 520, height: 600), name: "shortcuts", to: dir
        )
    }
}
