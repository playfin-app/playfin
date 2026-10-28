import SwiftUI

/// Style of clickable cards (posters, thumbnails, episodes): slight press-down on click. Hover is drawn by
/// the card itself, on the image only (see `PosterCard`).
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.hover, value: configuration.isPressed)
            .focusEffectDisabled()
    }
}

/// Shared visual feedback for buttons (capsules, circles): slight press-down on click, brightening on hover.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> PressableLabel {
        PressableLabel(configuration: configuration)
    }

    struct PressableLabel: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .brightness(isHovered ? 0.06 : 0)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(Theme.Motion.hover, value: configuration.isPressed)
                .animation(Theme.Motion.hover, value: isHovered)
                .onHover { isHovered = $0 }
                .focusEffectDisabled()
        }
    }
}

/// The app's single play button: white capsule, icon + text, greyed out when the server is unreachable.
struct PlayButton: View {
    @Environment(AppModel.self) private var model
    let title: String
    var systemImage = "play.fill"
    var isProminent = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: systemImage).font(.system(size: 15, weight: .bold))
                Text(title).font(.system(size: 16, weight: .bold)).lineLimit(1)
            }
            .foregroundStyle(isProminent ? .black : .white)
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
            .background(Capsule().fill(isProminent ? Color.white.opacity(model.isServerUnreachable ? 0.6 : 1) : Color.white.opacity(0.18)))
        }
        .buttonStyle(PressableButtonStyle())
        .help(model.isServerUnreachable ? "Server unreachable — streaming requires a connection" : title)
        .accessibilityLabel(title)
    }
}

/// Play icon shown on a poster on hover.
struct PlayOverlayButton: View {
    @Environment(AppModel.self) private var model
    let item: Movie
    var size: CGFloat = 44

    var body: some View {
        Button {
            model.play(item, fromStart: false)
        } label: {
            Image(systemName: item.resumeSeconds > 0 ? "play.circle.fill" : "play.fill")
                .font(.system(size: size))
                .foregroundStyle(.white)
                .shadow(radius: 8)
        }
        .buttonStyle(.plain)
        .help(model.isServerUnreachable ? "Server unreachable — streaming requires a connection"
              : (item.resumeSeconds > 0 ? "Resume playback" : item.playHelp))
        .accessibilityLabel(item.resumeSeconds > 0 ? "Resume \(item.name)" : "Play \(item.name)")
    }
}

/// Small "downloaded" badge shown on posters and thumbnails (everywhere).
struct DownloadedBadge: View {
    @Environment(AppModel.self) private var model
    let itemId: String

    var body: some View {
        if model.downloads.downloadedIds.contains(itemId) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white, Theme.Colors.accent)
                .background(Circle().fill(.black.opacity(0.35)).padding(1))
                .help("Downloaded: available offline")
                .accessibilityLabel("Downloaded")
        }
    }
}

/// Flow layout: elements side by side, wrapping to a new line when the width is full (genres, seasons).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        var height: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height = currentY + rowHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
