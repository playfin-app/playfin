import Foundation

/// Kind of track: used to sort (Full before SDH, before Forced…) and to name.
enum TrackKind: Int, Comparable {
    case main, sdh, forced, commentary, audioDescription, other

    static func < (lhs: TrackKind, rhs: TrackKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A track offered in the menu, under its language.
struct TrackChoice: Identifiable, Equatable {
    let id: Int
    let kind: TrackKind
    let label: String
    let detail: String
    let isSelected: Bool
}

/// All the tracks of one language ("French", "English"…).
struct LanguageGroup: Identifiable, Equatable {
    /// ISO 639-1 code ("fr") or "und" for an unknown language.
    let id: String
    let name: String
    let choices: [TrackChoice]
}

/// Grouping of audio or subtitle tracks by language (pure functions, tested).
enum TrackGrouping {
    /// ISO 639-2 "bibliographic" codes that Foundation does not know.
    static let bibliographic = [
        "fre": "fr", "ger": "de", "dut": "nl", "chi": "zh", "cze": "cs", "gre": "el", "per": "fa", "rum": "ro",
        "slo": "sk", "wel": "cy", "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "geo": "ka", "ice": "is",
        "mac": "mk", "mao": "mi", "may": "ms", "tib": "bo"
    ]

    /// "fre", "fra", "fr", "fr-CA" → "fr"; "und", "" → nil.
    static func languageCode(_ raw: String?) -> String? {
        guard let value = raw?.lowercased().trimmingCharacters(in: .whitespaces),
              !value.isEmpty, value != "und", value != "unk", value != "mis", value != "zxx" else { return nil }
        if let mapped = bibliographic[value] { return mapped }
        let base = String(value.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        let code = Locale.LanguageCode(base)
        if let alpha2 = code.identifier(.alpha2) { return alpha2 }
        return base.count == 2 ? base : nil
    }

    private static func containsWord(_ text: String, _ words: [String]) -> Bool {
        words.contains { word in
            text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: [.regularExpression]) != nil
        }
    }

    static func kind(of track: TrackItem) -> TrackKind {
        let title = track.title.lowercased()
        if track.isForced || containsWord(title, ["forced", "forcé", "forcés", "forces", "forzado"]) { return .forced }
        if track.isHearingImpaired || containsWord(title, ["sdh", "cc", "hi", "malentendants", "hearing impaired"]) { return .sdh }
        if title.contains("comment") { return .commentary }
        if track.type == "audio", title.contains("descri") || containsWord(title, ["ad"]) { return .audioDescription }
        return .main
    }

    static func label(for kind: TrackKind, trackType: String) -> String {
        switch kind {
        case .main: return trackType == "audio" ? "Main" : "Full"
        case .sdh: return "Deaf and hard of hearing"
        case .forced: return "Forced"
        case .commentary: return "Commentary"
        case .audioDescription: return "Audio description"
        case .other: return "Other"
        }
    }

    /// "5.1", "2.0"… from the number of channels.
    static func channelLayout(_ channels: Int?) -> String? {
        switch channels {
        case 1: return "1.0"
        case 2: return "2.0"
        case 6: return "5.1"
        case 8: return "7.1"
        case .some(let count) where count > 0: return "\(count) channels"
        default: return nil
        }
    }

    static func detail(_ track: TrackItem, languageName: String?) -> String {
        var parts: [String] = []
        let title = track.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, title.caseInsensitiveCompare(languageName ?? "") != .orderedSame,
           title.lowercased() != (track.language ?? "").lowercased() {
            parts.append(title)
        }
        if let codec = track.codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        if track.type == "audio", let layout = channelLayout(track.channels) { parts.append(layout) }
        if track.isExternal { parts.append("external") }
        return parts.joined(separator: " · ")
    }

    /// Language of the interface (English, decision 0011): track names follow it, not the language of the Mac,
    /// otherwise an English menu showed "Anglais" on a French Mac.
    static let interfaceLocale = Locale(identifier: "en_US")

    static func name(forLanguage code: String?, locale: Locale = interfaceLocale) -> String {
        guard let code else { return "Unknown language" }
        return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? code.uppercased()
    }

    /// Groups by language. Order: preferred languages first (in the order given), then alphabetical,
    /// "Unknown language" last. Within a language: Full, SDH, Forced, Commentary; the default track first.
    static func groups(_ tracks: [TrackItem], preferred: [String], locale: Locale = interfaceLocale) -> [LanguageGroup] {
        let byLanguage = Dictionary(grouping: tracks) { languageCode($0.language) ?? "und" }
        let built = byLanguage.map { code, list -> LanguageGroup in
            let languageName = name(forLanguage: code == "und" ? nil : code, locale: locale)
            let sorted = list.sorted { a, b in
                let (ka, kb) = (kind(of: a), kind(of: b))
                if ka != kb { return ka < kb }
                if a.isDefault != b.isDefault { return a.isDefault }
                return a.id < b.id
            }
            let choices = sorted.map { track -> TrackChoice in
                let trackKind = kind(of: track)
                return TrackChoice(
                    id: track.id, kind: trackKind, label: label(for: trackKind, trackType: track.type),
                    detail: detail(track, languageName: languageName), isSelected: track.isSelected
                )
            }
            return LanguageGroup(id: code, name: languageName, choices: choices)
        }
        return built.sorted { a, b in
            let (ra, rb) = (preferred.firstIndex(of: a.id) ?? Int.max, preferred.firstIndex(of: b.id) ?? Int.max)
            if ra != rb { return ra < rb }
            if (a.id == "und") != (b.id == "und") { return b.id == "und" }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    /// Button text: "French · Full" for the active track, otherwise nil.
    static func activeSummary(_ groups: [LanguageGroup]) -> String? {
        for group in groups {
            if let choice = group.choices.first(where: \.isSelected) {
                return group.choices.count > 1 ? "\(group.name) · \(choice.label)" : group.name
            }
        }
        return nil
    }

    /// Preferred languages for sorting: the one from the settings, then those of the system, without duplicates.
    static func preferredLanguages(setting: String, system: [String]) -> [String] {
        var result: [String] = []
        for code in [setting] + system where !code.isEmpty && !result.contains(code) { result.append(code) }
        return result
    }
}

/// Tracks chosen for a series (audio language, subtitle language and kind), reapplied to the next episode.
struct TrackPreference: Codable, Equatable {
    var audioLanguage: String?
    var subtitleLanguage: String?
    var subtitleKind: Int?
    var subtitlesOff = false
    /// Kind of the audio track (main, commentary…): without it, the main track is always preferred.
    var audioKind: Int?
}

/// Per-series track memory (pure functions + storage in the app preferences).
enum TrackMemory {
    private static func key(_ seriesId: String) -> String { "Playfin_Tracks_\(seriesId)" }

    static func load(seriesId: String, defaults: UserDefaults = AppPaths.defaults) -> TrackPreference? {
        guard let data = defaults.data(forKey: key(seriesId)) else { return nil }
        return try? JSONDecoder().decode(TrackPreference.self, from: data)
    }

    static func save(_ preference: TrackPreference, seriesId: String, defaults: UserDefaults = AppPaths.defaults) {
        if let data = try? JSONEncoder().encode(preference) { defaults.set(data, forKey: key(seriesId)) }
    }

    static func preference(audio: TrackItem?, subtitle: TrackItem?) -> TrackPreference {
        TrackPreference(
            audioLanguage: TrackGrouping.languageCode(audio?.language),
            subtitleLanguage: TrackGrouping.languageCode(subtitle?.language),
            subtitleKind: subtitle.map { TrackGrouping.kind(of: $0).rawValue },
            subtitlesOff: subtitle == nil,
            audioKind: audio.map { TrackGrouping.kind(of: $0).rawValue }
        )
    }

    /// Audio track to choose: same language and same kind if known, otherwise the main track.
    static func audioChoice(_ tracks: [TrackItem], preference: TrackPreference) -> Int? {
        guard let language = preference.audioLanguage else { return nil }
        let matching = tracks.filter { TrackGrouping.languageCode($0.language) == language }
        let sameKind = matching.first { TrackGrouping.kind(of: $0).rawValue == preference.audioKind }
        return (sameKind ?? matching.first { TrackGrouping.kind(of: $0) == .main } ?? matching.first)?.id
    }

    /// Subtitles to choose: `.some(nil)` for "off", `nil` if there is nothing to change.
    static func subtitleChoice(_ tracks: [TrackItem], preference: TrackPreference) -> Int?? {
        if preference.subtitlesOff { return .some(nil) }
        guard let language = preference.subtitleLanguage else { return nil }
        let matching = tracks.filter { TrackGrouping.languageCode($0.language) == language }
        guard !matching.isEmpty else { return nil }
        let sameKind = matching.first { TrackGrouping.kind(of: $0).rawValue == preference.subtitleKind }
        return .some((sameKind ?? matching.first)?.id)
    }
}

/// Subtitle style changed during playback (pure functions, tested).
enum SubtitleStyle {
    /// The properties of the style. The core only gives the background ones when there is a background:
    /// they are first set back to mpv's defaults, otherwise "None" would keep the old box.
    static let defaults: [(String, String)] = [("sub-border-style", "outline-and-shadow"), ("sub-back-color", "#00000000")]
    private static let names: Set<String> = ["sub-font-size", "sub-color", "sub-border-style", "sub-back-color"]

    static func liveOptions(settings: AppSettings) -> [(String, String)] {
        defaults + mpvOptions(settings: settings, systemLanguages: [])
            .filter { names.contains($0.name) }
            .map { ($0.name, $0.value) }
    }

    /// ± 10 s at most, rounded to the tenth (the buttons move by 0.1 s).
    static func clampedDelay(_ seconds: Double) -> Double {
        (min(10, max(-10, seconds)) * 10).rounded() / 10
    }

    /// "+0.3 s", "-1.5 s", "0 s".
    static func delayLabel(_ seconds: Double) -> String {
        seconds == 0 ? "0 s" : String(format: "%+.1f s", seconds)
    }
}
