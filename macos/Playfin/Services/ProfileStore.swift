import Foundation

/// Storage of server profiles and their addresses (local and remote).
/// The business logic, serialisation and address hierarchy
/// are handled by the Rust core (`ProfileStoreCore`), while tokens stay in the Keychain.
enum ProfileStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var customDirectory: URL?
    nonisolated(unsafe) private static var _core: ProfileStoreCore?

    /// Lets a temporary storage folder be injected to isolate the tests (Pitfall 8).
    static func setStorageDirectory(_ url: URL?) {
        lock.withLock {
            customDirectory = url
            _core = nil
        }
    }

    private static func resolveStorageDirectory() -> URL {
        if let custom = customDirectory {
            return custom
        }
        return AppPaths.supportDirectory
    }

    private static var core: ProfileStoreCore {
        lock.withLock {
            if let instance = _core { return instance }
            let dir = resolveStorageDirectory()
            let instance = ProfileStoreCore(storageDir: dir.path)
            _core = instance
            return instance
        }
    }

    static func loadAll() throws -> [ServerProfile] {
        try core.loadAll()
    }

    static func saveAll(_ profiles: [ServerProfile]) throws {
        try core.saveAll(profiles: profiles)
    }

    static func primaryProfile() throws -> ServerProfile? {
        try core.primaryProfile()
    }

    static func saveProfile(_ profile: ServerProfile) throws {
        try core.saveProfile(profile: profile)
    }

    static func verifyAndAddAddress(toServerId serverId: String, address: ServerAddress, timeoutMs: UInt64 = 3000) async throws -> ServerPublicInfo {
        try await core.verifyAndAddAddress(serverId: serverId, address: address, timeoutMs: timeoutMs)
    }

    static func resetCorruptStorage() throws {
        try core.resetCorruptStorage()
    }

    static func clear() throws {
        try core.clear()
    }
}
