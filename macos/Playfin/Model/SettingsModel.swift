import Foundation
import Observation
import os

/// Application settings: the core validates and saves them, this class exposes them to the interface.
/// Every change is saved immediately and applies at once (or at the next playback).
@MainActor
@Observable
final class SettingsModel {
    private let store: SettingsStore
    /// Notified after each save (e.g. to apply the download settings).
    @ObservationIgnored var onChange: ((AppSettings) -> Void)?
    private let logger = Logger(subsystem: "com.playfin.app", category: "Settings")

    var values: AppSettings {
        didSet {
            guard values != oldValue else { return }
            do {
                let saved = try store.save(settings: values)
                // The core brings invalid values back into the allowed range: the interface shows the result.
                if saved != values { values = saved }
                onChange?(saved)
            } catch {
                logger.error("Could not save the settings: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    init(directory: URL = AppPaths.supportDirectory) {
        store = SettingsStore(dir: directory.path)
        values = store.load()
    }
}

extension AppSettings {
    /// Name of the "skip back N seconds" icon (SF Symbols only has some durations).
    static func skipIcon(forward: Bool, seconds: UInt32) -> String {
        let supported: Set<UInt32> = [5, 10, 15, 30, 45, 60, 75, 90]
        let base = forward ? "goforward" : "gobackward"
        return supported.contains(seconds) ? "\(base).\(seconds)" : base
    }
}
