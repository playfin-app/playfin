import Foundation
import SwiftUI
import Observation

/// Represents an audio or subtitle track.
struct TrackItem: Identifiable, Hashable {
    let id: Int
    let type: String // "audio", "sub"
    /// Raw title of the track (may be empty); display goes through `TrackGrouping`.
    var title: String
    var language: String?
    var isSelected: Bool
    var codec: String?
    var channels: Int?
    var isForced = false
    var isDefault = false
    var isHearingImpaired = false
    var isExternal = false
}

/// Represents a chapter of the video.
struct ChapterItem: Identifiable, Hashable {
    let index: Int
    let title: String
    let timeSeconds: Double
    var id: Int { index }
}

/// What the interface asks of the playback engine. The interface never calls libmpv directly:
/// the engine can be replaced or simulated in the tests.
@MainActor
protocol PlayerEngine: AnyObject {
    func togglePause()
    func seek(relative seconds: Double)
    func seek(absolute seconds: Double)
    func setVolume(_ volume: Double)
    func toggleMute()
    func setSpeed(_ speed: Double)
    func selectAudio(id: Int)
    func selectSubtitle(id: Int?)
    func setAspectRatio(_ ratio: String)
    func setPanScan(_ value: Double)
    func jumpToChapter(_ index: Int)
    func setSubtitlePosition(_ percent: Double)
    /// Any other mpv property (subtitle style, delay…), applied at once.
    func setProperty(_ name: String, to value: String)
    /// Window that shows the player (the player keys must only act in this one).
    var hostWindow: NSWindow? { get }
}

/// State controller of the video player, shared between SwiftUI and MPVNSView.
@MainActor
@Observable
final class PlayerController {
    var currentTime: Double = 0
    var duration: Double = 0
    var isPaused: Bool = false
    var isScrubbing: Bool = false
    var scrubTime: Double = 0

    var volume: Double = 100 {
        didSet {
            engine?.setVolume(volume)
        }
    }
    var isMuted: Bool = false
    var playbackSpeed: Double = 1.0

    var audioTracks: [TrackItem] = []
    var subtitleTracks: [TrackItem] = []
    var chapters: [ChapterItem] = []

    var selectedAudioId: Int? = nil
    var selectedSubtitleId: Int? = nil

    var currentAspectRatio: String = "-1"
    var isZoomed: Bool = false

    var showInfoSheet: Bool = false
    /// Subtitle settings panel (gear of the subtitles window).
    var showSubtitleSettings: Bool = false
    /// Picture in picture (see `MiniPlayer`): small floating window with compact controls.
    var isMiniPlayer: Bool = false
    /// Frame of the window before the picture in picture, given back on exit.
    @ObservationIgnored var frameBeforeMiniPlayer: NSRect?
    var showCenterSplash: Bool = false
    var centerSplashIcon: String = "play.fill"

    // Live metrics from libmpv
    var videoCodec: String = ""
    var audioCodec: String = ""
    var videoResolution: String = ""
    var cacheDuration: Double = 0
    var hwdecCurrent: String = ""

    /// Not observed: `MPVPlayerView` assigns it during every view update; a view reading it would then
    /// be redrawn endlessly.
    @ObservationIgnored weak var engine: (any PlayerEngine)?

    /// Preferred languages (settings, then system) to order the track menus.
    var preferredAudioLanguages: [String] = []
    var preferredSubtitleLanguages: [String] = []

    var audioGroups: [LanguageGroup] {
        TrackGrouping.groups(audioTracks, preferred: preferredAudioLanguages)
    }

    var subtitleGroups: [LanguageGroup] {
        TrackGrouping.groups(subtitleTracks, preferred: preferredSubtitleLanguages)
    }

    var currentAudioTitle: String {
        TrackGrouping.activeSummary(audioGroups) ?? "Default track"
    }

    var currentSubtitleTitle: String {
        TrackGrouping.activeSummary(subtitleGroups) ?? "Off"
    }

    func update(
        position: Double,
        duration: Double,
        isPaused: Bool,
        volume: Double,
        isMuted: Bool,
        speed: Double,
        audioTracks: [TrackItem],
        subtitleTracks: [TrackItem],
        selectedAudioId: Int?,
        selectedSubtitleId: Int?,
        videoCodec: String = "",
        audioCodec: String = "",
        videoResolution: String = "",
        cacheDuration: Double = 0,
        hwdecCurrent: String = ""
    ) {
        // Only write what changes: each write to an @Observable property redraws the views that read it,
        // and this function is called 4 times per second.
        if !isScrubbing {
            // After a jump, we keep the target displayed until mpv has reached it: otherwise the slider
            // briefly went back to the old position before moving on (lag effect).
            if let target = pendingSeekTarget {
                if abs(position - target) < 1.5 || Date() > pendingSeekDeadline {
                    pendingSeekTarget = nil
                    if self.currentTime != position { self.currentTime = position }
                }
            } else if self.currentTime != position {
                self.currentTime = position
            }
        }
        if self.duration != duration { self.duration = duration }
        if self.isPaused != isPaused { self.isPaused = isPaused }
        if self.isMuted != isMuted { self.isMuted = isMuted }
        if self.playbackSpeed != speed { self.playbackSpeed = speed }
        if self.audioTracks != audioTracks { self.audioTracks = audioTracks }
        if self.subtitleTracks != subtitleTracks { self.subtitleTracks = subtitleTracks }
        defer {
            applyTrackMemoryIfNeeded()
            applyInitialTrackChoiceIfNeeded()
        }
        if self.selectedAudioId != selectedAudioId { self.selectedAudioId = selectedAudioId }
        if self.selectedSubtitleId != selectedSubtitleId { self.selectedSubtitleId = selectedSubtitleId }
        if !videoCodec.isEmpty, self.videoCodec != videoCodec { self.videoCodec = videoCodec }
        if !audioCodec.isEmpty, self.audioCodec != audioCodec { self.audioCodec = audioCodec }
        if !videoResolution.isEmpty, self.videoResolution != videoResolution { self.videoResolution = videoResolution }
        if self.cacheDuration != cacheDuration { self.cacheDuration = cacheDuration }
        if !hwdecCurrent.isEmpty, self.hwdecCurrent != hwdecCurrent { self.hwdecCurrent = hwdecCurrent }
    }

    func togglePlayPause() {
        triggerCenterSplash(icon: isPaused ? "play.fill" : "pause.fill")
        engine?.togglePause()
    }

    /// Second click of a double click: cancels the pause of the first click, without a "Play" icon
    /// (the user only wanted full screen).
    func undoClickPause() {
        splashTask?.cancel()
        showCenterSplash = false
        engine?.togglePause()
    }

    /// Jump lengths (settings), updated when the player opens.
    var skipBackSeconds: UInt32 = 10
    var skipForwardSeconds: UInt32 = 10

    func skipBack() { seek(relative: -Double(skipBackSeconds)) }
    func skipForward() { seek(relative: Double(skipForwardSeconds)) }

    func seek(relative seconds: Double) {
        let icon = AppSettings.skipIcon(forward: seconds > 0, seconds: UInt32(abs(seconds)))
        triggerCenterSplash(icon: icon)
        engine?.seek(relative: seconds)
    }

    /// Target of a jump in progress (see `update`).
    @ObservationIgnored private var pendingSeekDeadline = Date.distantPast
    private(set) var pendingSeekTarget: Double?

    func seek(absolute seconds: Double) {
        let target = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        pendingSeekTarget = target
        pendingSeekDeadline = Date().addingTimeInterval(4)
        currentTime = target
        engine?.seek(absolute: target)
    }

    /// Displayed time: the position during a drag, otherwise the playback position.
    var displayedTime: Double {
        isScrubbing ? scrubTime : currentTime
    }

    /// Fraction played (0…1) for the seek bar.
    var displayedFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(displayedTime / duration, 0), 1)
    }

    /// Fraction already loaded (playback + read-ahead cache), shown faintly behind the progress.
    var bufferedFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max((currentTime + cacheDuration) / duration, 0), 1)
    }

    func toggleMute() {
        engine?.toggleMute()
    }

    func adjustVolume(by delta: Double) {
        let newVol = min(max(volume + delta, 0), 100)
        volume = newVol
    }

    /// Series of the current episode: the chosen tracks are remembered for it and reapplied to the next episode.
    @ObservationIgnored var trackMemorySeriesId: String?
    @ObservationIgnored fileprivate(set) var appliedTrackMemory = false

    /// Once the tracks are known, applies those chosen for the series during a previous episode.
    private func applyTrackMemoryIfNeeded() {
        guard !appliedTrackMemory, let seriesId = trackMemorySeriesId, !audioTracks.isEmpty || !subtitleTracks.isEmpty
        else { return }
        appliedTrackMemory = true
        guard let preference = TrackMemory.load(seriesId: seriesId) else { return }
        if let audio = TrackMemory.audioChoice(audioTracks, preference: preference), audio != selectedAudioId {
            applyAudio(id: audio)
        }
        if let subtitle = TrackMemory.subtitleChoice(subtitleTracks, preference: preference), subtitle != selectedSubtitleId {
            applySubtitle(id: subtitle)
        }
    }

    /// Tracks chosen on the detail page: they take precedence over those remembered for the series. Each part is
    /// applied only once, as soon as a matching track exists (external subtitles arrive a little later).
    @ObservationIgnored var initialTrackChoice: TrackPreference?

    private func applyInitialTrackChoiceIfNeeded() {
        guard var choice = initialTrackChoice, !audioTracks.isEmpty else { return }
        var applied = false
        if choice.audioLanguage != nil {
            if let audio = TrackMemory.audioChoice(audioTracks, preference: choice), audio != selectedAudioId {
                applyAudio(id: audio)
                applied = true
            }
            choice.audioLanguage = nil
        }
        if choice.subtitlesOff {
            if selectedSubtitleId != nil { applySubtitle(id: nil) }
            choice.subtitlesOff = false
            applied = true
        } else if choice.subtitleLanguage != nil, let subtitle = TrackMemory.subtitleChoice(subtitleTracks, preference: choice) {
            if subtitle != selectedSubtitleId { applySubtitle(id: subtitle) }
            choice.subtitleLanguage = nil
            applied = true
        }
        // Nothing else to apply: we stop looking. Otherwise we try again (subtitles not arrived yet).
        initialTrackChoice = choice.audioLanguage == nil && choice.subtitleLanguage == nil && !choice.subtitlesOff ? nil : choice
        if applied { rememberTracks() }
    }

    private func rememberTracks() {
        guard let seriesId = trackMemorySeriesId else { return }
        let preference = TrackMemory.preference(
            audio: audioTracks.first { $0.id == selectedAudioId },
            subtitle: subtitleTracks.first { $0.id == selectedSubtitleId }
        )
        TrackMemory.save(preference, seriesId: seriesId)
    }

    /// The user's choice: applied and remembered for the series.
    func selectAudio(id: Int) {
        initialTrackChoice?.audioLanguage = nil
        applyAudio(id: id)
        rememberTracks()
    }

    func selectSubtitle(id: Int?) {
        initialTrackChoice?.subtitleLanguage = nil
        initialTrackChoice?.subtitlesOff = false
        applySubtitle(id: id)
        rememberTracks()
    }

    private func applyAudio(id: Int) {
        selectedAudioId = id
        audioTracks = audioTracks.map { track in
            var updated = track
            updated.isSelected = track.id == id
            return updated
        }
        engine?.selectAudio(id: id)
    }

    private func applySubtitle(id: Int?) {
        selectedSubtitleId = id
        subtitleTracks = subtitleTracks.map { track in
            var updated = track
            updated.isSelected = track.id == id
            return updated
        }
        engine?.selectSubtitle(id: id)
    }

    func setSpeed(_ speed: Double) {
        playbackSpeed = speed
        engine?.setSpeed(speed)
    }

    /// [ and ] keys: one speed down or up.
    func stepSpeed(faster: Bool) {
        setSpeed(PlaybackSpeeds.step(from: playbackSpeed, faster: faster))
    }

    /// Episodes around the current one, for the N and P keys (nil: none). Not observed: only read on a key press.
    @ObservationIgnored var playNextEpisode: (() -> Void)?
    @ObservationIgnored var playPreviousEpisode: (() -> Void)?

    /// Subtitle track turned off by the C key: turned on again by the next press.
    @ObservationIgnored private(set) var lastSubtitleId: Int?

    /// C key: turns the subtitles off, or back on (the last track used, otherwise the preferred language).
    func toggleSubtitles() {
        if let current = selectedSubtitleId {
            lastSubtitleId = current
            selectSubtitle(id: nil)
        } else if let id = SubtitleToggle.trackToTurnOn(lastUsed: lastSubtitleId, groups: subtitleGroups) {
            selectSubtitle(id: id)
        }
    }

    func setAspectRatio(_ ratio: String) {
        currentAspectRatio = ratio
        if isZoomed {
            isZoomed = false
            engine?.setPanScan(0)
        }
        engine?.setAspectRatio(ratio)
    }

    func toggleZoom() {
        isZoomed.toggle()
        engine?.setPanScan(isZoomed ? 1.0 : 0.0)
    }

    func jumpToChapter(_ index: Int) {
        engine?.jumpToChapter(index)
    }

    func setSubtitlePosition(_ percent: Double) {
        engine?.setSubtitlePosition(percent)
    }

    /// Subtitle delay in seconds (positive: later), for a file whose subtitles are out of sync. This video only.
    private(set) var subtitleDelay: Double = 0

    func adjustSubtitleDelay(by seconds: Double) {
        setSubtitleDelay(subtitleDelay + seconds)
    }

    func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = SubtitleStyle.clampedDelay(seconds)
        engine?.setProperty("sub-delay", to: String(format: "%.2f", subtitleDelay))
    }

    /// Size, colour and background chosen in the player: applied at once, the same way as at the start.
    func applySubtitleStyle(_ settings: AppSettings) {
        for (name, value) in SubtitleStyle.liveOptions(settings: settings) {
            engine?.setProperty(name, to: value)
        }
    }

    private var splashTask: Task<Void, Never>?
    /// Changes on every action: the centre icon is a new view (clean fade, no blending with the old one).
    private(set) var splashId = 0

    /// New item loaded in the same player (next episode): we clear what concerned the old one.
    func resetForNewItem() {
        currentTime = 0
        duration = 0
        audioTracks = []
        subtitleTracks = []
        chapters = []
        selectedAudioId = nil
        selectedSubtitleId = nil
        lastSubtitleId = nil
        pendingSeekTarget = nil
        appliedTrackMemory = false
        initialTrackChoice = nil
        videoCodec = ""
        audioCodec = ""
        videoResolution = ""
        showInfoSheet = false
        // mpv keeps the delay from one file to the next: the next episode starts in sync.
        if subtitleDelay != 0 { setSubtitleDelay(0) }
    }

    /// Centre icon (play, pause, jump): animated appearance; a second quick press starts again from zero
    /// instead of being hidden too early by the first.
    private func triggerCenterSplash(icon: String) {
        splashTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            centerSplashIcon = icon
            splashId &+= 1
            showCenterSplash = true
        }
        splashTask = Task {
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { showCenterSplash = false }
        }
    }
}
