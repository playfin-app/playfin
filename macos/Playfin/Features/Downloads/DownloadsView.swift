import SwiftUI

/// Downloads screen (always reachable, even without a server): in progress, waiting, failures, then what
/// is available offline, sorted into Movies / Series / Audiobooks.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model

    private var downloads: DownloadsModel { model.downloads }
    private var inProgress: [DownloadInfo] { downloads.items.filter { $0.state == .downloading } }
    private var waiting: [DownloadInfo] { downloads.items.filter { $0.state == .queued || $0.state == .paused } }
    private var failed: [DownloadInfo] { downloads.items.filter { $0.state == .failed } }
    private var completed: [DownloadInfo] { downloads.items.filter { $0.state == .completed } }

    var body: some View {
        Group {
            if downloads.items.isEmpty {
                ErrorStateView(
                    title: "No downloads",
                    message: downloads.canDownload
                        ? "Download a movie, an episode or a season from its page to watch it without a connection."
                        : "The server administrator does not allow downloads for this account.",
                    systemImage: "arrow.down.circle"
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if !inProgress.isEmpty { section("In progress", items: inProgress) }
                        if !waiting.isEmpty { section("Waiting", items: waiting, reorderable: true) }
                        if !failed.isEmpty { section("Failed", items: failed) }
                        if !completed.isEmpty { completedSection }
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
        }
        .background(Theme.Colors.background)
        .onAppear { downloads.refresh() }
    }

    private func section(_ title: String, items: [DownloadInfo], reorderable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.bold())
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.itemId) { index, info in
                    DownloadRow(info: info, canMoveUp: reorderable && index > 0, canMoveDown: reorderable && index < items.count - 1)
                    if index < items.count - 1 { Divider().padding(.leading, 64) }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Colors.surface))
        }
    }

    private var completedSection: some View {
        let downloaded = downloads.downloadedItems()
        let movies = downloaded.filter { !$0.isAudio && $0.itemType != "Episode" }
        let audio = downloaded.filter(\.isAudio)
        let bySeries = Dictionary(grouping: downloaded.filter { $0.itemType == "Episode" }) { $0.seriesName ?? "Series" }
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("Available offline").font(.title2.bold())
                Text(ByteCountFormatter.string(fromByteCount: Int64(downloads.usedBytes), countStyle: .file))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if !movies.isEmpty { shelf("Movies", items: movies) }
            ForEach(bySeries.keys.sorted(), id: \.self) { series in
                let episodes = (bySeries[series] ?? []).sorted {
                    ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0) < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0)
                }
                shelf(series, items: episodes)
            }
            if !audio.isEmpty { shelf("Audiobooks", items: audio) }
        }
    }

    private func shelf(_ title: String, items: [Movie]) -> some View {
        Shelf(title: title, horizontalPadding: 0) {
            ForEach(items, id: \.id) { item in
                NavigationLink(value: Route.movie(item.id)) {
                    PosterCard(movie: item).frame(width: Theme.Layout.posterWidth)
                }
                .buttonStyle(CardButtonStyle())
                .contextMenu {
                    Button("Play", systemImage: "play.fill") { model.play(item) }
                    WatchedMenuItems(movie: item)
                    Divider()
                    Button("Delete download", systemImage: "trash", role: .destructive) {
                        downloads.remove(item.id)
                    }
                }
            }
        }
    }
}

/// A row of the queue: title, progress, speed, remaining time, connections and actions.
private struct DownloadRow: View {
    @Environment(AppModel.self) private var model
    let info: DownloadInfo
    var canMoveUp = false
    var canMoveDown = false

    private var downloads: DownloadsModel { model.downloads }

    var body: some View {
        HStack(spacing: 14) {
            DownloadProgressRing(fraction: info.fraction, state: info.state)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title).font(.headline).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(info.state == .failed ? Theme.Colors.error : .secondary).lineLimit(2)
                if info.state == .downloading || info.state == .paused {
                    ProgressView(value: info.fraction).tint(Theme.Colors.accent)
                }
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(info.totalBytes), countStyle: .file)
        let done = ByteCountFormatter.string(fromByteCount: Int64(info.downloadedBytes), countStyle: .file)
        switch info.state {
        case .downloading:
            var parts = ["\(done) of \(size)"]
            if info.bytesPerSecond > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(info.bytesPerSecond), countStyle: .file) + "/s")
            }
            if let eta = info.etaSeconds { parts.append("\(formatDuration(eta)) left") }
            parts.append(info.rangesSupported
                ? "\(info.connections) connection\(info.connections > 1 ? "s" : "")"
                : "1 connection (the server does not allow splitting)")
            return parts.joined(separator: " · ")
        case .queued: return info.totalBytes > 0 ? "Waiting · \(done) of \(size)" : "Waiting"
        case .paused: return "Paused · \(done) of \(size)"
        case .failed: return info.error ?? "Failed"
        case .completed: return size
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch info.state {
            case .downloading:
                iconButton("pause.fill", "Pause") { downloads.pause(info.itemId) }
            case .paused:
                iconButton("play.fill", "Resume") { downloads.resume(info.itemId) }
            case .failed:
                iconButton("arrow.clockwise", "Try again") { downloads.retry(info.itemId) }
            case .queued, .completed:
                EmptyView()
            }
            if canMoveUp || canMoveDown {
                iconButton("chevron.up", "Move up in the queue") {
                    moveBy(-1)
                }
                .disabled(!canMoveUp)
                iconButton("chevron.down", "Move down in the queue") {
                    moveBy(1)
                }
                .disabled(!canMoveDown)
            }
            iconButton("xmark", info.state == .completed ? "Delete" : "Cancel") { downloads.remove(info.itemId) }
        }
    }

    private func moveBy(_ offset: Int) {
        guard let index = downloads.items.firstIndex(where: { $0.itemId == info.itemId }) else { return }
        downloads.move(info.itemId, to: index + offset)
    }

    private func iconButton(_ systemImage: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.Colors.surface))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Progress ring of a download (or its state).
struct DownloadProgressRing: View {
    let fraction: Double
    let state: DownloadState

    var body: some View {
        ZStack {
            Circle().stroke(Theme.Colors.surface, lineWidth: 3)
            Circle()
                .trim(from: 0, to: state == .completed ? 1 : fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Theme.Motion.standard, value: fraction)
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch state {
        case .failed: return Theme.Colors.error
        case .completed: return Theme.Colors.reachable
        case .paused, .queued: return .secondary
        case .downloading: return Theme.Colors.accent
        }
    }

    private var icon: String {
        switch state {
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .paused: return "pause.fill"
        case .queued: return "clock"
        case .downloading: return "arrow.down"
        }
    }
}

/// "Download" button of a page: progress in place, downloaded state, and an explanation if the administrator
/// does not allow it. For a series or a season, adds all of its episodes.
struct DownloadButton: View {
    @Environment(AppModel.self) private var model
    let item: Movie
    var seasonId: String?

    private var downloads: DownloadsModel { model.downloads }
    private var info: DownloadInfo? { downloads.info(for: item.id) }

    /// A series asks what to download (this season or everything).
    @State private var isAskingSeriesScope = false

    private var isAvailable: Bool { downloads.canDownload && !model.isServerUnreachable }

    var body: some View {
        Group {
            if let info, !item.isSeries {
                DetailCircleButton(
                    systemName: info.state == .completed ? "checkmark.circle.fill" : "arrow.down.circle",
                    tint: info.state == .completed ? Theme.Colors.reachable : .white,
                    caption: info.state == .completed ? "Downloaded" : "\(Int(info.fraction * 100)) %",
                    help: info.state == .completed ? "Downloaded — click to delete" : "Download: \(Int(info.fraction * 100))%",
                    action: activate
                )
                // On the circle (at the top), not on circle + word.
                .overlay(alignment: .top) {
                    if info.state == .downloading || info.state == .queued {
                        DownloadProgressRing(fraction: info.fraction, state: info.state)
                            .frame(width: DetailCircleButton.diameter, height: DetailCircleButton.diameter)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                DetailCircleButton(
                    systemName: "arrow.down.circle",
                    caption: "Download",
                    help: downloads.canDownload ? "Download to watch offline" : forbiddenHelp,
                    action: activate
                )
                .disabled(!isAvailable)
            }
        }
        .confirmationDialog("Download \(item.name)", isPresented: $isAskingSeriesScope) {
            if let seasonId {
                Button("Download this season") { downloads.downloadSeries(item.id, seasonId: seasonId) }
            }
            Button("Download the whole series") { downloads.downloadSeries(item.id) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func activate() {
        if let info, !item.isSeries {
            if info.state == .completed { downloads.remove(item.id) } else if info.state == .failed { downloads.retry(item.id) }
            return
        }
        guard isAvailable else { return }
        if item.isSeries { isAskingSeriesScope = true } else { downloads.download([item]) }
    }

    private var forbiddenHelp: String {
        "The server administrator does not allow downloads for this account."
    }
}

func formatDuration(_ seconds: UInt64) -> String {
    if seconds >= 3600 { return "\(seconds / 3600) h \((seconds % 3600) / 60) min" }
    if seconds >= 60 { return "\(seconds / 60) min" }
    return "\(seconds) s"
}
