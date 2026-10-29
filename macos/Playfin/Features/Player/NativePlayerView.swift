import AppKit
import SwiftUI

/// Modern video player with a native macOS / PlxNative interface.
struct NativePlayerView: View {
    let playback: Playback
    let subtitles: [ExternalSubtitle]
    var onStart: (Double) -> Void
    var onProgress: (Double, Bool) -> Void
    var onStop: (Double) -> Void
    var onClose: () -> Void
    var onFailure: (String) -> Void = { _ in }
    var onFinished: () -> Void = {}
    var skipBackSeconds: UInt32 = 10
    var skipForwardSeconds: UInt32 = 10
    var segments: [MediaSegment] = []
    var initialVolume: UInt32 = 100
    var onVolumeChange: (UInt32) -> Void = { _ in }
    /// "Next episode" card (only when the automatic playback is on: it counts down).
    var upNext: Movie?
    var onPlayUpNext: () -> Void = {}
    /// Episodes around the current one (buttons and N / P keys), whatever the automatic playback setting.
    var nextEpisode: Movie?
    var previousEpisode: Movie?
    var onPlayPrevious: () -> Void = {}
    var preferredAudioLanguages: [String] = []
    var preferredSubtitleLanguages: [String] = []

    @Environment(AppModel.self) private var model
    @State private var controller = PlayerController()
    @State private var isControlsVisible = true
    @State private var isOverlayHovered = false
    @State private var autoHideTask: Task<Void, Never>? = nil
    @State private var keyMonitor: Any? = nil
    @State private var barHeight: CGFloat = 0
    @State private var playerHeight: CGFloat = 0
    @State private var upNextDismissed = false
    @State private var isPopoverOpen = false
    /// When a window (tracks, options) last closed, and the filter of the clicks that only close it.
    @State private var popoverClosedAt: Date?
    @State private var menuClickGuard = MenuClickGuard()
    @State private var volumeSaveTask: Task<Void, Never>?
    @State private var nowPlaying = NowPlayingCenter()

    var body: some View {
        ZStack {
            // 1. OpenGL video rendering (libmpv)
            MPVPlayerView(
                playback: playback,
                subtitles: subtitles,
                controller: controller,
                onStart: onStart,
                onProgress: onProgress,
                onStop: onStop,
                onClose: onClose,
                onFailure: onFailure,
                onFinished: onFinished
            )

            // 1 bis. Audiobook: no video picture, we show the cover
            if playback.movie.isAudio {
                audioCover
            }

            // 2. Click area on the video: pause reacts on the first click (without waiting for a possible double click);
            // a double click silently cancels that pause and goes full screen.
            VideoClickArea(dragsWindow: controller.isMiniPlayer) { click in
                // A click beside an open window only closes it: no pause.
                switch menuClickGuard.filter(click, menuOpen: isPopoverOpen, menuClosedAt: popoverClosedAt) {
                case .togglePause:
                    controller.togglePlayPause()
                    revealControls()
                case .undoPauseAndToggleFullScreen:
                    controller.undoClickPause()
                    toggleFullScreen()
                case .ignore:
                    break
                }
            }

            // 3. Animated indicator in the centre on actions (Play, Pause, Forward/Back 10s)
            // Only one icon at a time: each action creates a new icon (identifier) that replaces the
            // previous one with a fade, with no overlap or scale effect.
            if controller.showCenterSplash {
                Image(systemName: controller.centerSplashIcon)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .id(controller.splashId)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            // 3 bis. "Skip intro / credits" when the server has spotted a segment
            // 3 ter. "Next episode" card during the end credits (or the last 30 seconds)
            // Both read the position in their own view: this one is not redrawn 4 times per second.
            // Not in the small window: no room.
            if !controller.isMiniPlayer {
            SegmentSkipOverlay(controller: controller, segments: segments,
                               isControlsVisible: isControlsVisible, barHeight: barHeight)
            }
            if let next = upNext, !controller.isMiniPlayer {
                UpNextOverlay(
                    controller: controller, episode: next, segments: segments,
                    isDismissed: upNextDismissed, isControlsVisible: isControlsVisible, barHeight: barHeight,
                    onPlay: onPlayUpNext,
                    onDismiss: { withAnimation(Theme.Motion.standard) { upNextDismissed = true } }
                )
            }

            // 4. Native control interface over the video (compact in picture in picture)
            if controller.isMiniPlayer {
                MiniPlayerControls(controller: controller, isVisible: isControlsVisible,
                                   onClose: onClose, onExit: toggleMiniPlayer)
            } else {
            PlayerControlsOverlay(
                movie: playback.movie,
                controller: controller,
                isVisible: isControlsVisible,
                onClose: onClose,
                onToggleFullScreen: toggleFullScreen,
                onToggleMiniPlayer: toggleMiniPlayer,
                episodeNavigation: playback.movie.itemType == "Episode"
                    ? EpisodeNavigation(
                        hasPrevious: previousEpisode != nil, hasNext: nextEpisode != nil,
                        onPrevious: onPlayPrevious, onNext: onPlayUpNext)
                    : nil,
                segments: segments,
                isOverlayHovered: $isOverlayHovered,
                barHeight: $barHeight,
                isPopoverOpen: $isPopoverOpen
            )
            }

            NowPlayingSync(controller: controller, center: nowPlaying)

            // 5. Modal window of the playback information
            if controller.showInfoSheet {
                PlayerInfoSheet(movie: playback.movie, controller: controller)
                    .transition(Theme.Motion.panelTransition)
            }
            if controller.showSubtitleSettings {
                SubtitleSettingsSheet(controller: controller, settings: model.settings)
                    .transition(Theme.Motion.panelTransition)
            }
        }
        .background(Color.black)
        // The panels open and close from many places (menu, ✕, Esc, gear): animated here once for all.
        .animation(Theme.Motion.panel, value: controller.showInfoSheet)
        .animation(Theme.Motion.panel, value: controller.showSubtitleSettings)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { playerHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, height in playerHeight = height }
        })
        .onChange(of: isControlsVisible) { _, _ in updateSubtitlePosition() }
        .onChange(of: controller.isMiniPlayer) { _, _ in updateSubtitlePosition() }
        .onChange(of: isPopoverOpen) { _, open in if !open { popoverClosedAt = Date() } }
        // The volume changes continuously during a drag: it is saved once the gesture is over (a file write
        // at every position made the slider jerky).
        .onChange(of: controller.volume) { _, value in
            volumeSaveTask?.cancel()
            volumeSaveTask = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                onVolumeChange(UInt32(max(0, min(100, value))))
            }
        }
        // Next episode in the same player: we start again from a clean state.
        .onChange(of: playback.movie.id) { _, _ in
            controller.resetForNewItem()
            controller.trackMemorySeriesId = playback.movie.itemType == "Episode" ? playback.movie.seriesId : nil
            controller.initialTrackChoice = playback.initialTracks
            upNextDismissed = false
            nowPlaying.setItem(playback.movie, artworkURL: model.imageURL(playback.movie, .primary, height: 600))
            revealControls()
        }
        // The episodes around arrive a little after the start (server request).
        .onChange(of: nextEpisode?.id, initial: true) { _, _ in
            controller.playNextEpisode = nextEpisode != nil ? onPlayUpNext : nil
        }
        .onChange(of: previousEpisode?.id, initial: true) { _, _ in
            controller.playPreviousEpisode = previousEpisode != nil ? onPlayPrevious : nil
        }
        .onChange(of: barHeight) { _, _ in if isControlsVisible { updateSubtitlePosition() } }
        .onChange(of: playerHeight) { _, _ in if isControlsVisible { updateSubtitlePosition() } }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                revealControls()
            case .ended:
                scheduleAutoHide()
            }
        }
        .onAppear {
            controller.volume = Double(initialVolume)
            controller.skipBackSeconds = skipBackSeconds
            controller.skipForwardSeconds = skipForwardSeconds
            controller.preferredAudioLanguages = preferredAudioLanguages
            controller.preferredSubtitleLanguages = preferredSubtitleLanguages
            controller.trackMemorySeriesId = playback.movie.itemType == "Episode" ? playback.movie.seriesId : nil
            controller.initialTrackChoice = playback.initialTracks
            revealControls()
            setupKeyMonitor()
            nowPlaying.start(controller: controller)
            nowPlaying.setItem(playback.movie, artworkURL: model.imageURL(playback.movie, .primary, height: 600))
        }
        .onDisappear {
            NSCursor.unhide()
            removeKeyMonitor()
            nowPlaying.stop()
        }
    }

    /// Listening screen: square cover on a black background (the audio stream has no picture).
    private var audioCover: some View {
        ZStack {
            Color.black
            VStack(spacing: 20) {
                AsyncArtwork(
                    url: model.imageURL(playback.movie, .primary, height: 700),
                    blurHash: playback.movie.primaryBlurHash,
                    targetBlurHashSize: CGSize(width: 32, height: 32),
                    contentMode: .fill
                ) {
                    Color.white.opacity(0.08).overlay(
                        Image(systemName: "headphones").font(.system(size: 80)).foregroundStyle(.white.opacity(0.4))
                    )
                }
                .frame(width: coverSide, height: coverSide)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .white.opacity(0.08), radius: 24)

                if !controller.isMiniPlayer {
                    Text(playback.movie.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var coverSide: CGFloat { controller.isMiniPlayer ? 140 : 360 }

    private func updateSubtitlePosition() {
        // The compact controls leave the bottom of the picture free.
        controller.setSubtitlePosition(SubtitleLayout.position(
            barHeight: barHeight, playerHeight: playerHeight, controlsVisible: isControlsVisible && !controller.isMiniPlayer
        ))
    }

    private func revealControls() {
        NSCursor.unhide()
        withAnimation(Theme.Motion.controls) {
            isControlsVisible = true
        }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task {
            try? await Task.sleep(for: Theme.Motion.controlsHideDelay)
            guard !Task.isCancelled else { return }
            // Do not hide the controls if the video is paused, the mouse is on the controls or a popup is open
            if ControlsVisibility.canHide(
                isPaused: controller.isPaused, infoSheetOpen: controller.showInfoSheet || controller.showSubtitleSettings,
                overlayHovered: isOverlayHovered, scrubbing: controller.isScrubbing, menuOpen: isPopoverOpen
            ) {
                withAnimation(Theme.Motion.controls) {
                    isControlsVisible = false
                }
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    /// The player window (its own, see `PlayerWindowController`): its full screen goes away with it.
    private func toggleFullScreen() {
        // From the small window, F or a double click give the big player back.
        if controller.isMiniPlayer { toggleMiniPlayer(); return }
        (controller.engine?.hostWindow ?? NSApplication.shared.keyWindow)?.toggleFullScreen(nil)
    }

    /// Picture in picture on or off (see `MiniPlayer`).
    private func toggleMiniPlayer() {
        guard let window = controller.engine?.hostWindow else { return }
        if controller.isMiniPlayer {
            MiniPlayer.exit(window, to: controller.frameBeforeMiniPlayer, video: controller.engine)
            controller.frameBeforeMiniPlayer = nil
            controller.isMiniPlayer = false
        } else {
            // The panels are as wide as the small window: closed.
            controller.showInfoSheet = false
            controller.showSubtitleSettings = false
            MiniPlayer.enter(window, video: controller.engine) { previous in
                controller.frameBeforeMiniPlayer = previous
                controller.isMiniPlayer = true
            }
        }
        revealControls()
    }

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let inPlayerWindow = event.window != nil && event.window === controller.engine?.hostWindow
            let typing = event.window?.firstResponder is NSText
            guard PlayerKeyAction.shouldHandle(
                    eventWindowIsPlayerWindow: inPlayerWindow, isTypingText: typing,
                    hasCommandModifier: event.modifierFlags.contains(.command)),
                  let action = PlayerKeyAction.from(keyCode: event.keyCode) else { return event }
            switch action {
            case .escape:
                let window = controller.engine?.hostWindow
                switch EscapeAction.resolve(
                    infoSheetOpen: controller.showInfoSheet, subtitleSettingsOpen: controller.showSubtitleSettings,
                    isFullScreen: window?.styleMask.contains(.fullScreen) == true
                ) {
                case .closeInfoSheet: controller.showInfoSheet = false
                case .closeSubtitleSettings: controller.showSubtitleSettings = false
                case .leaveFullScreen: window?.toggleFullScreen(nil)
                case .nothing: break
                }
            case .togglePause: controller.togglePlayPause()
            case .toggleFullScreen: toggleFullScreen()
            case .toggleMute: controller.toggleMute()
            case .skipBack: controller.skipBack()
            case .skipForward: controller.skipForward()
            case .volumeUp: controller.adjustVolume(by: 5)
            case .volumeDown: controller.adjustVolume(by: -5)
            // Read on the controller: this closure is created once, `nextEpisode` here would stay the first value.
            case .nextEpisode:
                guard let play = controller.playNextEpisode else { return event }
                play()
            case .previousEpisode:
                guard let play = controller.playPreviousEpisode else { return event }
                play()
            case .toggleSubtitles: controller.toggleSubtitles()
            case .slower: controller.stepSpeed(faster: false)
            case .faster: controller.stepSpeed(faster: true)
            }
            if action != .escape { revealControls() }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

/// "Skip intro / credits" button. Reads the playback position itself: the player around it is not
/// redrawn on each position read.
private struct SegmentSkipOverlay: View {
    let controller: PlayerController
    let segments: [MediaSegment]
    let isControlsVisible: Bool
    let barHeight: CGFloat

    var body: some View {
        if let offer = SegmentSkip.offer(at: controller.currentTime, in: segments) {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        controller.seek(absolute: offer.targetSeconds)
                    } label: {
                        Label(offer.title, systemImage: "forward.end.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 32)
                    // Above the control bar when it is visible
                    .padding(.bottom, isControlsVisible ? barHeight + 12 : 48)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .animation(Theme.Motion.standard, value: isControlsVisible)
        }
    }
}

/// "Next episode" card during the end credits (or the last 30 seconds). Reads the position itself.
private struct UpNextOverlay: View {
    let controller: PlayerController
    let episode: Movie
    let segments: [MediaSegment]
    let isDismissed: Bool
    let isControlsVisible: Bool
    let barHeight: CGFloat
    let onPlay: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        if !isDismissed, showsUpNext {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    UpNextCard(
                        episode: episode,
                        secondsLeft: max(0, Int(controller.duration - controller.currentTime)),
                        onPlay: onPlay,
                        onDismiss: onDismiss
                    )
                    .padding(.trailing, 32)
                    .padding(.bottom, isControlsVisible ? barHeight + 12 : 40)
                }
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(Theme.Motion.standard, value: isControlsVisible)
        }
    }

    /// End of the episode near: credits spotted by the server, or less than 30 s remaining.
    private var showsUpNext: Bool {
        guard controller.duration > 60 else { return false }
        if let outro = segments.first(where: { $0.kind == "Outro" }),
           controller.currentTime >= Double(outro.startTicks) / ticksPerSecond {
            return true
        }
        return controller.duration - controller.currentTime <= 30
    }
}

/// Window of technical information about the current playback.
struct PlayerInfoSheet: View {
    let movie: Movie
    let controller: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Stream details")
                    .font(.headline)
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    controller.showInfoSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                InfoRow(label: "Title", value: movie.displayTitle)
                InfoRow(label: "Mode", value: "Direct play (raw stream, no conversion)")
                if !controller.videoResolution.isEmpty {
                    InfoRow(label: "Resolution", value: controller.videoResolution)
                } else if let badge = movie.resolutionBadge {
                    InfoRow(label: "Resolution", value: badge)
                }
                if !controller.videoCodec.isEmpty {
                    InfoRow(label: "Video codec", value: controller.videoCodec)
                }
                InfoRow(
                    label: "Decoding",
                    value: (controller.hwdecCurrent.isEmpty || controller.hwdecCurrent == "no")
                        ? "Software (CPU)"
                        : "VideoToolbox (Hardware)"
                )
                if !controller.dynamicRange.isEmpty {
                    InfoRow(label: "Dynamic range", value: controller.dynamicRange)
                }
                if controller.cacheDuration > 0 {
                    InfoRow(label: "RAM cache", value: String(format: "%.1f s ahead", controller.cacheDuration))
                }
                if let container = movie.container {
                    InfoRow(label: "Container", value: container.uppercased())
                }
                InfoRow(
                    label: "Audio track",
                    value: controller.audioCodec.isEmpty
                        ? controller.currentAudioTitle
                        : "\(controller.currentAudioTitle) (\(controller.audioCodec))"
                )
                InfoRow(label: "Subtitles", value: controller.currentSubtitleTitle)
                InfoRow(label: "Position", value: "\(formatPlayerTime(controller.currentTime)) / \(formatPlayerTime(controller.duration))")
                InfoRow(label: "Speed", value: formatPlaybackSpeed(controller.playbackSpeed))
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(radius: 30)
        )
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption.bold())
                .foregroundStyle(.white)
        }
    }
}

/// Formats seconds as "00:45:12" or "45:12".
func formatPlayerTime(_ seconds: Double) -> String {
    guard !seconds.isNaN, !seconds.isInfinite, seconds >= 0 else { return "00:00" }
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    } else {
        return String(format: "%02d:%02d", m, s)
    }
}

/// "Next episode" card (Plex style): thumbnail, title, countdown, "Play now".
struct UpNextCard: View {
    @Environment(AppModel.self) private var model
    let episode: Movie
    let secondsLeft: Int
    let onPlay: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            AsyncArtwork(
                url: model.episodeThumbnailURL(episode, height: 240),
                blurHash: episode.primaryBlurHash,
                targetBlurHashSize: CGSize(width: 32, height: 18),
                contentMode: .fill
            )
            .frame(width: 150, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))

            VStack(alignment: .leading, spacing: 6) {
                Text("Next episode\(secondsLeft > 0 ? " in \(secondsLeft) s" : "")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Colors.accent)
                Text(episode.episodeSubtitle ?? episode.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: 220, alignment: .leading)
                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        Label("Play now", systemImage: "play.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(PressableButtonStyle())
                    Button("Hide", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .padding(12)
        .background(GlassPanel(cornerRadius: Theme.Radius.panel))
    }
}
