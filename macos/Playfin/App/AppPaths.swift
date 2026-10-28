import Foundation

/// Every location used by the app, in one place.
///
/// During unit tests (the app hosts the tests), **nothing** may touch the real user data: profiles, settings,
/// caches, Keychain and preferences are redirected to a temporary folder specific to the test process.
/// Without this, a test that cleared the profiles used to erase the user's real ones.
enum AppPaths {
    static let bundleName = "com.playfin.app"

    /// True when the code runs inside an XCTest process.
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    /// Temporary root used by the tests (one per process).
    static let testRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("PlayfinTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    nonisolated(unsafe) static var supportDirectoryOverride: URL?

    /// Durable data: profiles, settings, installation identifier, downloads database.
    static var supportDirectory: URL {
        if let override = supportDirectoryOverride { return override }
        let dir = isRunningTests
            ? testRoot.appendingPathComponent("support", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(bundleName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Caches (the system may empty them: this is only a convenience).
    static var cachesDirectory: URL {
        let dir = isRunningTests
            ? testRoot.appendingPathComponent("caches", isDirectory: true)
            : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(bundleName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Keychain service: separate during tests.
    static var keychainService: String {
        isRunningTests ? "\(bundleName).tests" : bundleName
    }

    /// Preferences: a separate domain during tests.
    static var defaults: UserDefaults {
        isRunningTests ? (UserDefaults(suiteName: "\(bundleName).tests") ?? .standard) : .standard
    }
}
