import Foundation

extension Movie {
    /// Tag of the image shown for this item (the series' for an episode), nil if unknown.
    func imageTag(_ kind: ImageKind) -> String? {
        let usesSeries = kind != .logo && !isSeries && !(seriesId ?? "").isEmpty
        switch kind {
        case .primary:
            return usesSeries ? seriesPrimaryImageTag : imageTags.first { $0.kind == "Primary" }?.tag
        case .backdrop:
            return (usesSeries ? parentBackdropImageTags : backdropImageTags).first
        case .logo:
            return imageTags.first { $0.kind == "Logo" }?.tag
        }
    }

    /// Resume position, in seconds (0 if the movie is not started or already watched).
    var resumeSeconds: Double {
        guard userData?.played != true else { return 0 }
        return ResumeRule.startSeconds(positionTicks: userData?.playbackPositionTicks ?? 0, runTimeTicks: runTimeTicks)
    }

    /// Raw position saved on the server, even if the movie was marked as watched.
    var rawPlaybackSeconds: Double {
        Double(userData?.playbackPositionTicks ?? 0) / ticksPerSecond
    }

    /// Tells whether the movie is currently started but not finished.
    var isInProgress: Bool {
        resumeSeconds > 0 && userData?.played != true
    }

    /// Tells whether the movie was marked as watched.
    var isWatched: Bool {
        userData?.played == true
    }

    /// In the user's favourites (heart).
    var isFavorite: Bool {
        userData?.isFavorite == true
    }

    /// "Mark as unwatched" is offered: watched, or started (even a few minutes), or a series partly watched.
    var canMarkUnwatched: Bool {
        isWatched || (userData?.playbackPositionTicks ?? 0) > 0 || (userData?.playedPercentage ?? 0) > 0
    }

    /// Watch fraction between 0.0 and 1.0 (uses playedPercentage or the position / duration ratio).
    var playbackFraction: Double? {
        if let percent = userData?.playedPercentage, percent > 0 {
            return min(max(percent / 100.0, 0.0), 1.0)
        }
        if let total = runTimeTicks, total > 0, let ticks = userData?.playbackPositionTicks, ticks > 0 {
            return min(max(Double(ticks) / Double(total), 0.0), 1.0)
        }
        return nil
    }

    /// "45 min left" or "1 hr 12 min left"
    var remainingText: String? {
        guard let total = runTimeTicks, total > 0, resumeSeconds > 0 else { return nil }
        let totalSeconds = Double(total) / ticksPerSecond
        let remainingSeconds = max(0, totalSeconds - resumeSeconds)
        let minutes = Int((remainingSeconds / 60).rounded(.up))
        guard minutes > 0 else { return nil }
        return Self.durationText(minutes: minutes).map { "\($0) left" }
    }

    /// Formatted duration, as on Plex: "1 hr 26 min", "2 hr" or "45 min".
    var formattedDuration: String? {
        guard let ticks = runTimeTicks else { return nil }
        return Self.durationText(minutes: Int(Double(ticks) / ticksPerSecond / 60))
    }

    static func durationText(minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m > 0 ? "\(h) hr \(m) min" : "\(h) hr"
    }

    /// Main title: series name for an episode, otherwise the item name.
    var displayTitle: String {
        if let series = seriesName, !series.isEmpty {
            return series
        }
        return name
    }

    /// Page of the series for an episode or a season, the item itself otherwise. In "Recently added", Jellyfin returns
    /// a lone new episode instead of its series: its card shows the series (poster, title), so it opens the series.
    var seriesPageId: String {
        if !isSeries, let seriesId, !seriesId.isEmpty { return seriesId }
        return id
    }

    /// Subtitle for episodes: "S1:E3 · Episode title"
    var episodeSubtitle: String? {
        guard let series = seriesName, !series.isEmpty else { return nil }
        var parts: [String] = []
        if let season = parentIndexNumber, let ep = indexNumber {
            parts.append(String(format: "S%d:E%d", season, ep))
        } else if let ep = indexNumber {
            parts.append(String(format: "Episode %d", ep))
        }
        if !name.isEmpty && name != series {
            parts.append(name)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Info line: "2014 · 169 min · PG-13 · ★ 8.7 · MKV"
    var infoLine: String {
        var parts: [String] = []
        if let year = productionYear { parts.append(String(year)) }
        if let dur = formattedDuration { parts.append(dur) }
        if let rating = officialRating { parts.append(rating) }
        if let score = communityRating { parts.append(String(format: "★ %.1f", score)) }
        if let container { parts.append(container.uppercased()) }
        return parts.joined(separator: " · ")
    }

    /// Name used for alphabetical sorting (uses SortName if available, otherwise Name).
    var effectiveSortName: String {
        if let sortName, !sortName.isEmpty {
            return sortName
        }
        return name
    }

    /// First letter for the alphabetical index ("A"..."Z" or "#").
    var sectionLetter: String {
        let clean = effectiveSortName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = clean.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    /// Formatted release date: "15 Jun 2017" or the year
    var formattedReleaseDate: String {
        if let premiereDate, !premiereDate.isEmpty {
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: premiereDate) {
                let df = DateFormatter()
                // Same language as the rest of the interface ("Apr 25, 2001", never "25 avr. 2001").
                df.locale = TrackGrouping.interfaceLocale
                df.dateStyle = .medium
                df.timeStyle = .none
                return df.string(from: date)
            }
            // Try with a YYYY-MM-DD prefix
            if premiereDate.count >= 10 {
                let sub = String(premiereDate.prefix(10))
                let dfInput = DateFormatter()
                dfInput.dateFormat = "yyyy-MM-dd"
                if let d = dfInput.date(from: sub) {
                    let dfOutput = DateFormatter()
                    dfOutput.dateStyle = .medium
                    return dfOutput.string(from: d)
                }
            }
        }
        if let year = productionYear {
            return String(year)
        }
        return ""
    }

    /// Director(s) of the movie
    var directorsText: String? {
        let directors = people.filter { $0.roleType?.localizedCaseInsensitiveContains("Director") == true }
        if !directors.isEmpty {
            return directors.map(\.name).joined(separator: ", ")
        }
        return nil
    }

    /// Main actors
    var starringActors: [Person] {
        people.filter { $0.roleType == nil || $0.roleType?.localizedCaseInsensitiveContains("Actor") == true }
    }

    /// Names of the main actors for the header line (up to 3)
    var starringText: String? {
        let actors = starringActors.prefix(3)
        if !actors.isEmpty {
            return actors.map(\.name).joined(separator: ", ")
        }
        return nil
    }

    /// Actual resolution computed from the video dimensions (width / height)
    var resolutionBadge: String? {
        formatResolutionTier(width: width.map(Int.init), height: height.map(Int.init))
    }

    /// Duration in minutes (useful for displaying episodes).
    var durationMinutes: Int? {
        guard let ticks = runTimeTicks else { return nil }
        let totalMinutes = Int(Double(ticks) / ticksPerSecond / 60)
        return totalMinutes > 0 ? totalMinutes : nil
    }

    /// Tells whether the item is a TV series.
    var isSeries: Bool {
        itemType?.caseInsensitiveCompare("Series") == .orderedSame
    }

    /// Tooltip of the quick play button, depending on what playing will do.
    var playHelp: String {
        if isSeries { return "Continue the series" }
        if isContainer { return "Play the content" }
        return isAudio ? "Listen" : "Play the movie"
    }

    /// Text of an episode's play button: "Resume S1:E3" or "Play S1:E3".
    var playButtonTitle: String {
        var code = ""
        if let season = parentIndexNumber, let episode = indexNumber {
            code = " S\(season):E\(episode)"
        } else if let episode = indexNumber {
            code = " episode \(episode)"
        }
        return (resumeSeconds > 0 ? "Resume" : "Play") + code
    }

    var isSeason: Bool { typeIs(["Season"]) }

    private func typeIs(_ names: [String]) -> Bool {
        guard let itemType else { return false }
        return names.contains { itemType.caseInsensitiveCompare($0) == .orderedSame }
    }

    /// An item that can be played directly (movie, episode, audiobook, audio file…), as opposed
    /// to a series or a container (folder, season, album, author) that must be opened to find what to play.
    var isDirectlyPlayable: Bool {
        !isSeries && !isContainer
    }

    /// Audiobook or audio file that can be played directly.
    var isAudio: Bool {
        typeIs(["AudioBook", "Audio"])
    }

    /// An item that groups other items (author, album, folder, collection): it is opened to see its content.
    var isContainer: Bool {
        typeIs(["Folder", "CollectionFolder", "MusicAlbum", "MusicArtist", "BoxSet", "PhotoAlbum", "Playlist", "Season"])
    }

    /// Cover aspect ratio: movie poster (2:3), square cover for audio.
    var cardAspectRatio: Double {
        if isSeries || typeIs(["Movie", "Episode", "Video"]) { return 2.0 / 3.0 }
        if let ratio = primaryImageAspectRatio, ratio > 0 { return min(max(ratio, 0.5), 1.8) }
        return isAudio || typeIs(["MusicAlbum", "MusicArtist"]) ? 1.0 : 2.0 / 3.0
    }

    /// Single card shape for a grid or a row: the most frequent one among its items (2:3 if empty).
    /// Cards of one container then have the same height: tidier, and a lazy container whose
    /// cards differ in height never stops measuring them again (the home froze that way).
    static func commonCardAspectRatio(of items: some Sequence<Movie>) -> Double {
        // Ratios close to each other (0.66 and 0.67) count as one shape.
        var counts: [Double: Int] = [:]
        var exact: [Double: Double] = [:]
        var order: [Double] = []
        for item in items {
            let ratio = item.cardAspectRatio
            let key = (ratio * 100).rounded() / 100
            if counts[key] == nil { order.append(key); exact[key] = ratio }
            counts[key, default: 0] += 1
        }
        // On a tie, the shape seen first wins (stable result for the same list).
        guard let key = order.max(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) }) else { return 2.0 / 3.0 }
        return exact[key] ?? 2.0 / 3.0
    }
}

/// Returns the label of the resolution tier (e.g. "4K UHD", "1440p QHD", "1080p FHD", "720p HD", "480p")
func formatResolutionTier(width: Int?, height: Int?) -> String? {
    let w = width ?? 0
    let h = height ?? 0
    if w >= 3800 || h >= 2000 {
        return "4K UHD"
    } else if w >= 2400 || h >= 1350 {
        return "1440p QHD"
    } else if w >= 1900 || h >= 1000 {
        return "1080p FHD"
    } else if w >= 1200 || h >= 700 {
        return "720p HD"
    } else if h > 0 {
        return "\(h)p"
    }
    return nil
}
