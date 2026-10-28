import AppKit
import SwiftUI

/// Previous / next episode buttons of the player (episodes only).
struct EpisodeNavigation {
    let hasPrevious: Bool
    let hasNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
}

/// Player controls: header (close, title, full screen) and bottom tinted-glass panel
/// (tracks and options at the top right, seek bar, then transport and volume).
struct PlayerControlsOverlay: View {
    let movie: Movie
    @Bindable var controller: PlayerController
    let isVisible: Bool
    let onClose: () -> Void
    let onToggleFullScreen: () -> Void
    /// Nil for a movie: no episode buttons.
    var episodeNavigation: EpisodeNavigation?
    /// Intro, credits… spotted by the server: shown on the seek bar.
    var segments: [MediaSegment] = []
    @Binding var isOverlayHovered: Bool
    @Binding var barHeight: CGFloat
    /// A window (tracks, options) is open: the controls do not hide.
    @Binding var isPopoverOpen: Bool

    @State private var openPopover: PlayerPopoverKind?

    var body: some View {
        ZStack {
            // Discreet dark veils at the top and bottom: the text stays readable on a light picture.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 200)
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                Spacer()
                bottomPanel
            }
        }
        .opacity(isVisible ? 1 : 0)
        .animation(Theme.Motion.controls, value: isVisible)
        .allowsHitTesting(isVisible)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .bold))
                    Text("Close").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(GlassCapsule())
            }
            .buttonStyle(.plain)
            .help("Close the player (Esc)")

            Spacer()

            VStack(spacing: 2) {
                Text(movie.displayTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let episode = movie.episodeSubtitle {
                    Text(episode).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                } else if let year = movie.productionYear {
                    Text(String(year)).font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            .shadow(color: .black.opacity(0.6), radius: 6)

            Spacer()

            PlayerIconButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Full screen (F)", action: onToggleFullScreen)
        }
        .padding(.horizontal, 24)
        // Below the title bar (where the window buttons were), not in it: "Close" and full screen on one line.
        .padding(.top, 32)
        .offset(y: isVisible ? 0 : -8)
    }

    // MARK: Panneau bas

    private var bottomPanel: some View {
        VStack(alignment: .trailing, spacing: 12) {
            // Tracks and options: small white circles placed above the panel, on the right; their windows
            // open upwards.
            HStack(spacing: 10) {
                PlayerCircleButton(
                    systemImage: "waveform", help: "Audio track", kind: .audio, openPopover: $openPopover
                ) {
                    TrackPopover(kind: .audio, groups: controller.audioGroups, isActive: true,
                                 onSelect: { controller.selectAudio(id: $0) }, onDisable: nil)
                }
                PlayerCircleButton(
                    systemImage: controller.selectedSubtitleId != nil ? "captions.bubble.fill" : "captions.bubble",
                    help: "Subtitles", kind: .subtitles, openPopover: $openPopover
                ) {
                    TrackPopover(kind: .subtitles, groups: controller.subtitleGroups,
                                 isActive: controller.selectedSubtitleId != nil,
                                 onSelect: { controller.selectSubtitle(id: $0) },
                                 onDisable: { controller.selectSubtitle(id: nil) })
                }
                PlayerCircleButton(systemImage: "ellipsis", help: "Options", kind: .options, openPopover: $openPopover) {
                    OptionsPopover(controller: controller, close: { openPopover = nil })
                }
            }
            .onChange(of: openPopover) { _, value in isPopoverOpen = value != nil }

            VStack(spacing: 10) {
                if let chapter = currentChapterTitle {
                    Text(chapter)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

            // Seek bar with elapsed and remaining time
            HStack(spacing: 12) {
                Text(formatPlayerTime(controller.displayedTime))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 62, alignment: .leading)
                PlayerScrubber(controller: controller, segments: segments)
                Text("-" + formatPlayerTime(max(0, controller.duration - controller.displayedTime)))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 70, alignment: .trailing)
            }

            // Centred transport, volume on the left
            ZStack {
                HStack {
                    volumeControl
                    Spacer()
                    if controller.playbackSpeed != 1 {
                        Text(formatPlaybackSpeed(controller.playbackSpeed))
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.Colors.accent.opacity(0.8)))
                    }
                }
                HStack(spacing: 26) {
                    if let episodes = episodeNavigation {
                        transportButton("backward.end.fill", size: 17, help: "Previous episode (P)", action: episodes.onPrevious)
                            .disabled(!episodes.hasPrevious)
                            .opacity(episodes.hasPrevious ? 1 : 0.35)
                    }
                    transportButton(
                        AppSettings.skipIcon(forward: false, seconds: controller.skipBackSeconds), size: 21,
                        help: "Skip back \(controller.skipBackSeconds) seconds (←)"
                    ) { controller.skipBack() }

                    Button {
                        controller.togglePlayPause()
                    } label: {
                        Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(.white))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .help(controller.isPaused ? "Play (Space)" : "Pause (Space)")
                    .accessibilityLabel(controller.isPaused ? "Play" : "Pause")

                    transportButton(
                        AppSettings.skipIcon(forward: true, seconds: controller.skipForwardSeconds), size: 21,
                        help: "Skip forward \(controller.skipForwardSeconds) seconds (→)"
                    ) { controller.skipForward() }
                    if let episodes = episodeNavigation {
                        transportButton("forward.end.fill", size: 17, help: "Next episode (N)", action: episodes.onNext)
                            .disabled(!episodes.hasNext)
                            .opacity(episodes.hasNext ? 1 : 0.35)
                    }
                }
            }
        }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 14)
            .background(GlassPanel(cornerRadius: 18))
        }
        // Total height (circles included): the subtitles and the "Next episode" card sit above it.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { barHeight = geo.size.height + 24 }
                .onChange(of: geo.size.height) { _, height in barHeight = height + 24 }
        })
        .onHover { isOverlayHovered = $0 }
        .frame(maxWidth: 1100)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .offset(y: isVisible ? 0 : 10)
    }

    private var currentChapterTitle: String? {
        guard controller.chapters.count > 1 else { return nil }
        return controller.chapters.last { $0.timeSeconds <= controller.displayedTime + 0.5 }?.title
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            Button {
                controller.toggleMute()
            } label: {
                let icon = (controller.isMuted || controller.volume == 0)
                    ? "speaker.slash.fill"
                    : (controller.volume < 50 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .help("Mute or unmute (M)")
            .accessibilityLabel("Sound")

            Slider(value: $controller.volume, in: 0...100)
                .frame(width: 90)
                .controlSize(.small)
                .tint(.white)
                .accessibilityLabel("Volume")
        }
    }

    private func transportButton(_ systemImage: String, size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Tinted glass

/// Frosted-glass panel slightly tinted with black: readable on a light picture as well as a dark one.
struct GlassPanel: View {
    var cornerRadius: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.black.opacity(0.38)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.35), radius: 22, y: 8)
            .environment(\.colorScheme, .dark)
    }
}

struct GlassCapsule: View {
    var tint: Color?

    var body: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().fill(tint ?? Color.black.opacity(0.35)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6))
            .environment(\.colorScheme, .dark)
    }
}

/// Round player icon (full screen, options, tracks).
struct PlayerIconLabel: View {
    let systemImage: String
    var isActive = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().fill(isActive ? Theme.Colors.accent.opacity(0.85) : Color.black.opacity(0.35)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6))
                    .environment(\.colorScheme, .dark)
            )
            .contentShape(Circle())
    }
}

struct PlayerIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { PlayerIconLabel(systemImage: systemImage) }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
    }
}

// MARK: - Playback bar

/// Seek bar: fixed height (nothing moves on hover), time bubble under the mouse, already-loaded area,
/// and the chosen position stays displayed while mpv reaches the target (no visual step back).
struct PlayerScrubber: View {
    @Bindable var controller: PlayerController
    var segments: [MediaSegment] = []
    @State private var hoverX: CGFloat?
    @State private var dragFraction: Double?

    private let trackHeight: CGFloat = 5
    private let thumbSize: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = dragFraction ?? controller.displayedFraction
            let buffered = controller.bufferedFraction
            let isActive = hoverX != nil || dragFraction != nil

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(height: trackHeight)
                Capsule().fill(Color.white.opacity(0.32)).frame(width: width * buffered, height: trackHeight)
                // Intro, credits, recap: a lighter band (hidden by the progress once played).
                ForEach(ScrubberMarks.segmentRanges(segments, duration: controller.duration), id: \.self) { range in
                    Capsule().fill(Color.white.opacity(0.55))
                        .frame(width: max(2, width * (range.end - range.start)), height: trackHeight)
                        .offset(x: width * range.start)
                }
                Capsule().fill(Theme.Colors.accent).frame(width: width * fraction, height: trackHeight)
                // Chapters: small gaps in the bar.
                ForEach(ScrubberMarks.chapterFractions(controller.chapters, duration: controller.duration), id: \.self) { mark in
                    Rectangle().fill(Color.black.opacity(0.7))
                        .frame(width: 2, height: trackHeight)
                        .offset(x: width * mark - 1)
                }
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .scaleEffect(isActive ? 1 : 0.5)
                    .opacity(isActive ? 1 : 0)
                    // Only the appearance and the size are animated; the position follows the cursor without delay.
                    .animation(Theme.Motion.hover, value: isActive)
                    .offset(x: min(max(width * fraction - thumbSize / 2, 0), width - thumbSize))
                    .transaction { $0.animation = nil }
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                if let bubbleX = dragFraction.map({ $0 * width }) ?? hoverX, controller.duration > 0 {
                    let seconds = min(max(bubbleX / width, 0), 1) * controller.duration
                    let name = ScrubberMarks.label(at: seconds, chapters: controller.chapters, segments: segments)
                    Text(name.map { "\($0) · \(formatPlayerTime(seconds))" } ?? formatPlayerTime(seconds))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(GlassCapsule())
                        .fixedSize()
                        .alignmentGuide(.leading) { d in
                            // Centred on the mouse, kept inside the bar (the text is longer with a chapter name).
                            -min(max(bubbleX - d.width / 2, 0), max(width - d.width, 0))
                        }
                        .offset(y: -26)
                        .allowsHitTesting(false)
                        .transaction { $0.animation = nil }
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): hoverX = min(max(point.x, 0), width)
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard controller.duration > 0 else { return }
                        let f = min(max(value.location.x / width, 0), 1)
                        dragFraction = f
                        controller.isScrubbing = true
                        controller.scrubTime = f * controller.duration
                    }
                    .onEnded { value in
                        defer {
                            dragFraction = nil
                            controller.isScrubbing = false
                        }
                        guard controller.duration > 0 else { return }
                        let f = min(max(value.location.x / width, 0), 1)
                        controller.seek(absolute: f * controller.duration)
                    }
            )
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(formatPlayerTime(controller.displayedTime))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: controller.skipForward()
            case .decrement: controller.skipBack()
            @unknown default: break
            }
        }
    }
}

// MARK: - Tracks and options (windows that open upwards)

enum PlayerPopoverKind: Hashable { case audio, subtitles, options }

/// White circle above the panel; a click opens its window above (more natural than a menu going down,
/// the button being at the bottom of the screen).
struct PlayerCircleButton<Content: View>: View {
    let systemImage: String
    let help: String
    let kind: PlayerPopoverKind
    @Binding var openPopover: PlayerPopoverKind?
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        Button {
            openPopover = openPopover == kind ? nil : kind
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(isHovered || openPopover == kind ? 1 : 0.9)))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                .scaleEffect(isHovered ? 1.06 : 1)
                .animation(Theme.Motion.hover, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .popover(
            isPresented: Binding(get: { openPopover == kind }, set: { if !$0, openPopover == kind { openPopover = nil } }),
            arrowEdge: .top
        ) {
            content()
                .environment(\.colorScheme, .dark)
        }
    }
}

/// Tracks window in two pages: first the languages (and "Off"), then, after a click on a language,
/// a page with only its tracks and a back arrow.
struct TrackPopover: View {
    let kind: TrackMenu.Kind
    let groups: [LanguageGroup]
    var isActive: Bool
    let onSelect: (Int) -> Void
    let onDisable: (() -> Void)?
    @State private var language: LanguageGroup?

    var body: some View {
        ZStack {
            if let language {
                tracksPage(language)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                languagesPage
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(width: 300)
        .clipped()
        .animation(Theme.Motion.standard, value: language?.id)
    }

    private var languagesPage: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kind == .audio ? "Audio" : "Subtitles")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            if let onDisable {
                row(title: "Off", selected: !isActive, trailingChevron: false) { onDisable() }
            }
            if groups.isEmpty {
                Text(kind == .audio ? "No audio track" : "No subtitles")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            scrollList(count: groups.count) {
                ForEach(groups) { group in
                    row(
                        title: group.name,
                        detail: group.choices.count > 1 ? "\(group.choices.count) tracks" : group.choices.first?.label ?? "",
                        selected: group.choices.contains(where: \.isSelected),
                        trailingChevron: true
                    ) { language = group }
                }
            }
        }
    }

    private func tracksPage(_ group: LanguageGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                language = nil
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.callout.bold())
                    Text(group.name).font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to languages")
            scrollList(count: group.choices.count) {
                ForEach(group.choices) { choice in
                    row(title: choice.label, detail: choice.detail, selected: choice.isSelected, trailingChevron: false) {
                        onSelect(choice.id)
                    }
                }
            }
        }
    }

    /// Number of rows visible at once; beyond that, the list scrolls.
    private static let visibleRows = 5
    /// Fixed height of a row: allows limiting the list to exactly `visibleRows` rows.
    private static let rowHeight: CGFloat = 44
    private static let rowSpacing: CGFloat = 2

    /// List that stops at five rows and scrolls beyond (otherwise it would take the whole window height).
    @ViewBuilder
    private func scrollList<Rows: View>(count: Int, @ViewBuilder rows: () -> Rows) -> some View {
        if count > 0 {
            ScrollView {
                VStack(alignment: .leading, spacing: Self.rowSpacing) { rows() }
            }
            .frame(height: CGFloat(min(count, Self.visibleRows)) * (Self.rowHeight + Self.rowSpacing) - Self.rowSpacing)
        }
    }

    private func row(
        title: String, detail: String = "", selected: Bool, trailingChevron: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .opacity(selected ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if trailingChevron {
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .frame(height: Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.white.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
    }
}

/// Options window: speed, aspect ratio, chapters, information.
struct OptionsPopover: View {
    @Bindable var controller: PlayerController
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speed").font(.headline)
                Picker("Speed", selection: Binding(get: { controller.playbackSpeed }, set: { controller.setSpeed($0) })) {
                    ForEach(PlaybackSpeeds.all, id: \.self) { Text(formatPlaybackSpeed($0)).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Picture").font(.headline)
                // Same presentation as the speed: the active choice is framed.
                Picker("Aspect ratio", selection: Binding(
                    get: { controller.isZoomed ? "zoom" : controller.currentAspectRatio },
                    set: { value in
                        if value == "zoom" {
                            if !controller.isZoomed { controller.toggleZoom() }
                        } else {
                            controller.setAspectRatio(value)
                        }
                    }
                )) {
                    Text("Original").tag("-1")
                    Text("16:9").tag("16:9")
                    Text("2.35:1").tag("2.35:1")
                    Text("Fill").tag("zoom")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            if !controller.chapters.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chapters").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(controller.chapters) { chapter in
                                Button {
                                    controller.jumpToChapter(chapter.index)
                                    close()
                                } label: {
                                    HStack {
                                        Text(chapter.title).lineLimit(1)
                                        Spacer()
                                        Text(formatPlayerTime(chapter.timeSeconds)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
            Divider()
            Button {
                controller.showInfoSheet.toggle()
                close()
            } label: {
                Label("Playback information", systemImage: "info.circle")
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// Type shared by the tracks windows.
enum TrackMenu {
    enum Kind { case audio, subtitles }
}

// MARK: - Click on the video

/// Transparent area that receives the clicks on the video. Counts the clicks itself (see `VideoClick`): two
/// SwiftUI tap gestures would fire the single click on each click of a double click (3 toggles: paused), and
/// the macOS count follows the system setting, too slow here.
struct VideoClickArea: NSViewRepresentable {
    let onClick: (VideoClick) -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.onClick = onClick
    }

    final class ClickView: NSView {
        var onClick: ((VideoClick) -> Void)?
        private var clickCount = 0
        private var lastClick: TimeInterval = -.infinity

        override func mouseDown(with event: NSEvent) {
            clickCount = VideoClick.clickCount(after: clickCount, interval: event.timestamp - lastClick)
            lastClick = event.timestamp
            let action = VideoClick.action(forClickCount: clickCount)
            if action != .ignore { onClick?(action) }
        }
    }
}
