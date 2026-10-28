import Foundation
import os

/// Keeps the installation identifier (the core's `device_id` file) safe from a Caches purge.
/// The core reads and creates it in its cache folder; a copy lives in Application Support.
enum DeviceIdentity {
    private static let fileName = "device_id"
    private static let logger = Logger(subsystem: "com.playfin.app", category: "DeviceIdentity")

    static var persistentDir: URL {
        AppPaths.supportDirectory
    }

    /// Call before and after creating a client:
    /// copies the identifier from the cache to Application Support, or the other way round if the cache was emptied.
    static func sync(cacheDir: URL, persistentDir: URL = persistentDir) {
        let cacheFile = cacheDir.appendingPathComponent(fileName)
        let persistentFile = persistentDir.appendingPathComponent(fileName)
        let fm = FileManager.default

        if fm.fileExists(atPath: cacheFile.path) {
            guard !fm.fileExists(atPath: persistentFile.path) else { return }
            copy(from: cacheFile, to: persistentFile, directory: persistentDir)
        } else if fm.fileExists(atPath: persistentFile.path) {
            copy(from: persistentFile, to: cacheFile, directory: cacheDir)
        }
    }

    private static func copy(from source: URL, to destination: URL, directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            logger.error("Could not keep the installation identifier: \(error.localizedDescription, privacy: .private)")
        }
    }
}
