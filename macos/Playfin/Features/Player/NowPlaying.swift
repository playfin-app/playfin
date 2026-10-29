import AppKit
import MediaPlayer
import SwiftUI

/// macOS media controls: the ⏯ ⏪ ⏩ keys, the "Now Playing" widget of the Control Centre and the headphone
/// buttons. macOS shows the title and moves the position by itself from the rate: we only tell it about
/// changes (pause, jump, speed, new item).
@MainActor
final class NowPlayingCenter {
    private weak var controller: PlayerController?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var info: [String: Any] = [:]
    private var artworkTask: Task<Void, Never>?
    /// Last position given to macOS, to spot a jump (its own clock moves on between two updates).
    private var sentElapsed: Double = 0
    private var sentAt = Date()
    private var sentRate: Double = 0

    func start(controller: PlayerController) {
        self.controller = controller
        let center = MPRemoteCommandCenter.shared()
        add(center.togglePlayPauseCommand) { $0.togglePlayPause() }
        add(center.playCommand) { if $0.isPaused { $0.togglePlayPause() } }
        add(center.pauseCommand) { if !$0.isPaused { $0.togglePlayPause() } }
        add(center.skipBackwardCommand) { $0.skipBack() }
        add(center.skipForwardCommand) { $0.skipForward() }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: controller.skipBackSeconds)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: controller.skipForwardSeconds)]
        add(center.nextTrackCommand) { $0.playNextEpisode?() }
        add(center.previousTrackCommand) { $0.playPreviousEpisode?() }
        targets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in self?.controller?.seek(absolute: seconds) }
            return .success
        }))
    }

    /// New item (start, next episode): title, duration and poster.
    func setItem(_ movie: Movie, artworkURL: URL?) {
        info = [
            MPMediaItemPropertyTitle: movie.displayTitle,
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: (movie.isAudio
                ? MPNowPlayingInfoMediaType.audio : .video).rawValue),
        ]
        if let subtitle = movie.episodeSubtitle ?? movie.productionYear.map({ String($0) }) {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        update()

        artworkTask?.cancel()
        guard let artworkURL else { return }
        artworkTask = Task {
            guard let (data, _) = try? await URLSession.shared.data(from: artworkURL),
                  !Task.isCancelled, let image = NSImage(data: data) else { return }
            nonisolated(unsafe) let artworkImage = image
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in artworkImage }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// Pause, speed, duration or position changed.
    func update() {
        guard let controller else { return }
        let rate = controller.isPaused ? 0 : controller.playbackSpeed
        info[MPMediaItemPropertyPlaybackDuration] = controller.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = controller.displayedTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = controller.isPaused ? .paused : .playing
        sentElapsed = controller.displayedTime
        sentAt = Date()
        sentRate = rate
    }

    /// Position read 4 times per second: macOS is only told when it no longer matches its own clock (a jump).
    func updateIfJumped() {
        guard let controller else { return }
        let expected = sentElapsed + sentRate * Date().timeIntervalSince(sentAt)
        if abs(controller.displayedTime - expected) > 1.5 { update() }
    }

    func stop() {
        artworkTask?.cancel()
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        controller = nil
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerController) -> Void) {
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let controller = self?.controller else { return }
                action(controller)
            }
            return .success
        }
        targets.append((command, target))
    }
}

/// Keeps `NowPlayingCenter` up to date. Its own small view: only it is redrawn when the position moves, not
/// the whole player.
struct NowPlayingSync: View {
    let controller: PlayerController
    let center: NowPlayingCenter

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: controller.isPaused) { _, _ in center.update() }
            .onChange(of: controller.duration) { _, _ in center.update() }
            .onChange(of: controller.playbackSpeed) { _, _ in center.update() }
            .onChange(of: controller.displayedTime) { _, _ in center.updateIfJumped() }
    }
}
