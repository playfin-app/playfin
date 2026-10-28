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

    /// Demo artwork: a sky gradient, a glowing sun and layered mountains (no real poster is used).
    private func demoImage(_ seed: Int, size: CGSize, title: String) -> NSImage {
        let palette: [(NSColor, NSColor)] = [
            (.systemIndigo, .systemOrange), (.systemPurple, .systemPink), (.systemTeal, .systemBlue),
            (.systemBlue, .systemPurple), (.systemRed, .systemOrange), (.systemGreen, .systemTeal)
        ]
        let (top, bottom) = palette[seed % palette.count]
        let rect = NSRect(origin: .zero, size: size)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: bottom.blended(withFraction: 0.2, of: .black) ?? bottom,
                   ending: top.blended(withFraction: 0.7, of: .black) ?? top)?.draw(in: rect, angle: 90)

        // Sun with a soft glow.
        let sun = NSPoint(x: size.width * (0.3 + CGFloat(seed % 4) * 0.13), y: size.height * 0.52)
        let radius = min(size.width, size.height) * 0.14
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.55), bottom.withAlphaComponent(0)])?
            .draw(fromCenter: sun, radius: 0, toCenter: sun, radius: radius * 3.5, options: [])
        NSColor(calibratedWhite: 1, alpha: 0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: sun.x - radius, y: sun.y - radius, width: radius * 2, height: radius * 2)).fill()

        // Three mountain ranges, darker towards the front.
        for layer in 0..<3 {
            let path = NSBezierPath()
            let base = size.height * (0.42 - CGFloat(layer) * 0.12)
            path.move(to: NSPoint(x: 0, y: 0))
            path.line(to: NSPoint(x: 0, y: base))
            let peaks = 5 + layer
            for peak in 0...peaks {
                let x = size.width * CGFloat(peak) / CGFloat(peaks)
                let wave = sin(Double(peak * 7 + seed * 3 + layer * 5))
                path.line(to: NSPoint(x: x, y: base + size.height * (0.08 + 0.07 * CGFloat(wave))))
            }
            path.line(to: NSPoint(x: size.width, y: 0))
            path.close()
            (top.blended(withFraction: 0.55 + CGFloat(layer) * 0.15, of: .black) ?? top).setFill()
            path.fill()
        }

        if !title.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size.width / 10, weight: .heavy),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92)
            ]
            NSAttributedString(string: title, attributes: attributes)
                .draw(at: NSPoint(x: size.width * 0.08, y: size.height * 0.06))
        }
        image.unlockFocus()
        return image
    }

    private let demoOverviews = [
        "A cartographer follows an old map to the edge of the known world, where the sky meets a sea of mountains.",
        "Two siblings return to their mountain village and uncover the secret their family kept for forty years.",
        "When the last lighthouse keeper disappears, a young pilot must guide the night ships home.",
        "A team of climbers races a winter storm to reach a summit no one has seen since the war."
    ]

    private func demoMovie(_ index: Int, type: String = "Movie", name: String, series: String? = nil, played: Bool = false,
                           position: Int64 = 0) -> Movie {
        var movie = Movie(
            id: "demo-\(index)", name: name, sortName: nil, productionYear: Int32(2010 + index % 14), premiereDate: nil,
            runTimeTicks: 72_000_000_000, container: "mkv",
            overview: demoOverviews[index % demoOverviews.count],
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
                for height: UInt32 in [240, 360, 400, 450, 650, 1080, 1440] {
                    if let url = model.imageURL(item, kind, height: height) {
                        let title = kind == .primary ? item.displayTitle : ""
                        ImageCache.shared.store(image: demoImage(index, size: size, title: title), forKey: ImageCache.shared.cacheKey(for: url))
                    }
                    if let url = model.episodeThumbnailURL(item, height: height) {
                        ImageCache.shared.store(image: demoImage(index + 2, size: CGSize(width: 640, height: 360), title: ""),
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
            size: CGSize(width: 1280, height: 860), name: "home", to: dir
        )
        try render(
            NavigationStack { MovieDetailView(movie: movies[0]) }.environment(model),
            size: CGSize(width: 1280, height: 860), name: "movie", to: dir
        )
        try render(
            NavigationStack { DownloadsView() }.environment(model),
            size: CGSize(width: 1000, height: 600), name: "downloads", to: dir
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
            size: CGSize(width: 1280, height: 720), name: "player", to: dir
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
            size: CGSize(width: 720, height: 760), name: "settings-profiles", to: dir
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
