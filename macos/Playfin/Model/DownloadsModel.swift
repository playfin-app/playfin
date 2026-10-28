import Foundation
import Observation
import os

/// Downloads of the open profile: queue, progress (read at most 4 times per second), items available
/// offline and pending playback reports. The work (HTTP, files, database) is done by the core.
@MainActor
@Observable
final class DownloadsModel {
    private(set) var items: [DownloadInfo] = []
    /// Complete items: badge on posters, playback from disk.
    private(set) var downloadedIds: Set<String> = []
    /// Saved images of the downloaded items: identifier → (type → path).
    private(set) var localAssets: [String: [String: String]] = [:]
    /// Does the administrator allow downloads for this account?
    private(set) var canDownload = true
    private(set) var usedBytes: UInt64 = 0
    /// Items in the list, whatever their state, and the number still to download. Kept apart from `items`
    /// (which changes with each progress read): the posters and the sidebar read these, and are only
    /// redrawn when the list changes, not 4 times per second during a download.
    private(set) var listedIds: Set<String> = []
    private(set) var activeCount = 0

    @ObservationIgnored private(set) var manager: DownloadManager?
    @ObservationIgnored private var managers: [String: DownloadManager] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.playfin.app", category: "Downloads")

    func info(for itemId: String) -> DownloadInfo? { items.first { $0.itemId == itemId } }

    /// Default root folder: ~/Movies/Playfin, changeable in the settings.
    static func defaultRoot() -> URL {
        if AppPaths.isRunningTests { return AppPaths.testRoot.appendingPathComponent("Downloads", isDirectory: true) }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Playfin", isDirectory: true)
    }

    static func downloadSettings(from settings: AppSettings, serverName: String) -> DownloadSettings {
        DownloadSettings(
            root: settings.downloadFolder.isEmpty ? defaultRoot().path : settings.downloadFolder,
            serverName: serverName.isEmpty ? "Jellyfin" : serverName,
            connections: settings.downloadConnections,
            maxConcurrent: settings.downloadConcurrent,
            bandwidthLimitKbps: settings.downloadBandwidthKbps,
            retryAttempts: settings.downloadRetries,
            retryBaseDelayMs: 1000,
            subtitleMode: settings.downloadSubtitles,
            preferredLanguages: TrackGrouping.preferredLanguages(
                setting: settings.subtitleLanguage, system: PlayerOptions.systemLanguageCodes()
            )
        )
    }

    /// Opens (or finds again) the profile's manager: one profile = one database. Downloads of another profile
    /// continue in the background and reappear when one comes back.
    func open(client: JellyfinClient, session: SessionInfo, serverName: String, settings: AppSettings) {
        let key = SessionStore.accountKey(serverId: session.serverId, userId: session.userId)
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        let dir = AppPaths.supportDirectory.appendingPathComponent("downloads/\(String(safe))", isDirectory: true)
        if let existing = managers[key] {
            manager = existing
        } else {
            do {
                let created = try DownloadManager(
                    client: client, dbDir: dir.path,
                    settings: Self.downloadSettings(from: settings, serverName: serverName)
                )
                managers[key] = created
                manager = created
                Task { await created.resumeAll() }
            } catch {
                logger.error("Downloads unavailable: \(error.localizedDescription, privacy: .private)")
                manager = nil
            }
        }
        refresh()
        Task { [weak self] in
            if let allowed = try? await client.canDownload() { self?.canDownload = allowed }
        }
    }

    func close() {
        pollTask?.cancel()
        pollTask = nil
        manager = nil
        items = []
        listedIds = []
        activeCount = 0
        downloadedIds = []
        localAssets = [:]
    }

    func apply(settings: AppSettings, serverName: String) {
        guard let manager else { return }
        let values = Self.downloadSettings(from: settings, serverName: serverName)
        Task { await manager.updateSettings(settings: values) }
    }

    /// Reads the state again. As long as a download is active, reads 4 times per second (no more).
    func refresh() {
        guard let manager else { return }
        let snapshot = manager.snapshot()
        if snapshot != items { items = snapshot }
        let listed = Set(snapshot.map(\.itemId))
        if listed != listedIds { listedIds = listed }
        let active = snapshot.filter { $0.state == .downloading || $0.state == .queued }.count
        if active != activeCount { activeCount = active }
        let completed = Set(snapshot.filter { $0.state == .completed }.map(\.itemId))
        if completed != downloadedIds {
            downloadedIds = completed
            var assets: [String: [String: String]] = [:]
            for id in completed {
                var kinds: [String: String] = [:]
                for kind in ["poster", "backdrop"] {
                    if let path = manager.localAsset(itemId: id, kind: kind) { kinds[kind] = path }
                }
                assets[id] = kinds
            }
            localAssets = assets
            usedBytes = manager.usedBytes()
        }
        let busy = snapshot.contains { $0.state == .downloading || $0.state == .queued }
        if busy, pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self else { return }
                    self.refresh()
                    if !self.items.contains(where: { $0.state == .downloading || $0.state == .queued }) {
                        self.pollTask = nil
                        return
                    }
                }
            }
        }
    }

    // MARK: Actions

    func download(_ items: [Movie]) {
        guard let manager, !items.isEmpty else { return }
        Task {
            _ = try? await manager.enqueue(items: items)
            refresh()
        }
    }

    func downloadSeries(_ seriesId: String, seasonId: String? = nil) {
        guard let manager else { return }
        Task {
            _ = try? await manager.enqueueSeries(seriesId: seriesId, seasonId: seasonId)
            refresh()
        }
    }

    func pause(_ id: String) { run { await $0.pause(itemId: id) } }
    func resume(_ id: String) { run { await $0.resume(itemId: id) } }
    func retry(_ id: String) { run { await $0.retry(itemId: id) } }
    func remove(_ id: String) { run { await $0.remove(itemId: id) } }
    func move(_ id: String, to index: Int) { run { await $0.moveTo(itemId: id, index: UInt32(max(0, index))) } }

    private func run(_ action: @escaping @Sendable (DownloadManager) async -> Void) {
        guard let manager else { return }
        Task {
            await action(manager)
            refresh()
        }
    }

    // MARK: Offline playback

    func localFile(for itemId: String) -> String? {
        guard downloadedIds.contains(itemId) else { return nil }
        return manager?.localFile(itemId: itemId)
    }

    func localSubtitles(for itemId: String) -> [ExternalSubtitle] {
        manager?.localSubtitles(itemId: itemId) ?? []
    }

    func downloadedItems() -> [Movie] {
        manager?.downloadedItems() ?? []
    }

    func queueReport(itemId: String, kind: String, ticks: Int64) {
        manager?.queueReport(itemId: itemId, kind: kind, positionTicks: ticks)
    }

    /// Sends the reports made offline (conflict rule applied by the core).
    func flushReports() async {
        guard let manager, manager.pendingReportCount() > 0 else { return }
        do {
            let sent = try await manager.flushReports()
            logger.info("Offline reports sent: \(sent)")
        } catch {
            logger.error("Offline reports not sent: \(error.localizedDescription, privacy: .private)")
        }
    }
}

extension DownloadInfo {
    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }
}
