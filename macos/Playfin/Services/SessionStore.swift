import Foundation
import Security

/// Secure storage of the Jellyfin session in the macOS Keychain.
/// Access tokens are never written in clear text on disk.
enum SessionStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var customService: String?
    private static var defaultService: String { AppPaths.keychainService }
    /// Old single entry, read only once to migrate to one entry per server and per user.
    private static let legacyAccount = "session"
    /// Points to the active session (`serverId:userId`); contains no secret.
    private static let activeAccount = "active"

    /// Lets an isolated Keychain service name be injected for the tests (Pitfall 8).
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

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Key of a session: one token per server and per user.
    static func accountKey(serverId: String, userId: String) -> String {
        "\(serverId):\(userId)"
    }

    /// True if an entry exists for this server and this user (useful for the tests).
    static func hasEntry(serverId: String, userId: String) -> Bool {
        read(account: accountKey(serverId: serverId, userId: userId)) != nil
    }

    @discardableResult
    private static func write(_ data: Data, account: String) -> Bool {
        let base = query(account: account)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func read(account: String) -> Data? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// True if the entry exists. Does not read the secret: the Keychain therefore asks for no authorisation.
    private static func exists(account: String) -> Bool {
        var q = query(account: account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    private static func decode(_ data: Data) -> SessionInfo? {
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        return SessionInfo(
            serverUrl: saved.serverUrl,
            serverId: saved.serverId ?? "",
            userId: saved.userId,
            accessToken: saved.accessToken
        )
    }

    @discardableResult
    static func save(_ info: SessionInfo) -> Bool {
        let saved = Saved(
            serverUrl: info.serverUrl,
            serverId: info.serverId,
            userId: info.userId,
            accessToken: info.accessToken
        )
        guard let data = try? JSONEncoder().encode(saved) else { return false }

        let key = accountKey(serverId: info.serverId, userId: info.userId)
        // The tokens of the other profiles stay: one can switch between them without signing in again.
        // A token is only deleted by signing out of its profile (`delete(serverId:userId:)`).
        guard write(data, account: key), write(Data(key.utf8), account: activeAccount) else { return false }
        // The old entry is only deleted after the new one has been written successfully.
        SecItemDelete(query(account: legacyAccount) as CFDictionary)
        return true
    }

    /// Saved session of a specific profile (without making it active).
    static func load(serverId: String, userId: String) -> SessionInfo? {
        read(account: accountKey(serverId: serverId, userId: userId)).flatMap(decode)
    }

    /// Makes the session of an already signed-in profile active. False if there is no token for this profile.
    @discardableResult
    static func setActive(serverId: String, userId: String) -> Bool {
        let key = accountKey(serverId: serverId, userId: userId)
        guard exists(account: key) else { return false }
        return write(Data(key.utf8), account: activeAccount)
    }

    /// Signs a profile out: deletes its token (and the pointer if it was active).
    static func delete(serverId: String, userId: String) {
        let key = accountKey(serverId: serverId, userId: userId)
        SecItemDelete(query(account: key) as CFDictionary)
        if let pointer = read(account: activeAccount), String(data: pointer, encoding: .utf8) == key {
            SecItemDelete(query(account: activeAccount) as CFDictionary)
        }
    }

    static func load() -> SessionInfo? {
        if let pointer = read(account: activeAccount),
           let key = String(data: pointer, encoding: .utf8),
           let data = read(account: key) {
            return decode(data)
        }
        // Migration: session saved before the per-server and per-user entry.
        guard let legacy = read(account: legacyAccount), let info = decode(legacy) else { return nil }
        save(info)
        return info
    }

    /// Sign-out: deletes the active session (and the old entry, if it still exists).
    static func delete() {
        if let pointer = read(account: activeAccount), let key = String(data: pointer, encoding: .utf8) {
            SecItemDelete(query(account: key) as CFDictionary)
        }
        SecItemDelete(query(account: activeAccount) as CFDictionary)
        SecItemDelete(query(account: legacyAccount) as CFDictionary)

        // Defensive cleanup of possible temporary files or obsolete keys
        AppPaths.defaults.removeObject(forKey: "Playfin_SavedSession")
        let file = AppPaths.supportDirectory.appendingPathComponent("session.json")
        try? FileManager.default.removeItem(at: file)
    }
}
