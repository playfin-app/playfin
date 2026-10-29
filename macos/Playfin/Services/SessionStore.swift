import Foundation
import Security

/// Storage of the Jellyfin sessions (one access token per server and per user) in a file of the app's folder,
/// readable only by the user's account (permissions 600) and left out of backups.
///
/// Not in the Keychain: without an Apple Developer account, macOS recognises the app there by the fingerprint of its
/// code, which changes with every version, so it asked for the Keychain password after each update (see
/// docs/decisions/0013). The tokens of the versions that used the Keychain are moved here once, then deleted from it.
enum SessionStore {
    private static let lock = NSLock()
    /// Every read and write of the file (and the migration) goes through this lock.
    private static let fileLock = NSLock()
    nonisolated(unsafe) private static var customService: String?
    private static var defaultService: String { AppPaths.sessionService }
    /// Old single Keychain entry (before one entry per server and per user).
    private static let legacyAccount = "session"
    /// Old Keychain entry of the active session pointer.
    private static let legacyActiveAccount = "active"

    /// Lets an isolated service name be injected for the tests (Pitfall 8): another file, other preferences.
    static func setServiceName(_ service: String?) {
        lock.withLock {
            customService = service
        }
    }

    private static var service: String {
        lock.withLock {
            customService ?? defaultService
        }
    }

    private struct Saved: Codable {
        let serverUrl: String
        var serverId: String? = nil
        let userId: String
        let accessToken: String
    }

    /// The active session (`serverId:userId`). Contains no secret: in the preferences.
    private static var activePointer: String? {
        get { AppPaths.defaults.string(forKey: "Playfin_ActiveSession_\(service)") }
        set { AppPaths.defaults.set(newValue, forKey: "Playfin_ActiveSession_\(service)") }
    }

    /// Key of a session: one token per server and per user.
    static func accountKey(serverId: String, userId: String) -> String {
        "\(serverId):\(userId)"
    }

    /// True if a token exists for this server and this user (useful for the tests).
    static func hasEntry(serverId: String, userId: String) -> Bool {
        currentTokens()[accountKey(serverId: serverId, userId: userId)] != nil
    }

    @discardableResult
    static func save(_ info: SessionInfo) -> Bool {
        let saved = Saved(
            serverUrl: info.serverUrl,
            serverId: info.serverId,
            userId: info.userId,
            accessToken: info.accessToken
        )
        let key = accountKey(serverId: info.serverId, userId: info.userId)
        // The tokens of the other profiles stay: one can switch between them without signing in again.
        // A token is only deleted by signing out of its profile (`delete(serverId:userId:)`).
        guard updateTokens({ $0[key] = saved }) else { return false }
        activePointer = key
        return true
    }

    /// Saved session of a specific profile (without making it active).
    static func load(serverId: String, userId: String) -> SessionInfo? {
        currentTokens()[accountKey(serverId: serverId, userId: userId)].map(sessionInfo)
    }

    /// Makes the session of an already signed-in profile active. False if there is no token for this profile.
    @discardableResult
    static func setActive(serverId: String, userId: String) -> Bool {
        let key = accountKey(serverId: serverId, userId: userId)
        guard currentTokens()[key] != nil else { return false }
        activePointer = key
        return true
    }

    /// Signs a profile out: deletes its token (and the pointer if it was active).
    static func delete(serverId: String, userId: String) {
        let key = accountKey(serverId: serverId, userId: userId)
        updateTokens { $0[key] = nil }
        if activePointer == key { activePointer = nil }
    }

    static func load() -> SessionInfo? {
        // The tokens first: the migration from the Keychain may set the active pointer.
        let tokens = currentTokens()
        return activePointer.flatMap { tokens[$0] }.map(sessionInfo)
    }

    /// Sign-out: deletes the active session.
    static func delete() {
        _ = currentTokens() // migration first (see `load()`)
        if let key = activePointer {
            updateTokens { $0[key] = nil }
        }
        activePointer = nil

        // Defensive cleanup of possible temporary files or obsolete keys
        AppPaths.defaults.removeObject(forKey: "Playfin_SavedSession")
        let file = AppPaths.supportDirectory.appendingPathComponent("session.json")
        try? FileManager.default.removeItem(at: file)
    }

    private static func sessionInfo(_ saved: Saved) -> SessionInfo {
        SessionInfo(
            serverUrl: saved.serverUrl,
            serverId: saved.serverId ?? "",
            userId: saved.userId,
            accessToken: saved.accessToken
        )
    }

    // MARK: File

    /// `tokens.json` (`tokens-<service>.json` for an injected service).
    private static func fileURL(for service: String) -> URL {
        let name = service == AppPaths.bundleName ? "tokens.json" : "tokens-\(service).json"
        return AppPaths.supportDirectory.appendingPathComponent(name)
    }

    private static func currentTokens() -> [String: Saved] {
        let service = service
        let url = fileURL(for: service)
        return fileLock.withLock {
            migrateFromKeychainIfNeeded(service: service, url: url)
            return readTokens(at: url)
        }
    }

    /// Modifies the tokens and writes the file. False if it could not be written.
    @discardableResult
    private static func updateTokens(_ change: (inout [String: Saved]) -> Void) -> Bool {
        let service = service
        let url = fileURL(for: service)
        return fileLock.withLock {
            migrateFromKeychainIfNeeded(service: service, url: url)
            var tokens = readTokens(at: url)
            change(&tokens)
            return writeTokens(tokens, to: url)
        }
    }

    private static func readTokens(at url: URL) -> [String: Saved] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Saved].self, from: data)) ?? [:]
    }

    /// Temporary file created directly with permissions 600 (never readable by others, even for a moment), then
    /// renamed over the old one: the file is never half written.
    private static func writeTokens(_ tokens: [String: Saved], to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        let complete = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return buffer.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, base + offset, buffer.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        close(descriptor)
        guard complete, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        // The tokens do not go into the backups (a restored Mac signs in again).
        var file = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? file.setResourceValues(values)
        return true
    }

    // MARK: Migration from the Keychain

    /// Moves the tokens of the versions that used the Keychain into the file, once per service. macOS may ask a last
    /// time for the Keychain password (one prompt per token). The Keychain entries are deleted afterwards.
    private static func migrateFromKeychainIfNeeded(service: String, url: URL) {
        let flag = "Playfin_TokensMovedFromKeychain_\(service)"
        guard !AppPaths.defaults.bool(forKey: flag) else { return }

        // Listing the entries (attributes only) asks nothing.
        var listQuery = keychainQuery(service: service)
        listQuery[kSecReturnAttributes as String] = true
        listQuery[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(listQuery as CFDictionary, &result)
        let accounts = ((result as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        guard status == errSecSuccess, !accounts.isEmpty else {
            AppPaths.defaults.set(true, forKey: flag)
            return
        }

        var tokens = readTokens(at: url)
        let pointerKey = "Playfin_ActiveSession_\(service)"
        var pointer = AppPaths.defaults.string(forKey: pointerKey)
        // The old pointer first: it tells which session the old single entry belongs to.
        let ordered = accounts.filter { $0 == legacyActiveAccount } + accounts.filter { $0 != legacyActiveAccount }
        for account in ordered {
            if account == legacyActiveAccount {
                if pointer == nil, let data = readKeychain(service: service, account: account) {
                    pointer = String(data: data, encoding: .utf8)
                }
                continue
            }
            guard let data = readKeychain(service: service, account: account),
                  let saved = try? JSONDecoder().decode(Saved.self, from: data)
            else { continue }
            let key = account == legacyAccount
                ? accountKey(serverId: saved.serverId ?? "", userId: saved.userId)
                : account
            if tokens[key] == nil { tokens[key] = saved }
            if account == legacyAccount, pointer == nil { pointer = key }
        }
        // Without a written file, the Keychain keeps the tokens: we try again at the next opening.
        guard writeTokens(tokens, to: url) else { return }
        AppPaths.defaults.set(pointer, forKey: pointerKey)
        for account in accounts {
            var deleteQuery = keychainQuery(service: service)
            deleteQuery[kSecAttrAccount as String] = account
            SecItemDelete(deleteQuery as CFDictionary)
        }
        AppPaths.defaults.set(true, forKey: flag)
    }

    private static func keychainQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    private static func readKeychain(service: String, account: String) -> Data? {
        var query = keychainQuery(service: service)
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
