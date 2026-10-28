import Foundation
import CoreGraphics

/// Action triggered by a player key. A single table for the whole player (testable without the interface).
enum PlayerKeyAction: Equatable {
    case close, togglePause, toggleFullScreen, toggleMute, skipBack, skipForward, volumeUp, volumeDown
    case nextEpisode, previousEpisode, toggleSubtitles, slower, faster

    /// Physical key codes (positions of a QWERTY keyboard).
    static func from(keyCode: UInt16) -> PlayerKeyAction? {
        switch keyCode {
        case 53: return .close
        case 49: return .togglePause
        case 3: return .toggleFullScreen
        case 46: return .toggleMute
        case 123: return .skipBack
        case 124: return .skipForward
        case 126: return .volumeUp
        case 125: return .volumeDown
        case 45: return .nextEpisode      // N
        case 35: return .previousEpisode  // P
        case 8: return .toggleSubtitles   // C (captions, like YouTube)
        case 33: return .slower           // [
        case 30: return .faster           // ]
        default: return nil
        }
    }

    /// The player keys must only act in the player window, never while text is being typed, and never with ⌘
    /// (⌘M must minimise, ⌘W close, ⌘F search: not mute, nothing or full screen).
    static func shouldHandle(eventWindowIsPlayerWindow: Bool, isTypingText: Bool, hasCommandModifier: Bool = false) -> Bool {
        eventWindowIsPlayerWindow && !isTypingText && !hasCommandModifier
    }
}

/// Playback speeds offered in the options and by the [ and ] keys.
enum PlaybackSpeeds {
    static let all: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// Next speed up or down from the current one (stays at the ends).
    static func step(from speed: Double, faster: Bool) -> Double {
        if faster { return all.first { $0 > speed + 0.001 } ?? all[all.count - 1] }
        return all.last { $0 < speed - 0.001 } ?? all[0]
    }
}

/// C key: subtitles on or off.
enum SubtitleToggle {
    /// Track to turn on: the last one used if it still exists, otherwise the first of the preferred language
    /// (the groups are already ordered: preferred languages first, full track first). Nil: no subtitles at all.
    static func trackToTurnOn(lastUsed: Int?, groups: [LanguageGroup]) -> Int? {
        let ids = groups.flatMap { $0.choices.map(\.id) }
        if let lastUsed, ids.contains(lastUsed) { return lastUsed }
        return ids.first
    }
}

/// What a click on the video does, from the click count (1, 2, 3…).
/// The first click pauses right away; the second click of a double click undoes that pause and goes full screen.
/// Only 2 pause toggles per double click, so playback always continues.
enum VideoClick: Equatable {
    case togglePause
    case undoPauseAndToggleFullScreen
    case ignore

    /// Longest gap between the two clicks of a double click on the video. Shorter than the macOS setting
    /// (0.5 s by default): two separate clicks no longer switch the full screen.
    static let doubleClickInterval: TimeInterval = 0.3

    /// Click count with this gap: the previous count plus one if the click follows it closely, otherwise 1.
    static func clickCount(after previous: Int, interval: TimeInterval) -> Int {
        interval <= doubleClickInterval ? previous + 1 : 1
    }

    static func action(forClickCount count: Int) -> VideoClick {
        switch count {
        case 1: .togglePause
        case 2: .undoPauseAndToggleFullScreen
        default: .ignore
        }
    }
}

/// Click on the video while a window (tracks, options) is open, or has just closed: macOS closes the window on that
/// click and also passes it to the video. That click (and the rest of a double click) must not pause.
struct MenuClickGuard {
    /// The window may already be closed when the click arrives: a click this soon after still counts.
    static let grace: TimeInterval = 0.5
    private(set) var isSwallowing = false

    mutating func filter(_ click: VideoClick, menuOpen: Bool, menuClosedAt: Date?, now: Date = Date()) -> VideoClick {
        // First click of a series: decides for the whole series (its second click must not undo a pause).
        if click == .togglePause {
            let justClosed = menuClosedAt.map { now.timeIntervalSince($0) < Self.grace } ?? false
            isSwallowing = menuOpen || justClosed
        }
        return isSwallowing ? .ignore : click
    }
}

/// Vertical position of the subtitles (mpv's `sub-pos`: 100 = all the way down).
enum SubtitleLayout {
    /// When the control bar is visible, the subtitles are raised just above it.
    static func position(barHeight: CGFloat, playerHeight: CGFloat, controlsVisible: Bool, margin: CGFloat = 16) -> Double {
        guard controlsVisible, playerHeight > 0, barHeight > 0 else { return 100 }
        let lifted = 100 - Double((barHeight + margin) / playerHeight) * 100
        return min(100, max(60, lifted))
    }
}

/// End of playback: mpv keeps the file open (`keep-open`), so we observe `eof-reached`.
enum PlaybackEnd {
    /// A network drop can also cause an "EOF": we only move on if we are really at the end.
    static func isGenuineEnd(eofReached: Bool, position: Double, duration: Double, tolerance: Double = 2) -> Bool {
        eofReached && duration > 0 && position >= duration - tolerance
    }
}

/// Decides whether the player controls may hide (simple state machine, without a clock).
enum ControlsVisibility {
    static func canHide(isPaused: Bool, infoSheetOpen: Bool, overlayHovered: Bool, scrubbing: Bool, menuOpen: Bool = false) -> Bool {
        !isPaused && !infoSheetOpen && !overlayHovered && !scrubbing && !menuOpen
    }
}

/// Text of the playback speed: "1×", "1.25×" (not "1.2x").
func formatPlaybackSpeed(_ speed: Double) -> String {
    let text = String(format: "%g", (speed * 100).rounded() / 100)
    return text + "×"
}

/// Segment spotted by the server that the user can skip with one click.
enum SegmentSkip {
    struct Offer: Equatable {
        let title: String
        let targetSeconds: Double
    }

    /// The segment to offer at this instant, if there is one (intro, credits, recap).
    static func offer(at position: Double, in segments: [MediaSegment]) -> Offer? {
        for segment in segments {
            let start = Double(segment.startTicks) / ticksPerSecond
            let end = Double(segment.endTicks) / ticksPerSecond
            guard position >= start, position < end - 1 else { continue }
            switch segment.kind {
            case "Intro": return Offer(title: "Skip intro", targetSeconds: end)
            case "Outro": return Offer(title: "Skip credits", targetSeconds: end)
            case "Recap": return Offer(title: "Skip recap", targetSeconds: end)
            default: continue
            }
        }
        return nil
    }
}

/// Marks of the seek bar: chapters and segments spotted by the server, as fractions of the duration.
enum ScrubberMarks {
    struct SegmentRange: Hashable {
        let kind: String
        let start: Double
        let end: Double
    }

    /// Start of each chapter except the first one (it starts at 0: nothing to mark).
    static func chapterFractions(_ chapters: [ChapterItem], duration: Double) -> [Double] {
        guard duration > 0, chapters.count > 1 else { return [] }
        return chapters.map { $0.timeSeconds / duration }.filter { $0 > 0.001 && $0 < 0.999 }
    }

    /// Intro, credits, recap and preview, bounded to the bar.
    static func segmentRanges(_ segments: [MediaSegment], duration: Double) -> [SegmentRange] {
        guard duration > 0 else { return [] }
        return segments.compactMap { segment in
            guard name(ofSegment: segment.kind) != nil else { return nil }
            let start = min(max(Double(segment.startTicks) / ticksPerSecond / duration, 0), 1)
            let end = min(max(Double(segment.endTicks) / ticksPerSecond / duration, 0), 1)
            return end > start ? SegmentRange(kind: segment.kind, start: start, end: end) : nil
        }
    }

    /// Name shown next to the time under the mouse: the segment first, otherwise the chapter (if there are several).
    static func label(at seconds: Double, chapters: [ChapterItem], segments: [MediaSegment]) -> String? {
        for segment in segments {
            let start = Double(segment.startTicks) / ticksPerSecond
            let end = Double(segment.endTicks) / ticksPerSecond
            if seconds >= start, seconds < end, let name = name(ofSegment: segment.kind) { return name }
        }
        guard chapters.count > 1 else { return nil }
        let title = chapters.last { $0.timeSeconds <= seconds }?.title
        return title?.isEmpty == false ? title : nil
    }

    static func name(ofSegment kind: String) -> String? {
        switch kind {
        case "Intro": "Intro"
        case "Outro": "Credits"
        case "Recap": "Recap"
        case "Preview": "Preview"
        default: nil
        }
    }
}
