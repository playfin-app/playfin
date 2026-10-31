import Foundation
import os

/// Launch, sign-in, Quick Connect, profile saving, sign-out and session opening.
extension AppModel {

    // MARK: Sign-in

    /// At launch: reuses the saved session if there is one.
    nonisolated static func normalizeURL(_ url: String) -> String {
        normalizeUrl(url: url)
    }

    func start() async {
        isAddingProfile = false
        loginPrefillServer = nil
        // At launch, we open the primary profile (if connected); afterwards, the session chosen by the user.
        let allProfiles = (try? ProfileStore.loadAll()) ?? []
        if !hasLaunched {
            hasLaunched = true
            if let primary = allProfiles.first(where: \.isPrimary) {
                SessionStore.setActive(serverId: primary.serverId, userId: primary.userId)
            }
        }
        profiles = allProfiles
        guard let saved = SessionStore.load() else {
            screen = .login
            return
        }
        Self.rememberServer(saved.serverUrl)
        DeviceIdentity.sync(cacheDir: URL(fileURLWithPath: Self.cacheDirectory))
        let client = JellyfinClient.restore(info: saved, cacheDir: Self.cacheDirectory)
        var profile = allProfiles.first { $0.serverId == saved.serverId && $0.userId == saved.userId }
        if profile == nil {
            // Session without a profile (profile file lost or old version): we recreate it, otherwise the server
            // does not appear in the settings and an address cannot be added to it.
            profile = recreateProfile(for: saved, existing: allProfiles)
        }

        // Immediate rendering from the cache (without blocking the UI). Then: forced address, otherwise choice of the best
        // address before the first network request if the server has several.
        var chooser: (() async -> Void)?
        if let profile, let forced = profile.forcedAddress, !forced.isEmpty {
            chooser = { [weak self] in
                client.setServerUrl(newUrl: forced)
                self?.rememberChosenAddress(forced)
            }
        } else if let profile, profile.addresses.count > 1 {
            chooser = { [weak self] in
                if let best = try? await client.autoSelectAddress(addresses: profile.addresses, expectedServerId: profile.serverId) {
                    self?.rememberChosenAddress(best.url)
                }
            }
        }
        Task {
            await openSession(client, chooseAddress: chooser)
            await refreshAvatar()
        }
    }

    /// Recreates the profile of an open session that no longer has one. The server name is completed as soon as it answers.
    @discardableResult
    func recreateProfile(for session: SessionInfo, existing: [ServerProfile]) -> ServerProfile? {
        let url = Self.normalizeURL(session.serverUrl)
        let local = checkIsLocalAddress(url: url)
        let sameServer = existing.first { $0.serverId == session.serverId }
        let profile = ServerProfile(
            serverId: session.serverId,
            serverName: sameServer?.serverName ?? "Jellyfin",
            userId: session.userId,
            userName: lastLoggedInUsername.isEmpty ? "User" : lastLoggedInUsername,
            userAvatarTag: nil,
            addresses: sameServer?.addresses
                ?? [ServerAddress(url: url, label: local ? "Home" : "Remote", priority: 1, isLocal: local)],
            isPrimary: !existing.contains(where: \.isPrimary),
            forcedAddress: sameServer?.forcedAddress
        )
        do {
            try ProfileStore.saveProfile(profile)
        } catch {
            logger.error("Could not recreate the profile: \(error.localizedDescription, privacy: .private)")
            return nil
        }
        refreshProfiles()
        Task { [weak self] in await self?.completeRecreatedProfile(serverId: session.serverId, url: url) }
        return profile
    }

    /// Completes the server name (and the user's) of a recreated profile.
    private func completeRecreatedProfile(serverId: String, url: String) async {
        let name = (try? await validateServer(url: url))?.serverName
        let user = try? await client?.currentUser()
        var all = (try? ProfileStore.loadAll()) ?? []
        for index in all.indices where all[index].serverId == serverId {
            if let name, all[index].serverName == "Jellyfin" { all[index].serverName = name }
            if let user, all[index].userId == user.id, all[index].userName == "User" { all[index].userName = user.name }
        }
        try? ProfileStore.saveAll(all)
        refreshProfiles()
    }

    private func rememberChosenAddress(_ url: String) {
        Self.rememberServer(url)
    }

    func login(server: String, username: String, password: String) async -> Bool {
        loginError = nil
        let cleanServer = Self.normalizeURL(server)
        Self.rememberServer(cleanServer)
        DeviceIdentity.sync(cacheDir: URL(fileURLWithPath: Self.cacheDirectory))
        let client = JellyfinClient(serverUrl: cleanServer, cacheDir: Self.cacheDirectory)
        DeviceIdentity.sync(cacheDir: URL(fileURLWithPath: Self.cacheDirectory))
        do {
            try await client.login(username: username, password: password)
        } catch {
            loginError = message(for: error)
            return false
        }
        if let info = client.sessionInfo() {
            SessionStore.save(info)
            lastLoggedInUsername = username
            saveProfileAfterLogin(info: info, username: username)
        }
        await openSession(client)
        return true
    }

    /// Starts the Quick Connect flow and returns the initial state (6-digit code and secret).
    func initiateQuickConnect(server: String) async throws -> (JellyfinClient, QuickConnectState) {
        loginError = nil
        let cleanServer = Self.normalizeURL(server)
        Self.rememberServer(cleanServer)
        DeviceIdentity.sync(cacheDir: URL(fileURLWithPath: Self.cacheDirectory))
        let client = JellyfinClient(serverUrl: cleanServer, cacheDir: Self.cacheDirectory)
        DeviceIdentity.sync(cacheDir: URL(fileURLWithPath: Self.cacheDirectory))
        let state = try await client.quickConnectInitiate()
        return (client, state)
    }

    enum QuickConnectPollOutcome: Equatable { case finished, timedOut, failed, cancelled }

    /// Polls the server until the Quick Connect code is approved.
    /// Stops on cancellation, definitive error (unknown code, access denied) or after `timeout`.
    /// `sleep` is injectable to test without waiting.
    func runQuickConnectPolling(
        client: JellyfinClient,
        secret: String,
        interval: Duration = .seconds(2.5),
        timeout: Duration = .seconds(15 * 60),
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> QuickConnectPollOutcome {
        var elapsed = Duration.zero
        while elapsed < timeout {
            do {
                try await sleep(interval)
            } catch {
                return .cancelled
            }
            elapsed += interval
            if Task.isCancelled { return .cancelled }
            do {
                if try await pollAndFinishQuickConnect(client: client, secret: secret) { return .finished }
            } catch is CancellationError {
                return .cancelled
            } catch let error as JellyfinError {
                switch error {
                case .Network, .ServerUnreachable:
                    continue // transient network error: try again on the next round
                default:
                    // Unknown code, access denied, server error, unreadable response: no point continuing.
                    loginError = "The Quick Connect code is no longer valid. Try again."
                    return .failed
                }
            } catch {
                continue
            }
        }
        loginError = "The Quick Connect code has expired. Try again."
        return .timedOut
    }

    /// Asks the server whether the code was authorised, and completes the sign-in if so.
    func pollAndFinishQuickConnect(client: JellyfinClient, secret: String) async throws -> Bool {
        let isAuth = try await client.quickConnectPoll(secret: secret)
        guard isAuth else { return false }
        let userName = try await client.quickConnectAuthenticate(secret: secret)
        if let info = client.sessionInfo() {
            SessionStore.save(info)
            Self.rememberServer(info.serverUrl)
            lastLoggedInUsername = userName
            saveProfileAfterLogin(info: info, username: userName)
        }
        await openSession(client)
        return true
    }

    func saveProfileAfterLogin(info: SessionInfo, username: String) {
        let cleanUrl = Self.normalizeURL(info.serverUrl)
        let isLocal = checkIsLocalAddress(url: cleanUrl)
        let addr = ServerAddress(
            url: cleanUrl,
            label: isLocal ? "Home" : "Remote",
            priority: isLocal ? 1 : 2,
            isLocal: isLocal
        )
        do {
            let allProfiles = try ProfileStore.loadAll()
            let sameServer = allProfiles.first { $0.serverId == info.serverId }
            if let existing = allProfiles.first(where: { $0.serverId == info.serverId && $0.userId == info.userId }) {
                var updatedAddresses = existing.addresses
                if !updatedAddresses.contains(where: { Self.normalizeURL($0.url) == cleanUrl }) {
                    updatedAddresses.append(addr)
                }
                var updated = existing
                updated.serverName = existing.serverName.isEmpty || existing.serverName == "Jellyfin"
                    ? (validatedServerNames[info.serverId] ?? "Jellyfin") : existing.serverName
                updated.userName = username
                updated.addresses = updatedAddresses
                try ProfileStore.saveProfile(updated)
                promptSecondaryAddress = updatedAddresses.count == 1 && !Self.isSecondaryPromptDismissed(serverId: info.serverId)
            } else {
                // A second user of the same server takes over the addresses already configured; they do not become
                // the primary profile (the one that opens at launch), unless they are the very first.
                let profile = ServerProfile(
                    serverId: info.serverId,
                    serverName: sameServer?.serverName ?? validatedServerNames[info.serverId] ?? "Jellyfin",
                    userId: info.userId,
                    userName: username,
                    userAvatarTag: nil,
                    addresses: sameServer?.addresses ?? [addr],
                    isPrimary: allProfiles.isEmpty,
                    forcedAddress: sameServer?.forcedAddress
                )
                try ProfileStore.saveProfile(profile)
                promptSecondaryAddress = sameServer == nil && !Self.isSecondaryPromptDismissed(serverId: info.serverId)
            }
            refreshProfiles()
        } catch let err as JellyfinError {
            logger.error("Error persisting the user profile: \(err.localizedDescription, privacy: .private)")
            switch err {
            case .Decode:
                corruptProfileStorageError = true
            default:
                offlineAlertMessage = "Warning: could not save the profile locally."
            }
        } catch {
            logger.error("Error persisting the user profile: \(error.localizedDescription, privacy: .private)")
            offlineAlertMessage = "Warning: could not save the profile locally."
        }
    }

    /// Resets the corrupted profile storage after confirmation and recreates the active profile if connected.
    func repairCorruptProfileStorage(username: String? = nil) throws {
        try ProfileStore.resetCorruptStorage()
        corruptProfileStorageError = false
        offlineAlertMessage = nil
        if let info = client?.sessionInfo() {
            let resolvedUser: String
            if let username, !username.isEmpty {
                resolvedUser = username
            } else if !lastLoggedInUsername.isEmpty {
                resolvedUser = lastLoggedInUsername
            } else {
                resolvedUser = "User"
            }
            saveProfileAfterLogin(info: info, username: resolvedUser)
        }
    }

    /// Adds a secondary address (local or remote) to the active profile after verification by the Rust core.
    func addSecondaryAddress(url: String, label: String) async throws {
        guard let info = client?.sessionInfo() else { return }
        let cleanUrl = Self.normalizeURL(url)
        let isLocal = checkIsLocalAddress(url: cleanUrl)
        let newAddr = ServerAddress(
            url: cleanUrl,
            label: label.isEmpty ? (isLocal ? "Home" : "Remote") : label,
            priority: isLocal ? 1 : 2,
            isLocal: isLocal
        )
        _ = try await ProfileStore.verifyAndAddAddress(toServerId: info.serverId, address: newAddr, timeoutMs: 3000)
        promptSecondaryAddress = false
    }

    private static func secondaryPromptKey(_ serverId: String) -> String { "Playfin_SecondaryPromptDismissed_\(serverId)" }

    static func isSecondaryPromptDismissed(serverId: String) -> Bool {
        userDefaults.bool(forKey: secondaryPromptKey(serverId))
    }

    /// "Later": we do not ask for the second address again at every sign-in.
    func dismissSecondaryAddressPrompt() {
        promptSecondaryAddress = false
        if let serverId = client?.sessionInfo()?.serverId {
            Self.userDefaults.set(true, forKey: Self.secondaryPromptKey(serverId))
        }
    }

    /// Opens the add-address sheet on demand (menu), even if "Later" was chosen at sign-in.
    func showAddAddress() {
        guard screen == .library, client != nil else { return }
        promptSecondaryAddress = true
    }

    func logout() {
        let client = self.client
        Task { try? await client?.logout() } // also clears the cache
        SessionStore.delete()
        lastLoggedInUsername = ""
        reset()
        screen = .login
    }

    /// Shows the app as fast as possible: first the cache (instant), then the server.
    /// `chooseAddress`: probes the server addresses BEFORE the first request, so as not to query an
    /// old dead address (which would show the offline banner wrongly or after a long delay).
    private func openSession(_ client: JellyfinClient, chooseAddress: (() async -> Void)? = nil) async {
        self.client = client
        openDownloads(for: client)

        let cached = await client.cachedHome()
        guard self.client === client else { return } // signed out in the meantime
        if !cached.resume.isEmpty || !cached.nextUp.isEmpty || !cached.latest.isEmpty {
            setHome(cached)
            screen = .library
        }

        await chooseAddress?()
        guard self.client === client else { return }

        do {
            let home = try await client.home()
            guard self.client === client else { return }
            setHome(home)
            isServerUnreachable = false
            stopBackgroundProber()
            screen = .library
            Task { await downloads.flushReports() }
            // The server answers at the right address: the banner titles can be picked now. If that fails too,
            // the banner stops waiting and shows the titles in progress.
            Task {
                if featured.isEmpty { await loadFeatured() }
                guard self.client === client else { return }
                isChoosingFeatured = false
            }
        } catch {
            guard self.client === client else { return }
            if isSessionExpired(error) {
                // Token expired or refused: back to sign-in.
                fail(error)
                return
            }
            // Network drop: offline mode with banner. Other error (server, format): message, no banner.
            _ = handleAsyncOperationError(error, for: client) {
                isServerUnreachable = true
                startBackgroundProber()
                return .offline
            }
            // No new banner titles without the server: the titles in progress meanwhile.
            isChoosingFeatured = false
            screen = .library
        }

        // Libraries and media load while the home is already usable
        Task {
            await loadLibraries(client)
        }
        Task { await loadCachedMovies(client) }
    }

    func reset() {
        stopBackgroundProber()
        downloads.close()
        latestByLibrary = []
        activeAvatarURL = nil
        isServerUnreachable = false
        isRetryingConnection = false
        offlineAlertMessage = nil
        corruptProfileStorageError = false
        lastLoggedInUsername = ""
        client = nil
        movies = []
        libraries = []
        selectedLibraryId = nil
        loadedLibraryId = nil
        libraryLoadedAt = nil
        moviesLoadedAt = nil
        librarySort = ("SortName", "Ascending")
        libraryItems = []
        libraryTotalCount = 0
        isLoadingLibrary = false
        isLoadingMoreLibraryItems = false
        resume = []
        nextUp = []
        latest = []
        favorites = []
        featured = []
        isChoosingFeatured = true
        gridCache = [:]
        known = [:]
        playback = nil
        pendingSubtitles = []
        selectedSection = .home
        selectedGenreFilter = nil
        promptSecondaryAddress = false
    }

    /// Back to sign-in with a message. A refused token is forgotten, along with its cache.
    func fail(_ error: Error) {
        if isSessionExpired(error) {
            client?.clearCache()
            SessionStore.delete()
        }
        loginError = message(for: error)
        reset()
        screen = .login
    }

    func isSessionExpired(_ error: Error) -> Bool {
        if let jErr = error as? JellyfinError, case .Unauthorized = jErr {
            return true
        }
        return false
    }

    // MARK: - Discovery & Addresses

    /// Looks for the Jellyfin servers available on the local network.
    func scanLocalServers(timeoutMs: UInt64 = 1500) async -> [DiscoveredServer] {
        (try? await discoverServers(timeoutMs: timeoutMs)) ?? []
    }

    /// Validates a server URL and returns its public information (Id, Name, Version >= 10.9).
    func validateServerURL(_ url: String) async throws -> ServerPublicInfo {
        let clean = Self.normalizeURL(url)
        let info = try await validateServer(url: clean)
        validatedServerNames[info.id] = info.serverName
        return info
    }
}
