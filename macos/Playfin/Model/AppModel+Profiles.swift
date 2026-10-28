import Foundation

/// Connection state of a profile, shown by a colour dot in the switcher.
enum ProfileStatus: Equatable {
    case checking
    case reachable(addressLabel: String)
    case unreachable
}

extension ServerProfile: Identifiable {
    /// One profile = one server + one user.
    public var id: String { SessionStore.accountKey(serverId: serverId, userId: userId) }

    /// Initials for the avatar when the user has no photo.
    var initials: String {
        let parts = userName.split(separator: " ").prefix(2).compactMap(\.first)
        let text = parts.isEmpty ? String(userName.prefix(1)) : String(parts)
        return text.uppercased()
    }
}

extension AppModel {
    /// Key of the active profile (the one whose session is open).
    var activeProfileKey: String? {
        client?.sessionInfo().map { SessionStore.accountKey(serverId: $0.serverId, userId: $0.userId) }
    }

    var activeProfile: ServerProfile? {
        profiles.first { $0.id == activeProfileKey }
    }

    /// Label of the address currently in use ("Home", "Remote"…).
    var activeAddressLabel: String? {
        guard let url = client?.serverUrl() else { return nil }
        return activeProfile?.addresses.first { Self.normalizeURL($0.url) == Self.normalizeURL(url) }?.label
    }

    func refreshProfiles() {
        profiles = (try? ProfileStore.loadAll()) ?? []
    }

    // MARK: Switching profile

    /// Opens another profile: its home shows at once from its cache, then refreshes.
    /// Without a saved token, we ask to sign in again to this server.
    func switchProfile(_ profile: ServerProfile) {
        guard profile.id != activeProfileKey else { return }
        guard SessionStore.setActive(serverId: profile.serverId, userId: profile.userId) else {
            beginAddUser(toServerOf: profile)
            return
        }
        reset()
        selectedSection = .home
        screen = .loading // the loading screen reopens the active session (see `start()`)
    }

    /// Profile number `index` (0 = first) in menu order, for the ⌃⌘1 to ⌃⌘9 shortcuts.
    func switchProfile(atMenuIndex index: Int) {
        guard profiles.indices.contains(index) else { return }
        switchProfile(profiles[index])
    }

    // MARK: Adding a server or a user

    func beginAddServer() {
        loginPrefillServer = nil
        isAddingProfile = true
        screen = .login
    }

    func beginAddUser(toServerOf profile: ServerProfile) {
        loginPrefillServer = profile.forcedAddress
            ?? profile.addresses.sorted { $0.priority < $1.priority }.first?.url
        isAddingProfile = true
        screen = .login
    }

    /// Abandons the addition and goes back to the profile that was open.
    func cancelAddProfile() {
        guard SessionStore.load() != nil else { return }
        reset()
        screen = .loading
    }

    // MARK: Server status

    /// Probes the addresses of each profile in parallel (once per server) for the colour dots.
    func refreshProfileStatuses() async {
        refreshProfiles()
        let byServer = Dictionary(grouping: profiles, by: \.serverId)
        for profile in profiles { profileStatuses[profile.id] = .checking }
        await withTaskGroup(of: (String, ProfileStatus).self) { group in
            for (serverId, members) in byServer {
                guard let first = members.first else { continue }
                group.addTask {
                    let candidates = first.forcedAddress.map { forced in first.addresses.filter { $0.url == forced } } ?? first.addresses
                    guard let best = try? await selectBestAddress(
                        addresses: candidates.isEmpty ? first.addresses : candidates, expectedServerId: serverId
                    ) else { return (serverId, .unreachable) }
                    return (serverId, .reachable(addressLabel: best.label))
                }
            }
            for await (serverId, status) in group {
                for member in byServer[serverId] ?? [] { profileStatuses[member.id] = status }
            }
        }
    }

    // MARK: Managing profiles

    func setPrimary(_ profile: ServerProfile) {
        var updated = profile
        updated.isPrimary = true
        try? ProfileStore.saveProfile(updated) // the core removes the primary status from the others
        refreshProfiles()
    }

    /// Signs a profile out: token deleted, profile removed from the list. If it was open, we switch to another connected
    /// profile, otherwise to the sign-in screen.
    func signOut(_ profile: ServerProfile) {
        let wasActive = profile.id == activeProfileKey
        let session = SessionStore.load(serverId: profile.serverId, userId: profile.userId)
        if wasActive {
            let active = client
            Task { try? await active?.logout() } // also clears the cache of this profile
        } else if let session {
            let temporary = JellyfinClient.restore(info: session, cacheDir: Self.cacheDirectory)
            Task { try? await temporary.logout() }
        }
        SessionStore.delete(serverId: profile.serverId, userId: profile.userId)

        var remaining = ((try? ProfileStore.loadAll()) ?? []).filter { $0.id != profile.id }
        if !remaining.isEmpty, !remaining.contains(where: \.isPrimary) { remaining[0].isPrimary = true }
        try? ProfileStore.saveAll(remaining)
        profiles = remaining
        profileStatuses[profile.id] = nil

        guard wasActive else { return }
        reset()
        if let next = remaining.first(where: { SessionStore.setActive(serverId: $0.serverId, userId: $0.userId) }) {
            _ = next
            screen = .loading
        } else {
            screen = .login
        }
    }

    // MARK: Addresses of a server

    /// Applies a list of addresses to all the profiles of a server (they are shared by its users).
    func setAddresses(_ addresses: [ServerAddress], forServer serverId: String) {
        var all = (try? ProfileStore.loadAll()) ?? []
        for index in all.indices where all[index].serverId == serverId {
            all[index].addresses = addresses
            if let forced = all[index].forcedAddress, !addresses.contains(where: { $0.url == forced }) {
                all[index].forcedAddress = nil // the forced address was removed
            }
        }
        try? ProfileStore.saveAll(all)
        refreshProfiles()
    }

    func moveAddress(forServer serverId: String, from: Int, to: Int) {
        guard let current = profiles.first(where: { $0.serverId == serverId })?.addresses else { return }
        setAddresses(reorderAddresses(addresses: current, from: UInt32(from), to: UInt32(to)), forServer: serverId)
    }

    func removeAddress(forServer serverId: String, at index: Int) {
        guard var list = profiles.first(where: { $0.serverId == serverId })?.addresses,
              list.indices.contains(index), list.count > 1 else { return }
        list.remove(at: index)
        setAddresses(reorderAddresses(addresses: list, from: 0, to: 0), forServer: serverId)
    }

    /// Edits the label or URL of an address. A new URL is checked: it must answer with the same server.
    func editAddress(forServer serverId: String, at index: Int, label: String, url: String) async throws {
        guard var list = profiles.first(where: { $0.serverId == serverId })?.addresses, list.indices.contains(index) else { return }
        let clean = Self.normalizeURL(url)
        if Self.normalizeURL(list[index].url) != clean {
            let info = try await validateServer(url: clean)
            guard info.id == serverId else { throw JellyfinError.ServerMismatch(message: "This address answers with another server.") }
        }
        list[index] = ServerAddress(
            url: clean, label: label.isEmpty ? list[index].label : label,
            priority: list[index].priority, isLocal: checkIsLocalAddress(url: clean)
        )
        setAddresses(list, forServer: serverId)
    }

    func addAddress(forServer serverId: String, label: String, url: String) async throws {
        let clean = Self.normalizeURL(url)
        let local = checkIsLocalAddress(url: clean)
        let priority = UInt32((profiles.first { $0.serverId == serverId }?.addresses.count ?? 0) + 1)
        let address = ServerAddress(url: clean, label: label.isEmpty ? (local ? "Home" : "Remote") : label, priority: priority, isLocal: local)
        _ = try await ProfileStore.verifyAndAddAddress(toServerId: serverId, address: address)
        refreshProfiles()
    }

    /// Tests an address: does it answer, is it the right server, and how fast.
    func testAddress(_ address: ServerAddress, serverId: String) async -> AddressTestResult {
        let start = Date()
        do {
            let info = try await validateServer(url: address.url)
            guard info.id == serverId else { return .wrongServer }
            return .ok(milliseconds: Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            return .unreachable
        }
    }

    /// Forces an address (nil: back to automatic selection).
    func setForcedAddress(_ url: String?, forServer serverId: String) {
        var all = (try? ProfileStore.loadAll()) ?? []
        for index in all.indices where all[index].serverId == serverId { all[index].forcedAddress = url }
        try? ProfileStore.saveAll(all)
        refreshProfiles()
        if let url, client?.sessionInfo()?.serverId == serverId {
            client?.setServerUrl(newUrl: url)
            Self.rememberServer(url)
        }
    }

    // MARK: Avatar

    /// Fetches the profile picture of the signed-in user (remembered in their profile) and their address.
    func refreshAvatar() async {
        guard let client, let session = client.sessionInfo() else { return }
        guard let user = try? await client.currentUser(), self.client === client else { return }
        if var profile = (try? ProfileStore.loadAll())?.first(where: { $0.serverId == session.serverId && $0.userId == session.userId }),
           profile.userAvatarTag != user.avatarTag || profile.userName != user.name {
            profile.userAvatarTag = user.avatarTag
            profile.userName = user.name
            try? ProfileStore.saveProfile(profile)
        }
        refreshProfiles()
        activeAvatarURL = user.avatarTag.flatMap { URL(string: client.userImageUrl(userId: user.id, tag: $0, maxHeight: 96)) }
    }
}

enum AddressTestResult: Equatable {
    case ok(milliseconds: Int)
    case wrongServer
    case unreachable
}
