import XCTest
@testable import Playfin

final class PlayerLogicTests: XCTestCase {
    // MARK: Touches

    func testKeyCodesMapToActions() {
        XCTAssertEqual(PlayerKeyAction.from(keyCode: 49), .togglePause)
        XCTAssertEqual(PlayerKeyAction.from(keyCode: 123), .skipBack)
        XCTAssertEqual(PlayerKeyAction.from(keyCode: 124), .skipForward)
        XCTAssertEqual(PlayerKeyAction.from(keyCode: 126), .volumeUp)
        XCTAssertEqual(PlayerKeyAction.from(keyCode: 125), .volumeDown)
        XCTAssertEqual(PlayerKeyAction.from(keyCode: 53), .escape)
        XCTAssertEqual(PlayerKeyAction.from(keyCode: 3), .toggleFullScreen)
        XCTAssertEqual(PlayerKeyAction.from(keyCode: 46), .toggleMute)
        XCTAssertNil(PlayerKeyAction.from(keyCode: 0))
    }

    func testKeysAreIgnoredOutsideThePlayerWindowOrWhileTyping() {
        XCTAssertTrue(PlayerKeyAction.shouldHandle(eventWindowIsPlayerWindow: true, isTypingText: false))
        XCTAssertFalse(PlayerKeyAction.shouldHandle(eventWindowIsPlayerWindow: false, isTypingText: false), "Settings window")
        XCTAssertFalse(PlayerKeyAction.shouldHandle(eventWindowIsPlayerWindow: true, isTypingText: true), "text field")
    }

    // MARK: Sous-titres

    func testSubtitlesStayAtTheBottomWhenControlsAreHidden() {
        XCTAssertEqual(SubtitleLayout.position(barHeight: 150, playerHeight: 800, controlsVisible: false), 100)
        XCTAssertEqual(SubtitleLayout.position(barHeight: 0, playerHeight: 800, controlsVisible: true), 100, "bar not measured yet")
        XCTAssertEqual(SubtitleLayout.position(barHeight: 150, playerHeight: 0, controlsVisible: true), 100)
    }

    func testSubtitlesMoveUpAboveTheControlsButNotTooFar() {
        // (150 + 16) / 800 = 20,75 % → 79,25
        XCTAssertEqual(SubtitleLayout.position(barHeight: 150, playerHeight: 800, controlsVisible: true), 79.25, accuracy: 0.01)
        // Small window: the bar takes almost everything, but the subtitles do not go above 60.
        XCTAssertEqual(SubtitleLayout.position(barHeight: 300, playerHeight: 400, controlsVisible: true), 60)
    }

    // MARK: End of playback and controls

    func testOnlyARealEndOfFileTriggersTheNextEpisode() {
        XCTAssertTrue(PlaybackEnd.isGenuineEnd(eofReached: true, position: 2399, duration: 2400))
        XCTAssertFalse(PlaybackEnd.isGenuineEnd(eofReached: true, position: 600, duration: 2400), "network drop in the middle")
        XCTAssertFalse(PlaybackEnd.isGenuineEnd(eofReached: false, position: 2400, duration: 2400))
        XCTAssertFalse(PlaybackEnd.isGenuineEnd(eofReached: true, position: 0, duration: 0), "unknown duration")
    }

    func testControlsOnlyHideWhenNothingKeepsThemOpen() {
        XCTAssertTrue(ControlsVisibility.canHide(isPaused: false, infoSheetOpen: false, overlayHovered: false, scrubbing: false))
        XCTAssertFalse(ControlsVisibility.canHide(isPaused: true, infoSheetOpen: false, overlayHovered: false, scrubbing: false))
        XCTAssertFalse(ControlsVisibility.canHide(isPaused: false, infoSheetOpen: true, overlayHovered: false, scrubbing: false))
        XCTAssertFalse(ControlsVisibility.canHide(isPaused: false, infoSheetOpen: false, overlayHovered: true, scrubbing: false))
        XCTAssertFalse(ControlsVisibility.canHide(isPaused: false, infoSheetOpen: false, overlayHovered: false, scrubbing: true))
        XCTAssertFalse(ControlsVisibility.canHide(isPaused: false, infoSheetOpen: false, overlayHovered: false, scrubbing: false, menuOpen: true))
    }

    func testPlaybackSpeedText() {
        XCTAssertEqual(formatPlaybackSpeed(1), "1×")
        XCTAssertEqual(formatPlaybackSpeed(1.25), "1.25×")
        XCTAssertEqual(formatPlaybackSpeed(0.5), "0.5×")
        XCTAssertEqual(formatPlaybackSpeed(2), "2×")
    }

    func testControlsHideAfterThreeSecondsAsInTheBrief() {
        XCTAssertEqual(Theme.Motion.controlsHideDelay, .seconds(3))
    }

    // MARK: Tracks by language

    private func track(
        _ id: Int, _ type: String = "sub", lang: String?, title: String = "", selected: Bool = false,
        forced: Bool = false, sdh: Bool = false, isDefault: Bool = false, codec: String? = nil, channels: Int? = nil
    ) -> TrackItem {
        TrackItem(
            id: id, type: type, title: title, language: lang, isSelected: selected, codec: codec, channels: channels,
            isForced: forced, isDefault: isDefault, isHearingImpaired: sdh
        )
    }

    func testLanguageCodesAreNormalised() {
        for raw in ["fre", "fra", "fr", "fr-CA", "FR"] { XCTAssertEqual(TrackGrouping.languageCode(raw), "fr", raw) }
        XCTAssertEqual(TrackGrouping.languageCode("ger"), "de")
        XCTAssertEqual(TrackGrouping.languageCode("eng"), "en")
        XCTAssertEqual(TrackGrouping.languageCode("jpn"), "ja")
        for raw in ["und", "", "  ", "zxx"] { XCTAssertNil(TrackGrouping.languageCode(raw), raw) }
        XCTAssertNil(TrackGrouping.languageCode(nil))
    }

    func testTrackKindsComeFromFlagsAndTitles() {
        XCTAssertEqual(TrackGrouping.kind(of: track(1, lang: "en", forced: true)), .forced)
        XCTAssertEqual(TrackGrouping.kind(of: track(1, lang: "en", title: "English SDH")), .sdh)
        XCTAssertEqual(TrackGrouping.kind(of: track(1, lang: "en", sdh: true)), .sdh)
        XCTAssertEqual(TrackGrouping.kind(of: track(1, lang: "en", title: "Director's commentary")), .commentary)
        XCTAssertEqual(TrackGrouping.kind(of: track(1, "audio", lang: "fr", title: "Audiodescription")), .audioDescription)
        XCTAssertEqual(TrackGrouping.kind(of: track(1, lang: "en", title: "Accent marks")), .main, "\"cc\" inside a word is not SDH")
        XCTAssertEqual(TrackGrouping.kind(of: track(1, lang: "en")), .main)
    }

    func testGroupsPutPreferredLanguagesFirstAndUnknownLast() {
        let fr = Locale(identifier: "en_US")
        let tracks = [
            track(1, lang: "eng"), track(2, lang: nil), track(3, lang: "fre"), track(4, lang: "spa"), track(5, lang: "ger")
        ]
        let groups = TrackGrouping.groups(tracks, preferred: ["fr", "en"], locale: fr)
        XCTAssertEqual(groups.map(\.id), ["fr", "en", "de", "es", "und"])
        XCTAssertEqual(groups.map(\.name), ["French", "English", "German", "Spanish", "Unknown language"])
    }

    func testChoicesInsideALanguageAreOrderedAndKeepTheSelection() {
        let fr = Locale(identifier: "en_US")
        let tracks = [
            track(10, lang: "eng", title: "Commentary", codec: "subrip"),
            track(11, lang: "eng", forced: true, codec: "hdmv_pgs_subtitle"),
            track(12, lang: "eng", selected: true, sdh: true),
            track(13, lang: "eng", isDefault: true)
        ]
        let group = TrackGrouping.groups(tracks, preferred: [], locale: fr)[0]
        XCTAssertEqual(group.choices.map(\.id), [13, 12, 11, 10], "Full, SDH, Forced, Commentary")
        XCTAssertEqual(group.choices.map(\.label), ["Full", "Deaf and hard of hearing", "Forced", "Commentary"])
        XCTAssertEqual(group.choices.filter(\.isSelected).map(\.id), [12])
        XCTAssertEqual(group.choices.first { $0.id == 11 }?.detail, "HDMV_PGS_SUBTITLE")
    }

    func testAudioDetailShowsCodecAndChannelLayout() {
        let fr = Locale(identifier: "en_US")
        let group = TrackGrouping.groups([track(1, "audio", lang: "fre", codec: "eac3", channels: 6)], preferred: [], locale: fr)[0]
        XCTAssertEqual(group.choices[0].label, "Main")
        XCTAssertEqual(group.choices[0].detail, "EAC3 · 5.1")
    }

    func testButtonSummaryAndPreferredLanguageOrder() {
        let fr = Locale(identifier: "en_US")
        let groups = TrackGrouping.groups(
            [track(1, lang: "fre", selected: true), track(2, lang: "fre", forced: true), track(3, lang: "eng")],
            preferred: ["fr"], locale: fr
        )
        XCTAssertEqual(TrackGrouping.activeSummary(groups), "French · Full")
        XCTAssertEqual(TrackGrouping.activeSummary(TrackGrouping.groups([track(3, lang: "eng")], preferred: [], locale: fr)), nil)
        XCTAssertEqual(TrackGrouping.preferredLanguages(setting: "ja", system: ["fr", "ja", "en"]), ["ja", "fr", "en"])
        XCTAssertEqual(TrackGrouping.preferredLanguages(setting: "", system: ["fr"]), ["fr"])
    }

    func testOnlyOneTrackGivesASingleChoiceGroup() {
        let groups = TrackGrouping.groups([track(1, lang: "spa")], preferred: [], locale: Locale(identifier: "fr_FR"))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].choices.count, 1)
    }
}

final class VideoClickTests: XCTestCase {
    func testADoubleClickTogglesThePauseTwiceSoPlaybackContinues() {
        // Click 1 pauses at once, click 2 undoes it and goes full screen: 2 toggles in all (not 3).
        let toggles = [1, 2].map(VideoClick.action(forClickCount:)).filter { $0 != .ignore }.count
        XCTAssertEqual(toggles, 2)
        XCTAssertEqual(VideoClick.action(forClickCount: 1), .togglePause)
        XCTAssertEqual(VideoClick.action(forClickCount: 2), .undoPauseAndToggleFullScreen)
        XCTAssertEqual(VideoClick.action(forClickCount: 3), .ignore, "a triple click changes nothing more")
    }

    func testTwoClicksFarApartAreTwoSingleClicks() {
        XCTAssertEqual(VideoClick.clickCount(after: 1, interval: 0.2), 2, "quick second click: double click")
        XCTAssertEqual(VideoClick.clickCount(after: 1, interval: 0.45), 1, "within the macOS 0.5 s, but too slow here")
        XCTAssertEqual(VideoClick.clickCount(after: 0, interval: .infinity), 1, "first click")
        XCTAssertEqual(VideoClick.clickCount(after: 2, interval: 0.1), 3)
    }
}

final class SegmentSkipTests: XCTestCase {
    private let segments = [
        MediaSegment(kind: "Intro", startTicks: 600_000_000, endTicks: 1_500_000_000),      // 60 s → 150 s
        MediaSegment(kind: "Outro", startTicks: 20_000_000_000, endTicks: 21_000_000_000),  // 2000 s → 2100 s
        MediaSegment(kind: "Commercial", startTicks: 3_000_000_000, endTicks: 3_300_000_000)
    ]

    func testIntroIsOfferedDuringTheIntroOnly() {
        XCTAssertNil(SegmentSkip.offer(at: 10, in: segments))
        XCTAssertEqual(SegmentSkip.offer(at: 60, in: segments), .init(title: "Skip intro", targetSeconds: 150))
        XCTAssertEqual(SegmentSkip.offer(at: 120, in: segments)?.targetSeconds, 150)
        XCTAssertNil(SegmentSkip.offer(at: 149.5, in: segments), "nothing left to skip at the very end")
        XCTAssertNil(SegmentSkip.offer(at: 300, in: segments))
    }

    func testOutroAndUnknownSegments() {
        XCTAssertEqual(SegmentSkip.offer(at: 2010, in: segments)?.title, "Skip credits")
        XCTAssertNil(SegmentSkip.offer(at: 305, in: segments), "a \"Commercial\" segment is not offered")
        XCTAssertNil(SegmentSkip.offer(at: 100, in: []))
    }

    func testVolumeIsKeptInSettingsAndClamped() throws {
        var settings = defaultSettings()
        XCTAssertEqual(settings.playerVolume, 100)
        settings.playerVolume = 400
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-vol-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try SettingsStore(dir: dir.path).save(settings: settings).playerVolume, 100)
    }
}

@MainActor
final class PlayerControllerSeekTests: XCTestCase {
    private func update(_ controller: PlayerController, position: Double) {
        controller.update(
            position: position, duration: 1000, isPaused: false, volume: 100, isMuted: false, speed: 1,
            audioTracks: [], subtitleTracks: [], selectedAudioId: nil, selectedSubtitleId: nil
        )
    }

    func testTheSeekTargetStaysDisplayedUntilMpvReachesIt() {
        let controller = PlayerController()
        update(controller, position: 100)
        controller.seek(absolute: 600)
        XCTAssertEqual(controller.displayedTime, 600, "the bar jumps to the target at once")

        update(controller, position: 101) // mpv has not jumped yet: no visual step back
        XCTAssertEqual(controller.displayedTime, 600)

        update(controller, position: 600.4)
        XCTAssertEqual(controller.displayedTime, 600.4, accuracy: 0.001)
        XCTAssertNil(controller.pendingSeekTarget)

        update(controller, position: 601)
        XCTAssertEqual(controller.displayedTime, 601)
    }

    func testSeekIsClampedAndFractionsStayInRange() {
        let controller = PlayerController()
        update(controller, position: 10)
        controller.seek(absolute: 5000)
        XCTAssertEqual(controller.displayedTime, 1000)
        XCTAssertEqual(controller.displayedFraction, 1)
        controller.seek(absolute: -5)
        XCTAssertEqual(controller.displayedFraction, 0)
    }

    func testScrubbingShowsTheDraggedTime() {
        let controller = PlayerController()
        update(controller, position: 10)
        controller.isScrubbing = true
        controller.scrubTime = 250
        XCTAssertEqual(controller.displayedTime, 250)
        update(controller, position: 11)
        XCTAssertEqual(controller.displayedTime, 250, "playback does not move the cursor held by the user")
    }
}

final class ShelfWheelTests: XCTestCase {
    func testMouseWheelScrollsShelvesSideways() {
        XCTAssertEqual(ShelfWheel.horizontalDelta(deltaX: 0, deltaY: -1, isPrecise: false), 60, "wheel down: to the right")
        XCTAssertEqual(ShelfWheel.horizontalDelta(deltaX: 0, deltaY: 2, isPrecise: false), -120)
    }

    func testTrackpadAndHorizontalGesturesKeepTheirNativeBehaviour() {
        XCTAssertNil(ShelfWheel.horizontalDelta(deltaX: 0, deltaY: -5, isPrecise: true), "trackpad")
        XCTAssertNil(ShelfWheel.horizontalDelta(deltaX: 3, deltaY: 1, isPrecise: false), "geste horizontal")
        XCTAssertNil(ShelfWheel.horizontalDelta(deltaX: 0, deltaY: 0, isPrecise: false))
    }
}

final class TrackMemoryTests: XCTestCase {
    private func track(_ id: Int, _ type: String, _ lang: String, title: String = "", forced: Bool = false) -> TrackItem {
        TrackItem(id: id, type: type, title: title, language: lang, isSelected: false, isForced: forced)
    }

    func testTheSameLanguageAndKindAreChosenForTheNextEpisode() {
        let audio = [track(1, "audio", "fre"), track(2, "audio", "jpn"), track(3, "audio", "jpn", title: "Commentary")]
        let subs = [track(4, "sub", "fre", forced: true), track(5, "sub", "fre"), track(6, "sub", "eng")]
        let pref = TrackMemory.preference(audio: audio[1], subtitle: subs[1])
        XCTAssertEqual(pref.audioLanguage, "ja")
        XCTAssertEqual(pref.subtitleLanguage, "fr")

        // Next episode: other identifiers, same languages.
        let nextAudio = [track(10, "audio", "jpn", title: "Commentary"), track(11, "audio", "jpn"), track(12, "audio", "fre")]
        let nextSubs = [track(13, "sub", "fre"), track(14, "sub", "fre", forced: true)]
        XCTAssertEqual(TrackMemory.audioChoice(nextAudio, preference: pref), 11, "main Japanese track, not the commentary")
        XCTAssertEqual(TrackMemory.subtitleChoice(nextSubs, preference: pref), .some(13), "full, not forced")
    }

    func testSubtitlesOffAndUnknownLanguagesAreRespected() {
        let off = TrackMemory.preference(audio: nil, subtitle: nil)
        XCTAssertTrue(off.subtitlesOff)
        XCTAssertEqual(TrackMemory.subtitleChoice([track(1, "sub", "eng")], preference: off), .some(nil))
        let german = TrackPreference(audioLanguage: "de", subtitleLanguage: "de", subtitleKind: 0)
        XCTAssertNil(TrackMemory.audioChoice([track(1, "audio", "eng")], preference: german))
        XCTAssertNil(TrackMemory.subtitleChoice([track(1, "sub", "eng")], preference: german), "language absent: nothing changes")
    }

    func testPreferencesAreStoredPerSeries() {
        let defaults = UserDefaults(suiteName: "jn-tracks-\(UUID().uuidString)")!
        TrackMemory.save(TrackPreference(audioLanguage: "fr"), seriesId: "s1", defaults: defaults)
        XCTAssertEqual(TrackMemory.load(seriesId: "s1", defaults: defaults)?.audioLanguage, "fr")
        XCTAssertNil(TrackMemory.load(seriesId: "s2", defaults: defaults))
    }
}

final class AcknowledgementsTests: XCTestCase {
    func testTheAcknowledgementsAreBundledAndListMpvAndFFmpeg() throws {
        let list = try XCTUnwrap(Acknowledgements.load(bundle: Bundle(for: AppModel.self)))
        XCTAssertTrue(list.native.contains { $0.name == "mpv" && $0.license.hasPrefix("LGPL") })
        XCTAssertTrue(list.native.contains { $0.name == "FFmpeg" && $0.license.hasPrefix("LGPL") })
        XCTAssertFalse(list.native.contains { $0.license.hasPrefix("GPL") }, "no standalone GPL component")
        XCTAssertGreaterThan(list.rust.count, 50)
    }
}

final class MediaInfoTextTests: XCTestCase {
    private func stream(_ lang: String?) -> StreamInfo {
        StreamInfo(codec: "aac", language: lang, channels: 2, isDefault: false, isExternal: false, title: nil)
    }

    func testLanguagesAreDistinctNamedInEnglishAndLimited() {
        let fr = Locale(identifier: "en_US")
        XCTAssertEqual(MediaInfoText.languages([stream("fre"), stream("eng"), stream("fra")], locale: fr), "French, English")
        XCTAssertEqual(
            MediaInfoText.languages(["fre", "eng", "ger", "spa", "ita", "jpn"].map(stream), locale: fr, limit: 4),
            "French, English, German, Spanish (+2)"
        )
        XCTAssertEqual(MediaInfoText.languages([stream(nil)], locale: fr), "Unknown language")
        XCTAssertNil(MediaInfoText.languages([], locale: fr))
    }

    func testOnlyHdrIsShownAsQuality() {
        let base = MediaInfo(container: "mkv", videoCodec: "hevc", width: 3840, height: 2160, videoRange: "SDR", audio: [], subtitles: [])
        XCTAssertNil(MediaInfoText.quality(base))
        var hdr = base
        hdr.videoRange = "DOVI"
        XCTAssertEqual(MediaInfoText.quality(hdr), "Dolby Vision")
        hdr.videoRange = "DOVIWithHDR10"
        XCTAssertEqual(MediaInfoText.quality(hdr), "Dolby Vision", "not the raw server value")
    }

    func testTheSoundIsNamedLikeOnTheBox() {
        let atmos = StreamInfo(codec: "truehd", language: "eng", channels: 8, isDefault: true, isExternal: false,
                               title: nil, profile: "Dolby TrueHD + Dolby Atmos", channelLayout: "7.1")
        let stereo = StreamInfo(codec: "aac", language: "fre", channels: 2, isDefault: false, isExternal: false, title: nil)
        let info = MediaInfo(container: "mkv", videoCodec: "hevc", width: 3840, height: 2160, videoRange: "HDR10",
                             audio: [stereo, atmos], subtitles: [])
        XCTAssertEqual(MediaInfoText.mainAudio(info), "Dolby Atmos · 7.1", "the default track")
        XCTAssertEqual(MediaInfoText.audioFormats(info), "AAC · Stereo, Dolby Atmos · 7.1")
    }

    func testHDRIsShownOnlyWhereTheDisplayCan() {
        XCTAssertTrue(HDROutput.isHDR(mode: "auto", transfer: "pq", headroom: 16))
        XCTAssertTrue(HDROutput.isHDR(mode: "auto", transfer: "hlg", headroom: 2))
        XCTAssertFalse(HDROutput.isHDR(mode: "auto", transfer: "pq", headroom: 1), "SDR display: converted")
        XCTAssertFalse(HDROutput.isHDR(mode: "off", transfer: "pq", headroom: 16), "turned off in Settings")
        XCTAssertFalse(HDROutput.isHDR(mode: "auto", transfer: "bt.1886", headroom: 16), "SDR video stays SDR")
        XCTAssertEqual(HDROutput.peakNits(headroom: 16), 1600)
        XCTAssertEqual(HDROutput.peakNits(headroom: 1.2), 203, "never below the HDR reference white")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: HDROutput.mpvOptions(hdr: true, headroom: 16))["target-trc"], "pq")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: HDROutput.mpvOptions(hdr: false, headroom: 16))["target-trc"], "auto")
        XCTAssertEqual(HDROutput.summary(transfer: "pq", hdr: false), "HDR (PQ), converted to SDR")
    }

    func testSDRWithFloatingPointPixelsIsNeverLeftWithoutAColourSpace() {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)
        // Unlabelled floating-point pixels are read as linear light: SDR videos looked washed out.
        XCTAssertTrue(HDROutput.layerColorSpace(hdr: false, floatingPoint: true, display: p3) === p3, "the display's own")
        XCTAssertEqual(HDROutput.layerColorSpace(hdr: false, floatingPoint: true, display: nil)?.name, CGColorSpace.sRGB)
        XCTAssertNil(HDROutput.layerColorSpace(hdr: false, floatingPoint: false, display: p3), "8-bit: as before")
        XCTAssertEqual(HDROutput.layerColorSpace(hdr: true, floatingPoint: true, display: p3)?.name, CGColorSpace.itur_2100_PQ)
    }
}

@MainActor
final class DetailTrackChoiceTests: XCTestCase {
    private func track(_ id: Int, _ type: String, _ lang: String, title: String = "", selected: Bool = false) -> TrackItem {
        TrackItem(id: id, type: type, title: title, language: lang, isSelected: selected)
    }

    private final class RecordingEngine: PlayerEngine {
        var calls: [String] = []
        func togglePause() {}
        func seek(relative seconds: Double) {}
        func seek(absolute seconds: Double) {}
        func setVolume(_ volume: Double) {}
        func toggleMute() {}
        func setSpeed(_ speed: Double) {}
        func selectAudio(id: Int) { calls.append("audio \(id)") }
        func selectSubtitle(id: Int?) { calls.append("sub \(String(describing: id))") }
        func setAspectRatio(_ ratio: String) {}
        func setPanScan(_ value: Double) {}
        func jumpToChapter(_ index: Int) {}
        func setSubtitlePosition(_ percent: Double) {}
        func setProperty(_ name: String, to value: String) { calls.append("\(name)=\(value)") }
        func setRenderingSuspended(_ suspended: Bool) {}
        var hostWindow: NSWindow? { nil }
    }

    private func update(_ controller: PlayerController, audio: [TrackItem], subs: [TrackItem]) {
        controller.update(
            position: 0, duration: 1000, isPaused: false, volume: 100, isMuted: false, speed: 1,
            audioTracks: audio, subtitleTracks: subs,
            selectedAudioId: audio.first(where: \.isSelected)?.id, selectedSubtitleId: subs.first(where: \.isSelected)?.id
        )
    }

    func testNothingChosenMeansTheAutomaticChoice() {
        XCTAssertNil(DetailTrackSelection().forPlayback)
    }

    func testChosenTracksBecomeAPreference() {
        var selection = DetailTrackSelection()
        selection.chooseAudio(track(2, "audio", "jpn"))
        XCTAssertEqual(selection.forPlayback?.audioLanguage, "ja")
        XCTAssertEqual(selection.forPlayback?.subtitlesOff, false, "subtitles untouched: the player decides")

        selection.disableSubtitles()
        XCTAssertEqual(selection.forPlayback?.subtitlesOff, true)

        selection.chooseSubtitle(track(3, "sub", "fre"))
        XCTAssertEqual(selection.forPlayback?.subtitleLanguage, "fr")
        XCTAssertEqual(selection.forPlayback?.subtitlesOff, false)
    }

    func testAChosenCommentaryTrackIsNotReplacedByTheMainOne() {
        let audio = [track(1, "audio", "eng"), track(2, "audio", "eng", title: "Commentary")]
        var selection = DetailTrackSelection()
        selection.chooseAudio(audio[1])
        XCTAssertEqual(selection.forPlayback.flatMap { TrackMemory.audioChoice(audio, preference: $0) }, 2)
    }

    func testThePlayerAppliesTheChoiceOnceTheTracksExist() {
        let engine = RecordingEngine()
        let controller = PlayerController()
        controller.engine = engine
        controller.initialTrackChoice = TrackPreference(audioLanguage: "fr", subtitlesOff: true)

        update(controller, audio: [track(1, "audio", "eng", selected: true), track(2, "audio", "fre")],
               subs: [track(5, "sub", "eng", selected: true)])
        XCTAssertEqual(engine.calls, ["audio 2", "sub nil"])

        update(controller, audio: [track(1, "audio", "eng"), track(2, "audio", "fre", selected: true)], subs: [])
        XCTAssertEqual(engine.calls.count, 2, "the choice is applied only once")
    }

    func testASubtitleThatArrivesLaterIsStillApplied() {
        let engine = RecordingEngine()
        let controller = PlayerController()
        controller.engine = engine
        controller.initialTrackChoice = TrackPreference(subtitleLanguage: "fr", subtitleKind: 0)

        let audio = [track(1, "audio", "eng", selected: true)]
        update(controller, audio: audio, subs: [track(5, "sub", "eng")])
        XCTAssertEqual(engine.calls, [], "no French subtitles yet")

        update(controller, audio: audio, subs: [track(5, "sub", "eng"), track(6, "sub", "fre")])
        XCTAssertEqual(engine.calls, ["sub Optional(6)"])
    }

    func testAManualChoiceCancelsThePendingOne() {
        let engine = RecordingEngine()
        let controller = PlayerController()
        controller.engine = engine
        controller.initialTrackChoice = TrackPreference(subtitleLanguage: "fr", subtitleKind: 0)
        let audio = [track(1, "audio", "eng", selected: true)]
        update(controller, audio: audio, subs: [track(5, "sub", "eng")])

        controller.selectSubtitle(id: nil)
        update(controller, audio: audio, subs: [track(5, "sub", "eng"), track(6, "sub", "fre")])
        XCTAssertEqual(engine.calls, ["sub nil"], "the user turned the subtitles off: we no longer touch them")
    }
}

@MainActor
final class PlayerWindowTests: AppTestCase {
    private func hostWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 140, width: 1100, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func testThePlayerOpensOverTheMainWindowAndClosesWithIt() throws {
        try skipOnCI("the runner's screen is too small for the window frames")
        let model = AppModel()
        let host = hostWindow()
        let controller = PlayerWindowController()
        controller.hostWindow = host

        controller.show(model: model)
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.frame, host.frame, "exactly over the main window")
        XCTAssertFalse(window.isRestorable, "never reopened at the next launch")
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, true, "no window buttons over the video")
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isHidden, true)
        XCTAssertTrue(window.styleMask.contains(.closable), "⌘W still closes the player")

        controller.show(model: model)
        XCTAssertTrue(controller.window === window, "next episode: the same window")

        controller.close()
        XCTAssertNil(controller.window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4)) // fade out
        XCTAssertFalse(window.isVisible)
        host.close()
    }

    func testCloseFadesOutBeforeStoppingThePlayback() throws {
        let model = AppModel()
        let controller = PlayerWindowController()
        model.playback = Playback(movie: makeItem(id: "m", type: "Movie"), url: "/nonexistent.mkv",
                                  httpHeader: "", startSeconds: 0, subtitles: [])
        controller.show(model: model)
        let window = try XCTUnwrap(controller.window)

        controller.dismiss()
        XCTAssertNotNil(model.playback, "the picture stays while the window fades")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNil(model.playback, "then the playback stops")
        XCTAssertEqual(window.alphaValue, 0)
        controller.close()
        XCTAssertNil(controller.window)
        XCTAssertFalse(window.isVisible, "already faded: closed at once")
    }

    func testTheMinimumSizeSurvivesSwiftUILayout() throws {
        let model = AppModel()
        let controller = PlayerWindowController()
        model.playback = Playback(movie: makeItem(id: "m", type: "Movie"), url: "/nonexistent.mkv",
                                  httpHeader: "", startSeconds: 0, subtitles: [])
        controller.show(model: model)
        let window = try XCTUnwrap(controller.window)
        // The hosting resets `contentMinSize` to zero after its first layout: the delegate keeps the minimum.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let proposed = controller.windowWillResize(window, to: NSSize(width: 300, height: 200))
        let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: PlayerWindowController.minimumSize)).size
        XCTAssertEqual(proposed, minimum, "the bottom bar never overlaps")
        XCTAssertEqual(controller.windowWillResize(window, to: NSSize(width: 1400, height: 900)), NSSize(width: 1400, height: 900))
        model.playback = nil
        controller.close()
    }

    func testPictureInPictureFloatsSmallAndGivesTheFrameBack() throws {
        try skipOnCI("the runner's screen is too small for the window frames")
        let model = AppModel()
        let host = hostWindow()
        let controller = PlayerWindowController()
        controller.hostWindow = host
        controller.show(model: model)
        let window = try XCTUnwrap(controller.window as? PlayerWindow)

        var saved: NSRect?
        MiniPlayer.enter(window) { saved = $0 }
        XCTAssertEqual(saved, host.frame)
        XCTAssertEqual(window.level, .floating, "above the other windows")
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces), "on every desktop")
        XCTAssertEqual(window.minimumContentSize, MiniPlayer.minimumSize)
        // Fade out, jump, fade in.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertLessThan(window.frame.width, 600)
        XCTAssertEqual(window.alphaValue, 1)

        MiniPlayer.exit(window, to: saved)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.frame, host.frame)
        XCTAssertEqual(window.minimumContentSize, PlayerWindowController.minimumSize)
        controller.close()
        host.close()
    }

    func testClosingTheWindowStopsThePlayback() throws {
        let model = AppModel()
        let controller = PlayerWindowController()
        controller.hostWindow = hostWindow()
        controller.show(model: model)
        let window = try XCTUnwrap(controller.window)
        model.playback = Playback(movie: makeItem(id: "film-1", type: "Movie"), url: "/nonexistent.mkv",
                                  httpHeader: "", startSeconds: 0, subtitles: [])

        // Red button / ⌘W: the delegate is told, the playback stops like with "Close".
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        XCTAssertNil(controller.window)
        XCTAssertNil(model.playback)
        window.close()
    }
}

final class PlayerShortcutsTests: XCTestCase {
    func testEscapeNeverStopsThePlayback() {
        XCTAssertEqual(EscapeAction.resolve(infoSheetOpen: false, subtitleSettingsOpen: false, isFullScreen: true),
                       .leaveFullScreen)
        XCTAssertEqual(EscapeAction.resolve(infoSheetOpen: false, subtitleSettingsOpen: false, isFullScreen: false),
                       .nothing, "in a window: Esc does nothing (\"Close\" or ⌘W stop the playback)")
        XCTAssertEqual(EscapeAction.resolve(infoSheetOpen: true, subtitleSettingsOpen: false, isFullScreen: true),
                       .closeInfoSheet, "an open panel first")
        XCTAssertEqual(EscapeAction.resolve(infoSheetOpen: false, subtitleSettingsOpen: true, isFullScreen: false),
                       .closeSubtitleSettings)
    }

    func testEpisodeSubtitleAndSpeedKeys() {
        XCTAssertEqual(PlayerKeyAction.from(keyCode: 45), .nextEpisode)
        XCTAssertEqual(PlayerKeyAction.from(keyCode: 35), .previousEpisode)
        XCTAssertEqual(PlayerKeyAction.from(keyCode: 8), .toggleSubtitles)
        XCTAssertEqual(PlayerKeyAction.from(keyCode: 33), .slower)
        XCTAssertEqual(PlayerKeyAction.from(keyCode: 30), .faster)
    }

    func testCommandShortcutsAreLeftToTheMenus() {
        XCTAssertFalse(PlayerKeyAction.shouldHandle(eventWindowIsPlayerWindow: true, isTypingText: false, hasCommandModifier: true),
                       "⌘M minimises, it does not mute")
        XCTAssertTrue(PlayerKeyAction.shouldHandle(eventWindowIsPlayerWindow: true, isTypingText: false, hasCommandModifier: false))
    }

    func testSpeedStepsStopAtTheEnds() {
        XCTAssertEqual(PlaybackSpeeds.all.first, 0.5, "0.5× is offered")
        XCTAssertEqual(PlaybackSpeeds.step(from: 1, faster: true), 1.25)
        XCTAssertEqual(PlaybackSpeeds.step(from: 1, faster: false), 0.75)
        XCTAssertEqual(PlaybackSpeeds.step(from: 2, faster: true), 2)
        XCTAssertEqual(PlaybackSpeeds.step(from: 0.5, faster: false), 0.5)
        XCTAssertEqual(PlaybackSpeeds.step(from: 1.1, faster: true), 1.25, "a speed outside the list goes to the next one")
    }

    func testSubtitleToggleTurnsBackOnTheLastTrackOrThePreferredOne() {
        let groups = [
            LanguageGroup(id: "fr", name: "French", choices: [TrackChoice(id: 7, kind: .main, label: "Full", detail: "", isSelected: false)]),
            LanguageGroup(id: "en", name: "English", choices: [TrackChoice(id: 3, kind: .main, label: "Full", detail: "", isSelected: false)])
        ]
        XCTAssertEqual(SubtitleToggle.trackToTurnOn(lastUsed: 3, groups: groups), 3)
        XCTAssertEqual(SubtitleToggle.trackToTurnOn(lastUsed: nil, groups: groups), 7, "first of the preferred language")
        XCTAssertEqual(SubtitleToggle.trackToTurnOn(lastUsed: 99, groups: groups), 7, "a track that no longer exists")
        XCTAssertNil(SubtitleToggle.trackToTurnOn(lastUsed: nil, groups: []))
    }

    func testTrackNamesFollowTheInterfaceLanguage() {
        let groups = TrackGrouping.groups(
            [TrackItem(id: 1, type: "sub", title: "", language: "eng", isSelected: false)], preferred: [])
        XCTAssertEqual(groups.first?.name, "English", "never \"Anglais\" in the English interface, whatever the Mac")
    }

    func testScrubberMarksForChaptersAndSegments() {
        let chapters = [ChapterItem(index: 0, title: "Start", timeSeconds: 0),
                        ChapterItem(index: 1, title: "The camp", timeSeconds: 250),
                        ChapterItem(index: 2, title: "Night", timeSeconds: 750)]
        XCTAssertEqual(ScrubberMarks.chapterFractions(chapters, duration: 1000), [0.25, 0.75])
        XCTAssertEqual(ScrubberMarks.chapterFractions(chapters, duration: 0), [])

        let intro = MediaSegment(kind: "Intro", startTicks: 0, endTicks: Int64(100 * ticksPerSecond))
        let ad = MediaSegment(kind: "Commercial", startTicks: 0, endTicks: Int64(10 * ticksPerSecond))
        let outro = MediaSegment(kind: "Outro", startTicks: Int64(950 * ticksPerSecond), endTicks: Int64(2000 * ticksPerSecond))
        XCTAssertEqual(ScrubberMarks.segmentRanges([intro, ad, outro], duration: 1000), [
            .init(kind: "Intro", start: 0, end: 0.1), .init(kind: "Outro", start: 0.95, end: 1)
        ], "unknown kinds are left out, the end is kept inside the bar")

        XCTAssertEqual(ScrubberMarks.label(at: 50, chapters: chapters, segments: [intro]), "Intro")
        XCTAssertEqual(ScrubberMarks.label(at: 300, chapters: chapters, segments: [intro]), "The camp")
        XCTAssertNil(ScrubberMarks.label(at: 300, chapters: [chapters[0]], segments: []), "a single chapter says nothing")
    }
}

@MainActor
final class PlayerSubtitleToggleTests: XCTestCase {
    func testTheCKeyTurnsSubtitlesOffAndBackOn() {
        let controller = PlayerController()
        controller.preferredSubtitleLanguages = ["fr"]
        controller.update(
            position: 0, duration: 1000, isPaused: false, volume: 100, isMuted: false, speed: 1, audioTracks: [],
            subtitleTracks: [TrackItem(id: 2, type: "sub", title: "", language: "eng", isSelected: false),
                             TrackItem(id: 5, type: "sub", title: "", language: "fre", isSelected: false)],
            selectedAudioId: nil, selectedSubtitleId: nil
        )
        controller.toggleSubtitles()
        XCTAssertEqual(controller.selectedSubtitleId, 5, "off at first: the preferred language")
        controller.selectSubtitle(id: 2)
        controller.toggleSubtitles()
        XCTAssertNil(controller.selectedSubtitleId)
        controller.toggleSubtitles()
        XCTAssertEqual(controller.selectedSubtitleId, 2, "back to the track that was on")
    }

    func testSpeedKeysChangeTheSpeed() {
        let controller = PlayerController()
        controller.stepSpeed(faster: false)
        controller.stepSpeed(faster: false)
        controller.stepSpeed(faster: false)
        XCTAssertEqual(controller.playbackSpeed, 0.5)
    }
}

@MainActor
final class PlayerWindowTitleTests: AppTestCase {
    func testTheTitleNamesTheEpisodeAndFollowsTheNextItem() throws {
        try skipOnCI("opens a real player window")
        var episode = makeItem(id: "A New Land", type: "Episode")
        episode.seriesName = "Alone"
        episode.parentIndexNumber = 3
        episode.indexNumber = 1
        XCTAssertEqual(PlayerWindowController.title(for: episode), "Alone · S3:E1 · A New Land")
        XCTAssertEqual(PlayerWindowController.title(for: makeItem(id: "Amélie", type: "Movie")), "Amélie")
        XCTAssertEqual(PlayerWindowController.title(for: nil), "Playfin")

        // A second video started while the player is open: same window, new title.
        let model = AppModel()
        let controller = PlayerWindowController()
        model.playback = Playback(movie: makeItem(id: "Percy", type: "Movie"), url: "/nonexistent.mkv",
                                  httpHeader: "", startSeconds: 0, subtitles: [])
        controller.show(model: model)
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.title, "Percy")
        model.playback = Playback(movie: episode, url: "/nonexistent.mkv", httpHeader: "", startSeconds: 0, subtitles: [])
        controller.show(model: model)
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(window.title, "Alone · S3:E1 · A New Land")
        model.playback = nil
        controller.close()
    }

    func testPreviousAndNextEpisodes() {
        let episodes = ["e1", "e2", "e3"].map { makeItem(id: $0, type: "Episode") }
        XCTAssertEqual(PlaybackChooser.episode(before: "e2", in: episodes)?.id, "e1")
        XCTAssertNil(PlaybackChooser.episode(before: "e1", in: episodes))
        XCTAssertNil(PlaybackChooser.episode(before: "zz", in: episodes))
        XCTAssertEqual(PlaybackChooser.episode(after: "e2", in: episodes)?.id, "e3")
    }
}

final class EpisodesSectionStateTests: XCTestCase {
    private func state(selected: String?, shown: String?, loading: Bool = false, seasonsLoaded: Bool = true,
                       hasSeasons: Bool = true, hasEpisodes: Bool = false) -> EpisodesSectionState {
        EpisodesSectionState.state(selectedSeasonId: selected, shownSeasonId: shown, isLoadingEpisodes: loading,
                                   seasonsLoaded: seasonsLoaded, hasSeasons: hasSeasons, hasEpisodes: hasEpisodes)
    }

    func testNoEmptyMessageBeforeTheEpisodesArrive() {
        XCTAssertEqual(state(selected: nil, shown: nil, seasonsLoaded: false, hasSeasons: false), .loading,
                       "seasons not known yet: no \"No episode\" for a moment")
        XCTAssertEqual(state(selected: "s1", shown: nil), .loading, "first season not loaded yet")
        XCTAssertEqual(state(selected: "s2", shown: "s1", hasEpisodes: true), .loading, "never the old season's episodes")
        XCTAssertEqual(state(selected: "s1", shown: "s1", loading: true), .loading)
    }

    func testTheEmptyMessageOnlyAfterAnAnswer() {
        XCTAssertEqual(state(selected: "s1", shown: "s1"), .empty)
        XCTAssertEqual(state(selected: nil, shown: nil, seasonsLoaded: true, hasSeasons: false), .empty, "a series without seasons")
        XCTAssertEqual(state(selected: "s1", shown: "s1", hasEpisodes: true), .episodes)
    }
}

final class MenuClickGuardTests: XCTestCase {
    func testAClickBesideAnOpenWindowDoesNotPause() {
        var guardrail = MenuClickGuard()
        XCTAssertEqual(guardrail.filter(.togglePause, menuOpen: true, menuClosedAt: nil), .ignore)
        XCTAssertEqual(guardrail.filter(.undoPauseAndToggleFullScreen, menuOpen: false, menuClosedAt: nil), .ignore,
                       "the second click of that double click does not pause either")
    }

    func testAClickJustAfterTheWindowClosedIsIgnoredThenClicksWorkAgain() {
        var guardrail = MenuClickGuard()
        let closed = Date()
        XCTAssertEqual(guardrail.filter(.togglePause, menuOpen: false, menuClosedAt: closed, now: closed.addingTimeInterval(0.1)), .ignore)
        XCTAssertEqual(guardrail.filter(.togglePause, menuOpen: false, menuClosedAt: closed, now: closed.addingTimeInterval(2)), .togglePause)
        XCTAssertEqual(guardrail.filter(.undoPauseAndToggleFullScreen, menuOpen: false, menuClosedAt: closed),
                       .undoPauseAndToggleFullScreen, "a normal double click still goes full screen")
    }

    func testNoWindowNoChange() {
        var guardrail = MenuClickGuard()
        XCTAssertEqual(guardrail.filter(.togglePause, menuOpen: false, menuClosedAt: nil), .togglePause)
    }
}
