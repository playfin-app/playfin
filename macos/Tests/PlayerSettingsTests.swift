import XCTest
import AppKit
@testable import Playfin

final class PlayerSettingsTests: XCTestCase {
    func testPlayerOptionsComeFromTheSavedSettings() {
        var settings = defaultSettings()
        settings.cachePreset = "low"
        settings.hardwareDecoding = false
        let options = Dictionary(uniqueKeysWithValues: PlayerOptions.current(settings: settings).map { ($0.name, $0.value) })
        XCTAssertEqual(options["hwdec"], "no")
        XCTAssertEqual(options["demuxer-max-bytes"], "50MiB")
        XCTAssertEqual(options["cache-secs"], "30")
    }

    func testSettingsAreSavedAndReloaded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(dir: dir.path)
        var settings = defaultSettings()
        settings.skipForwardSeconds = 30
        settings.autoPlayNext = false
        _ = try store.save(settings: settings)
        let reloaded = SettingsStore(dir: dir.path).load()
        XCTAssertEqual(reloaded.skipForwardSeconds, 30)
        XCTAssertFalse(reloaded.autoPlayNext)
    }

    @MainActor
    func testSettingsModelPersistsEveryChangeAndClampsInvalidValues() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = SettingsModel(directory: dir)
        model.values.skipBackSeconds = 999
        XCTAssertEqual(model.values.skipBackSeconds, 120, "the core brings the value back into the allowed range")
        model.values.subtitleSize = "large"
        XCTAssertEqual(SettingsModel(directory: dir).values.subtitleSize, "large")
    }

    func testCustomMpvOptionsAreValidatedByTheCore() {
        XCTAssertNoThrow(try validateCustomMpvOptions(text: "cache-secs=900"))
        XCTAssertThrowsError(try validateCustomMpvOptions(text: "script=/tmp/x.lua"))
    }

    func testSkipIconsFallBackWhenThereIsNoSymbolForTheDuration() {
        XCTAssertEqual(AppSettings.skipIcon(forward: true, seconds: 30), "goforward.30")
        XCTAssertEqual(AppSettings.skipIcon(forward: false, seconds: 7), "gobackward")
    }

    func testNextEpisodeIsTheOneAfterTheFinishedOne() {
        func ep(_ id: String) -> Movie {
            Movie(
                id: id, name: id, sortName: nil, productionYear: nil, premiereDate: nil, runTimeTicks: nil,
                container: nil, overview: nil, communityRating: nil, criticRating: nil, officialRating: nil,
                genres: [], dateCreated: nil, people: [], userData: nil, seriesName: nil, seriesId: nil, seasonId: nil,
                seasonName: nil, indexNumber: nil, parentIndexNumber: nil, itemType: "Episode", width: nil,
                height: nil, primaryBlurHash: nil, primaryImageAspectRatio: nil
            )
        }
        let list = [ep("e1"), ep("e2"), ep("e3")]
        XCTAssertEqual(PlaybackChooser.episode(after: "e1", in: list)?.id, "e2")
        XCTAssertNil(PlaybackChooser.episode(after: "e3", in: list), "last episode: nothing after")
        XCTAssertNil(PlaybackChooser.episode(after: "inconnu", in: list))
    }

    func testSystemLanguageCodes() {
        XCTAssertEqual(PlayerOptions.systemLanguageCodes(["fr-CA", "en-US", "fr-FR"]), ["fr", "en"])
    }

    func testResumeRule() {
        let hour: Int64 = 36_000_000_000
        XCTAssertEqual(ResumeRule.startSeconds(positionTicks: 0, runTimeTicks: hour), 0)
        XCTAssertEqual(ResumeRule.startSeconds(positionTicks: hour / 40, runTimeTicks: hour), 0, "under 5%: from the start")
        XCTAssertEqual(ResumeRule.startSeconds(positionTicks: hour / 2, runTimeTicks: hour), 1800)
        XCTAssertEqual(ResumeRule.startSeconds(positionTicks: hour * 95 / 100, runTimeTicks: hour), 0, "beyond 90%: finished")
        XCTAssertEqual(ResumeRule.startSeconds(positionTicks: 600_000_000, runTimeTicks: nil), 60, "unknown duration: position kept")
    }

    @MainActor
    func testControllerTalksToAnEngineNotToMpv() {
        @MainActor final class FakeEngine: PlayerEngine {
            var calls: [String] = []
            func togglePause() { calls.append("pause") }
            func seek(relative seconds: Double) { calls.append("seek \(seconds)") }
            func seek(absolute seconds: Double) { calls.append("goto \(seconds)") }
            func setVolume(_ volume: Double) { calls.append("volume \(volume)") }
            func toggleMute() { calls.append("mute") }
            func setSpeed(_ speed: Double) { calls.append("speed \(speed)") }
            func selectAudio(id: Int) { calls.append("audio \(id)") }
            func selectSubtitle(id: Int?) { calls.append("sub \(String(describing: id))") }
            func setAspectRatio(_ ratio: String) {}
            func setPanScan(_ value: Double) {}
            func jumpToChapter(_ index: Int) {}
            func setSubtitlePosition(_ percent: Double) { calls.append("subpos \(percent)") }
            func setProperty(_ name: String, to value: String) { calls.append("\(name)=\(value)") }
        func setRenderingSuspended(_ suspended: Bool) {}
            var hostWindow: NSWindow? { nil }
        }
        let engine = FakeEngine()
        let controller = PlayerController()
        controller.engine = engine
        controller.togglePlayPause()
        controller.seek(relative: -10)
        XCTAssertEqual(engine.calls, ["pause", "seek -10.0"])
    }
}

@MainActor
final class SubtitleStyleTests: XCTestCase {
    func testTheStyleIsAppliedLiveAndNoneRemovesTheBox() {
        var settings = defaultSettings()
        settings.subtitleSize = "large"
        settings.subtitleBackground = "black"
        let boxed = Dictionary(SubtitleStyle.liveOptions(settings: settings), uniquingKeysWith: { _, last in last })
        XCTAssertEqual(boxed["sub-font-size"], "72")
        XCTAssertEqual(boxed["sub-border-style"], "background-box")

        settings.subtitleBackground = "none"
        let plain = Dictionary(SubtitleStyle.liveOptions(settings: settings), uniquingKeysWith: { _, last in last })
        XCTAssertEqual(plain["sub-border-style"], "outline-and-shadow", "the old box goes away")
        XCTAssertNil(plain["slang"], "only the style, not the track choice")
    }

    func testTheDelayMovesByTenthsAndResetsForTheNextItem() {
        XCTAssertEqual(SubtitleStyle.clampedDelay(0.30000001), 0.3)
        XCTAssertEqual(SubtitleStyle.clampedDelay(42), 10)
        XCTAssertEqual(SubtitleStyle.delayLabel(-1.5), "-1.5 s")
        XCTAssertEqual(SubtitleStyle.delayLabel(0), "0 s")

        let controller = PlayerController()
        controller.adjustSubtitleDelay(by: 0.1)
        controller.adjustSubtitleDelay(by: 0.1)
        XCTAssertEqual(controller.subtitleDelay, 0.2)
        controller.resetForNewItem()
        XCTAssertEqual(controller.subtitleDelay, 0)
    }
}
