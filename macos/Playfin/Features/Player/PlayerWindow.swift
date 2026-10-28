import AppKit
import SwiftUI

/// The player lives in its own window, placed exactly over the main window. During playback the main window
/// (library, toolbar) no longer changes at all: nothing to lay out again under the video, and closing the
/// player only removes its window (the library is already drawn behind). In full screen, the player window
/// goes to its own space, like IINA or QuickTime.
@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    /// The main window, read by `HostWindowReader`: the player opens over it and gives the focus back to it.
    weak var hostWindow: NSWindow?
    /// The player window while it is open (read by the tests).
    private(set) var window: NSWindow?
    private var model: AppModel?

    /// Opens the window (the content follows `model.playback` by itself: next episode in the same window).
    /// Called again for each new item: the title follows (Window menu, Mission Control, ⌘`).
    func show(model: AppModel) {
        self.model = model
        if let window {
            window.title = Self.title(for: model.playback?.movie)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: PlayerWindowContent()
            .environment(model)
            .preferredColorScheme(.dark)
            .tint(Theme.Colors.accent))
        // The window decides its size, not the content.
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.title = Self.title(for: model.playback?.movie)
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Never reopened at the next launch (macOS window restoration).
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        Self.hideWindowButtons(of: window)
        window.delegate = self
        if let hostWindow {
            window.setFrame(hostWindow.frame, display: false)
        } else {
            window.setContentSize(NSSize(width: 1280, height: 720))
            window.center()
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        // Main window in full screen: the player goes full screen too (otherwise it would open on the desktop).
        if hostWindow?.styleMask.contains(.fullScreen) == true {
            window.toggleFullScreen(nil)
        }
    }

    /// Window title: "Alone · S3:E1 · A New Land" for an episode, the name for a movie.
    static func title(for movie: Movie?) -> String {
        guard let movie else { return "Playfin" }
        return [movie.displayTitle, movie.episodeSubtitle].compactMap { $0 }.joined(separator: " · ")
    }

    /// Closes the window (playback over). Its full-screen space goes away with it.
    func close() {
        guard let window else { return }
        self.window = nil
        window.delegate = nil
        window.close()
        hostWindow?.makeKeyAndOrderFront(nil)
    }

    /// No close / minimise / zoom buttons over the video: "Close", Esc and ⌘W close, F or the button goes full
    /// screen, ⌘M still minimises.
    static func hideWindowButtons(of window: NSWindow) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
    }

    /// Back from full screen: macOS rebuilds the title bar, the buttons stay hidden.
    func windowDidExitFullScreen(_ notification: Notification) {
        if let window { Self.hideWindowButtons(of: window) }
    }

    /// ⌘W: the playback stops like with the "Close" button.
    func windowWillClose(_ notification: Notification) {
        window = nil
        hostWindow?.makeKeyAndOrderFront(nil)
        if model?.playback != nil { model?.playback = nil }
    }
}

/// Content of the player window: the player of the current playback (black between two items).
struct PlayerWindowContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let playback = model.playback {
            NativePlayerView(
                playback: playback,
                subtitles: model.pendingSubtitles,
                onStart: { model.reportStart(playback.movie, seconds: $0) },
                onProgress: { model.reportProgress(playback.movie, seconds: $0, isPaused: $1) },
                onStop: { model.reportStopped(playback.movie, seconds: $0) },
                onClose: { model.playback = nil },
                onFailure: { model.offlineAlertMessage = $0 },
                onFinished: { model.playbackFinished() },
                skipBackSeconds: model.settings.values.skipBackSeconds,
                skipForwardSeconds: model.settings.values.skipForwardSeconds,
                segments: model.playbackSegments,
                initialVolume: model.settings.values.playerVolume,
                onVolumeChange: { model.settings.values.playerVolume = $0 },
                upNext: model.settings.values.autoPlayNext ? model.upNext : nil,
                onPlayUpNext: { model.playUpNext() },
                nextEpisode: model.upNext,
                previousEpisode: model.previousEpisode,
                onPlayPrevious: { model.playPreviousEpisode() },
                preferredAudioLanguages: TrackGrouping.preferredLanguages(
                    setting: model.settings.values.audioLanguage, system: PlayerOptions.systemLanguageCodes()),
                preferredSubtitleLanguages: TrackGrouping.preferredLanguages(
                    setting: model.settings.values.subtitleLanguage, system: PlayerOptions.systemLanguageCodes()))
            .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

/// Gives the window that contains the view (the main window), as soon as the view is in it.
struct HostWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
