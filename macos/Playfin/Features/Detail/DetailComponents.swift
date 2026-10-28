import SwiftUI

/// Ratings row (user rating, critics), shared by the movie and series detail pages.
struct DetailRatingsRow: View {
    let movie: Movie

    var body: some View {
        HStack(spacing: 18) {
            // Community rating (a single one: the server does not state its source)
            if let score = movie.communityRating, score > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.rating)
                    Text(String(format: "%.1f", score))
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                    Text("/10")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            // Rotten Tomatoes (Critics 🍅) only if provided by the server
            if let critic = movie.criticRating, critic > 0 {
                HStack(spacing: 8) {
                    Text("ROTTEN TOMATOES")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.65))

                    HStack(spacing: 3) {
                        Text("🍅")
                        Text("\(Int(critic))%")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }
}

/// "Cast & Crew" section (round avatars), shared by the detail pages. A person opens their page.
struct CastCrewSection: View {
    let movie: Movie

    var body: some View {
        if !movie.starringActors.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Cast & Crew")
                    .font(Theme.Typography.section)
                    .foregroundStyle(.white)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 22) {
                        ForEach(movie.starringActors, id: \.castId) { person in
                            CastAvatar(person: person)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(.top, 10)
        }
    }
}

/// A round avatar with the name and the role; a click shows everything the person appears in.
private struct CastAvatar: View {
    @Environment(AppModel.self) private var model
    let person: Person

    var body: some View {
        NavigationLink(value: Route.person(id: person.id ?? "", name: person.name)) {
            VStack(spacing: 8) {
                AsyncArtwork(url: person.id.flatMap { model.personImageURL($0, height: 240) }, contentMode: .fill) {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .overlay(Image(systemName: "person.fill").font(.title3).foregroundStyle(.white.opacity(0.4)))
                }
                .frame(width: 74, height: 74)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))

                VStack(spacing: 2) {
                    Text(person.name)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let role = person.role, !role.isEmpty {
                        Text(role)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .frame(width: 85)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle())
        .disabled(person.id == nil)
        .help("See everything \(person.name) appears in")
    }
}

/// Small round button of the detail pages (watched / unwatched, restart…).
struct DetailCircleButton: View {
    let systemName: String
    var tint: Color = .white
    /// Short word under the circle ("Audio", "Download"…): what the icon does, without hovering it.
    var caption: String?
    let help: String
    let action: () -> Void

    static let diameter: CGFloat = 42

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: Self.diameter, height: Self.diameter)
                    .background(Circle().fill(tint == .white ? Color.white.opacity(0.18) : tint.opacity(0.2)))
                    .overlay(Circle().stroke(tint == .white ? Color.white.opacity(0.35) : tint.opacity(0.6), lineWidth: 1))
                if let caption {
                    Text(caption)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        // Lined up by the centre of the circle (not of circle + word): level with the Play button.
        .alignmentGuide(VerticalAlignment.center) { _ in Self.diameter / 2 }
    }
}

extension Person {
    /// Stable identifier for SwiftUI: two actors can have the same name.
    var castId: String { id ?? "\(name)|\(role ?? "")" }
}

/// Background of the detail pages (movie, series): full-bleed background image, vertical gradient to the app background and
/// horizontal gradient that darkens the left so the text stays readable on any image.
struct DetailBackdrop: View {
    @Environment(AppModel.self) private var model
    let item: Movie

    var body: some View {
        ZStack(alignment: .top) {
            Theme.Colors.background
            AsyncArtwork(
                url: model.imageURL(item, .backdrop, height: 1080),
                blurHash: item.backdropBlurHash,
                targetBlurHashSize: CGSize(width: 64, height: 36),
                contentMode: .fill
            ) {
                Theme.Colors.background
            }
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: Theme.Colors.background.opacity(0.25), location: 0.4),
                        .init(color: Theme.Colors.background.opacity(0.8), location: 0.72),
                        .init(color: Theme.Colors.background, location: 1.0)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: Theme.Colors.background.opacity(0.9), location: 0.0),
                        .init(color: Theme.Colors.background.opacity(0.55), location: 0.4),
                        .init(color: .clear, location: 0.75)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// Summary limited to a few lines, with "Read more" when it is long (the rest of the page stays visible).
struct ExpandableOverview: View {
    let text: String
    var lineLimit = 4
    var maxWidth: CGFloat = 720
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.body)
                .lineSpacing(4)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(isExpanded ? nil : lineLimit)
                .frame(maxWidth: maxWidth, alignment: .leading)
            if text.count > 260 {
                Button(isExpanded ? "Show less" : "Read more") {
                    withAnimation(Theme.Motion.standard) { isExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.Colors.accent)
            }
        }
    }
}

/// Thin-bordered pill ("1080p FHD", "Direct play"…) of the Movie · Genre · Rating row.
struct FormatBadge: View {
    let text: String
    var tint: Color = .white
    var help: String?

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(tint.opacity(0.9))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(tint.opacity(0.6), lineWidth: 1))
            .help(help ?? "")
    }
}

/// Line under the summary, as on Plex: "Mar 27, 2008 · 1 hr 26 min · Direct play".
/// "Direct play" (or the reason it is not possible) appears once the file of `fileItemId` is known.
struct DetailInfoLine: View {
    @Environment(AppModel.self) private var model
    let parts: [String]
    let fileItemId: String?
    @State private var info: MediaInfo?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { separator }
                Text(part)
            }
            if let info {
                let support = playbackSupport(info: info)
                if !parts.isEmpty { separator }
                if support.directPlay {
                    Text("Direct play").help("The file plays as it is, without conversion by the server.")
                } else {
                    Text("Conversion needed")
                        .foregroundStyle(Theme.Colors.error)
                        .help(support.notes.joined(separator: "\n"))
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
        .task(id: fileItemId) {
            info = nil
            guard let fileItemId else { return }
            info = await model.mediaInfo(for: fileItemId)
        }
    }

    private var separator: some View { Text("·").foregroundStyle(.white.opacity(0.5)) }
}

/// "Directed by … / Starring …", right-aligned at the right edge of the page, level with the buttons (Plex).
struct DetailCredits: View {
    let item: Movie

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let directors = item.directorsText {
                Text("Directed by \(directors)").lineLimit(1)
            }
            if let actors = item.starringText {
                Text("Starring \(actors)").lineLimit(2)
            }
        }
        .font(.callout)
        .foregroundStyle(.white.opacity(0.85))
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 380, alignment: .trailing)
    }
}

/// Tracks chosen on the detail page before starting playback. Nothing chosen: the player chooses by itself.
struct DetailTrackSelection: Equatable {
    var audioId: Int?
    var subtitleId: Int?
    var subtitlesOff = false
    private var preference = TrackPreference()

    /// What the player must apply; `nil` if nothing was chosen.
    var forPlayback: TrackPreference? {
        audioId != nil || subtitleId != nil || subtitlesOff ? preference : nil
    }

    mutating func chooseAudio(_ track: TrackItem) {
        audioId = track.id
        preference.audioLanguage = TrackGrouping.languageCode(track.language)
        preference.audioKind = TrackGrouping.kind(of: track).rawValue
    }

    mutating func chooseSubtitle(_ track: TrackItem) {
        subtitleId = track.id
        subtitlesOff = false
        preference.subtitleLanguage = TrackGrouping.languageCode(track.language)
        preference.subtitleKind = TrackGrouping.kind(of: track).rawValue
        preference.subtitlesOff = false
    }

    mutating func disableSubtitles() {
        subtitleId = nil
        subtitlesOff = true
        preference.subtitleLanguage = nil
        preference.subtitleKind = nil
        preference.subtitlesOff = true
    }
}

/// Two round buttons, Audio and Subtitles, next to the play button: they open the same window as the player.
/// Always present (greyed out until the file is known) so that the other buttons do not move.
struct DetailTrackButtons: View {
    @Environment(AppModel.self) private var model
    let itemId: String
    @Binding var selection: DetailTrackSelection
    @State private var info: MediaInfo?
    @State private var openKind: TrackMenu.Kind?

    var body: some View {
        HStack(spacing: 14) {
            DetailCircleButton(
                systemName: "waveform", tint: selection.audioId != nil ? Theme.Colors.accent : .white,
                caption: "Audio", help: "Audio track"
            ) { toggle(.audio) }
            .disabled(audioTracks.isEmpty)
            .popover(isPresented: isOpen(.audio), arrowEdge: .bottom) {
                TrackPopover(
                    kind: .audio, groups: groups(for: audioTracks, system: .audio), isActive: true,
                    onSelect: { id in
                        if let track = audioTracks.first(where: { $0.id == id }) { selection.chooseAudio(track) }
                        openKind = nil
                    },
                    onDisable: nil
                )
                .environment(\.colorScheme, .dark)
            }

            DetailCircleButton(
                systemName: selection.subtitleId != nil ? "captions.bubble.fill" : "captions.bubble",
                tint: selection.subtitleId != nil || selection.subtitlesOff ? Theme.Colors.accent : .white,
                caption: "Subtitles", help: "Subtitles"
            ) { toggle(.subtitles) }
            .disabled(subtitleTracks.isEmpty)
            .popover(isPresented: isOpen(.subtitles), arrowEdge: .bottom) {
                TrackPopover(
                    kind: .subtitles, groups: groups(for: subtitleTracks, system: .subtitles),
                    isActive: !selection.subtitlesOff,
                    onSelect: { id in
                        if let track = subtitleTracks.first(where: { $0.id == id }) { selection.chooseSubtitle(track) }
                        openKind = nil
                    },
                    onDisable: {
                        selection.disableSubtitles()
                        openKind = nil
                    }
                )
                .environment(\.colorScheme, .dark)
            }
        }
        // A stack is lined up by its middle: by the circles here (not circles + words), like a single button.
        .alignmentGuide(VerticalAlignment.center) { _ in DetailCircleButton.diameter / 2 }
        .task(id: itemId) { info = await model.mediaInfo(for: itemId) }
        // Another item (next episode…) has other tracks: the previous choice no longer applies to it.
        .onChange(of: itemId) { _, _ in selection = DetailTrackSelection() }
    }

    private func toggle(_ kind: TrackMenu.Kind) { openKind = openKind == kind ? nil : kind }

    private func isOpen(_ kind: TrackMenu.Kind) -> Binding<Bool> {
        Binding(get: { openKind == kind }, set: { if !$0, openKind == kind { openKind = nil } })
    }

    /// The tracks of the file, numbered as in the player (1, 2, 3… per kind of track).
    private var audioTracks: [TrackItem] { tracks(info?.audio ?? [], type: "audio", selectedId: selection.audioId) }
    private var subtitleTracks: [TrackItem] { tracks(info?.subtitles ?? [], type: "sub", selectedId: selection.subtitleId) }

    private func tracks(_ streams: [StreamInfo], type: String, selectedId: Int?) -> [TrackItem] {
        streams.enumerated().map { index, stream in
            TrackItem(
                id: index + 1, type: type, title: stream.title ?? "", language: stream.language,
                isSelected: index + 1 == selectedId, codec: stream.codec, channels: stream.channels.map { Int($0) },
                isDefault: stream.isDefault, isExternal: stream.isExternal
            )
        }
    }

    private func groups(for tracks: [TrackItem], system kind: TrackMenu.Kind) -> [LanguageGroup] {
        let setting = kind == .audio ? model.settings.values.audioLanguage : model.settings.values.subtitleLanguage
        let preferred = TrackGrouping.preferredLanguages(setting: setting, system: PlayerOptions.systemLanguageCodes())
        return TrackGrouping.groups(tracks, preferred: preferred)
    }
}

/// "About" section (between the episodes and the cast): information, file and languages.
/// `fileItemId`: the item whose file is read (for a series, the episode that will be played).
struct DetailAboutSection: View {
    @Environment(AppModel.self) private var model
    let item: Movie
    var fileItemId: String?
    @State private var info: MediaInfo?
    /// Collapsed at first: a click on the title (or the arrow) unfolds it.
    @State private var isExpanded = false

    var body: some View {
        let columns = [
            AboutColumn(title: "Information", rows: informationRows),
            AboutColumn(title: "File", rows: fileRows),
            AboutColumn(title: "Languages", rows: languageRows)
        ].filter { !$0.rows.isEmpty }

        Group {
            if !columns.isEmpty {
                content(columns)
            } else {
                // An invisible point keeps the view alive: without it, `.task` would never start.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        // Outside the `if`: the file must be read even when the other columns are empty.
        .task(id: fileItemId) {
            guard let fileItemId else { return }
            info = await model.mediaInfo(for: fileItemId)
        }
    }

    @ViewBuilder
    private func content(_ columns: [AboutColumn]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(Theme.Motion.standard) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("About")
                        .font(Theme.Typography.section)
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                HStack(alignment: .top, spacing: 48) {
                    ForEach(columns, id: \.title) { column in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(column.title.uppercased())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.5))
                            ForEach(column.rows, id: \.label) { row in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.label).font(.caption).foregroundStyle(.white.opacity(0.55))
                                    Text(row.value).font(.subheadline).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
                                }
                            }
                        }
                        .frame(width: 210, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 8)
    }

    private struct AboutRow { let label: String; let value: String }
    private struct AboutColumn { let title: String; let rows: [AboutRow] }

    private var informationRows: [AboutRow] {
        var rows: [AboutRow] = []
        if !item.formattedReleaseDate.isEmpty { rows.append(AboutRow(label: "Released", value: item.formattedReleaseDate)) }
        if let duration = item.formattedDuration { rows.append(AboutRow(label: "Duration", value: duration)) }
        if let rating = item.officialRating, !rating.isEmpty { rows.append(AboutRow(label: "Rating", value: rating)) }
        if !item.genres.isEmpty { rows.append(AboutRow(label: "Genres", value: item.genres.joined(separator: ", "))) }
        return rows
    }

    private var fileRows: [AboutRow] {
        guard let info else { return [] }
        var rows: [AboutRow] = []
        if let container = info.container, !container.isEmpty { rows.append(AboutRow(label: "Container", value: container.uppercased())) }
        let video = [
            info.videoCodec?.uppercased(),
            formatResolutionTier(width: info.width.map { Int($0) }, height: info.height.map { Int($0) }),
            MediaInfoText.quality(info)
        ].compactMap { $0 }.filter { !$0.isEmpty }
        if !video.isEmpty { rows.append(AboutRow(label: "Video", value: video.joined(separator: " · "))) }
        return rows
    }

    private var languageRows: [AboutRow] {
        guard let info else { return [] }
        var rows: [AboutRow] = []
        if let audio = MediaInfoText.languages(info.audio) { rows.append(AboutRow(label: "Audio", value: audio)) }
        if let subtitles = MediaInfoText.languages(info.subtitles) { rows.append(AboutRow(label: "Subtitles", value: subtitles)) }
        return rows
    }
}

/// Texts taken from a file description (pure functions, tested).
enum MediaInfoText {
    /// "French, English, German (+2)": distinct languages, in the file's order, named in English.
    static func languages(_ streams: [StreamInfo], locale: Locale = TrackGrouping.interfaceLocale, limit: Int = 4) -> String? {
        var names: [String] = []
        for stream in streams {
            let name = TrackGrouping.name(forLanguage: TrackGrouping.languageCode(stream.language), locale: locale)
            if !names.contains(name) { names.append(name) }
        }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? "\(shown) (+\(names.count - limit))" : shown
    }

    /// "HDR10", "Dolby Vision"… (the resolution is already shown by the 4K / 1080p badge).
    static func quality(_ info: MediaInfo) -> String? {
        guard let range = info.videoRange, range != "SDR", !range.isEmpty else { return nil }
        return range == "DOVI" ? "Dolby Vision" : range
    }
}
