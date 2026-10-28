import Foundation

/// mpv options applied at the start of each playback: the core computes them from the saved settings.
enum PlayerOptions {
    /// Language codes ("fr", "en"…) of the system's preferred languages, to choose audio and subtitle tracks.
    static func systemLanguageCodes(_ identifiers: [String] = Locale.preferredLanguages) -> [String] {
        var codes: [String] = []
        for identifier in identifiers {
            let code = Locale(identifier: identifier).language.languageCode?.identifier ?? ""
            if !code.isEmpty, !codes.contains(code) { codes.append(code) }
        }
        return codes
    }

    static func current(settings: AppSettings? = nil) -> [MpvOption] {
        let values = settings ?? SettingsStore(dir: AppPaths.supportDirectory.path).load()
        return mpvOptions(settings: values, systemLanguages: systemLanguageCodes())
    }
}

/// Resume rule: under 5% we restart from the beginning, beyond 90% the item is considered finished.
enum ResumeRule {
    static func startSeconds(positionTicks: Int64, runTimeTicks: Int64?) -> Double {
        guard positionTicks > 0 else { return 0 }
        if let total = runTimeTicks, total > 0 {
            let fraction = Double(positionTicks) / Double(total)
            if fraction < 0.05 || fraction > 0.90 { return 0 }
        }
        return Double(positionTicks) / ticksPerSecond
    }
}
