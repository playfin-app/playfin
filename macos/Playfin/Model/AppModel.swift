import Foundation
import Network
import Observation
import os

/// Global state of the app. The views read these values and update by themselves.
///
/// This file only holds the state. The behaviour is split by topic:
/// - `AppModel+Session`: launch, sign-in, Quick Connect, sign-out
/// - `AppModel+Connectivity`: network changes, offline mode, reconnection
/// - `AppModel+Library`: libraries, seasons, episodes, refresh
/// - `AppModel+Items`: known items, details, watched state, search, image URLs
/// - `AppModel+Playback`: starting playback, next episode, progress reports
/// - `AppModel+Profiles`: profile switcher and addresses
///
/// Properties written by the extensions cannot be `private` (Swift limits `private` to one file).
@MainActor
@Observable
final class AppModel {
    enum Screen: Equatable { case loading, login, library }

    enum SidebarSection: Hashable {
        case home
        case movies
        case library(String)
        case search
        case favorites
        case downloads
    }

    enum ProbeResult {
        case recovered
        case offline
        case terminal
    }

    var screen: Screen = .loading
    var selectedSection: SidebarSection = .home
    /// Incremented each time a section is chosen, even the one already shown: the main view then closes
    /// the pages opened in it and shows its first page.
    private(set) var sectionRootRequests = 0
    /// Incremented by the "Back" menu item: the main view closes the current page.
    private(set) var goBackRequests = 0
    /// Page asked by a link (`RouteLink`): the main view opens it in the visible section.
    private(set) var requestedRoute: Route?
    private(set) var openRequests = 0
    var selectedGenreFilter: String? = nil
    var client: JellyfinClient?
    var movies: [Movie] = [] { didSet { moviesRevision &+= 1 } }
    /// Counters incremented on every change to the lists: cheap keys to recompute the display.
    private(set) var moviesRevision = 0
    private(set) var libraryRevision = 0
    /// Dynamic libraries discovered on the Jellyfin server.
    var libraries: [UserView] = []
    var selectedLibraryId: String? = nil
    var currentLibrary: UserView? {
        if let selectedLibraryId {
            return libraries.first { $0.id == selectedLibraryId }
        }
        return libraries.first
    }
    /// Items of the library being browsed (paged).
    var libraryItems: [Movie] = [] { didSet { libraryRevision &+= 1 } }
    var libraryLoadGeneration = 0
    /// Library whose items are in `libraryItems` (differs from `selectedLibraryId` as long as nothing is loaded).
    var loadedLibraryId: String?
    /// Sort of the displayed list, so that "Refresh" keeps it.
    var librarySort: (sortBy: String, sortOrder: String) = ("SortName", "Ascending")
    var libraryLoadedAt: Date?
    /// How long an already loaded library is not downloaded again.
    static let libraryFreshness: TimeInterval = 300
    var moviesLoadedAt: Date?
    var libraryTotalCount: UInt32 = 0
    var isLoadingLibrary = false
    /// Message shown when the library cannot be loaded and no saved copy exists.
    var libraryLoadError: String?
    var isLoadingMoreLibraryItems = false

    /// Movies in progress (home).
    var resume: [Movie] = []
    /// Next episodes to watch (home).
    var nextUp: [Movie] = []
    /// Recently added movies (home).
    var latest: [Movie] = []
    /// The user's favourites (home row).
    var favorites: [Movie] = []
    /// Last grid shown per library ("movies" for the Movies grid). The grids are built again in the background on
    /// each visit: showing this one meanwhile avoids a blank frame (a flicker) before the posters appear.
    @ObservationIgnored var gridCache: [String: CachedGrid] = [:]
    struct CachedGrid { let query: GridQuery; let content: GridContent }
    /// "Recently added in …": one row per library.
    struct LibraryLatest { let library: UserView; let items: [Movie] }
    var latestByLibrary: [LibraryLatest] = []
    var isLoadingMovies = false
    /// True while we look for what to play in a series or a folder.
    var isResolvingPlayback = false
    /// Application settings (see `SettingsModel`).
    let settings = SettingsModel()
    /// Downloads of the open profile (see `DownloadsModel`).
    let downloads = DownloadsModel()
    var playback: Playback?
    var pendingSubtitles: [ExternalSubtitle] = []
    /// Passages spotted by the server (intro, credits) of the current playback.
    var playbackSegments: [MediaSegment] = []
    /// Episode that follows the one playing ("Next episode" card and automatic playback).
    var upNext: Movie?
    /// Episode before the one playing (button and P key of the player).
    var previousEpisode: Movie?
    var loginError: String?
    var promptSecondaryAddress = false
    var showShortcutsHelp = false

    /// Known profiles (one per server and user), their connection state and the requested add page.
    var profiles: [ServerProfile] = []
    var profileStatuses: [String: ProfileStatus] = [:]
    /// When a user is added to an already known server, the sign-in screen starts on this address.
    var loginPrefillServer: String?
    var isAddingProfile = false
    var hasLaunched = false
    var activeAvatarURL: URL?

    /// Offline state and server connectivity.
    var isServerUnreachable = false
    var isRetryingConnection = false
    var offlineAlertMessage: String?
    var corruptProfileStorageError = false
    var lastLoggedInUsername: String = ""
    var proberTask: Task<Void, Never>?
    let proberBackoff = ProberBackoff.newDefault()
    let logger = Logger(subsystem: "com.playfin.app", category: "AppModel")

    #if DEBUG
    var onProbeErrorCaught: ((Error) -> Void)?
    #endif

    init() {
        setupNetworkMonitor()
    }

    // MARK: Internal state used by the extensions

    var networkDebounceTask: Task<Void, Never>?
    var lastNetworkSignature: String?

    /// Every movie seen in a list, found again by its identifier.
    /// The most recently received from the server replaces the old one: pages therefore always show the up-to-date version.
    var known: [String: Movie] = [:]

    /// Server names obtained at validation, by server identifier (to name the profile created afterwards).
    var validatedServerNames: [String: String] = [:]

    /// File descriptions already read (one request per item and per session).
    @ObservationIgnored var mediaInfoCache: [String: MediaInfo] = [:]

    /// Version of the Rust core (UniFFI).
    var rustCoreVersion: String {
        coreVersion()
    }

    /// Host or name of the Jellyfin server for the sidebar.
    var serverHost: String {
        guard let raw = client?.serverUrl(), let url = URL(string: raw) else { return "Jellyfin" }
        return url.host ?? raw
    }

    func movie(id: String) -> Movie? { known[id] }

    /// Shows the first page of a section (sidebar click, menu shortcut), even if it is already selected.
    func showSection(_ section: SidebarSection) {
        selectedSection = section
        sectionRootRequests &+= 1
    }

    func requestGoBack() {
        goBackRequests &+= 1
    }

    func openPage(_ route: Route) {
        requestedRoute = route
        openRequests &+= 1
    }

    /// The movies featured at the top of the home: first those in progress, then the new releases.
    var heroMovies: [Movie] {
        var seen = Set<String>()
        let candidates: [Movie] = Array(resume.prefix(3)) + Array(nextUp.prefix(2)) + latest
        return Array(candidates.filter { seen.insert($0.id).inserted }.prefix(5))
    }

    /// Disk cache folder (the system may empty it: this is only a convenience).
    static let cacheDirectory: String = AppPaths.cachesDirectory.path

    private static let lastServerKey = "Playfin_LastServerURL"
    static var userDefaults: UserDefaults = AppPaths.defaults

    static func setUserDefaults(_ defaults: UserDefaults) {
        userDefaults = defaults
    }

    static var defaultServer: String {
        userDefaults.string(forKey: lastServerKey) ?? ""
    }

    static func rememberServer(_ url: String) {
        userDefaults.set(url, forKey: lastServerKey)
    }

    func diagnosticsReport() -> String {
        let profiles = (try? ProfileStore.loadAll()) ?? []
        var seen = Set<String>()
        let servers = profiles.filter { seen.insert($0.serverId).inserted }.map { profile in
            DiagnosticsReport.ServerLine(
                name: profile.serverName,
                addressCount: profile.addresses.count,
                activeAddressLabel: profile.addresses.first { Self.normalizeURL($0.url) == Self.normalizeURL(client?.serverUrl() ?? "") }?.label
            )
        }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        return DiagnosticsReport.build(
            appVersion: version, coreVersion: rustCoreVersion,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            servers: servers, settings: settings.values, logs: DiagnosticsReport.recentLogs()
        )
    }

    // MARK: Utilities

    func message(for error: Error) -> String {
        if let jErr = error as? JellyfinError {
            switch jErr {
            case .Network(let msg),
                 .ServerUnreachable(let msg),
                 .NotLoggedIn(let msg),
                 .Unauthorized(let msg),
                 .Forbidden(let msg),
                 .ServerError(let msg),
                 .NotFound(let msg),
                 .UnsupportedServerVersion(let msg),
                 .Decode(let msg),
                 .Cache(let msg),
                 .InvalidInput(let msg),
                 .ServerMismatch(let msg),
                 .Storage(let msg):
                return msg
            }
        }
        return error.localizedDescription
    }
}
