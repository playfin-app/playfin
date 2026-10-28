import Foundation
import OSLog

/// Exportable diagnostic report. It never contains a token, a password or a user identifier.
enum DiagnosticsReport {
    struct ServerLine {
        let name: String
        let addressCount: Int
        let activeAddressLabel: String?
    }

    static func build(
        appVersion: String,
        coreVersion: String,
        systemVersion: String,
        servers: [ServerLine],
        settings: AppSettings,
        logs: [String]
    ) -> String {
        var lines = [
            "Playfin — diagnostics",
            "App: \(appVersion)",
            "Core: \(coreVersion)",
            "System: \(systemVersion)",
            "Log level: \(settings.logLevel)",
            "Player cache: \(settings.cachePreset)",
            "Hardware decoding: \(settings.hardwareDecoding ? "yes" : "no")",
            "",
            "Servers (\(servers.count)):"
        ]
        for server in servers {
            let active = server.activeAddressLabel.map { ", active address: \($0)" } ?? ""
            lines.append("- \(server.name) — \(server.addressCount) address(es)\(active)")
        }
        lines += ["", "Recent logs:"] + (logs.isEmpty ? ["(none)"] : logs)
        return lines.joined(separator: "\n")
    }

    /// App log messages from the last hour (private values are already masked by the system).
    static func recentLogs() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let since = store.position(date: Date().addingTimeInterval(-3600))
        let entries = (try? store.getEntries(at: since)) ?? AnySequence([])
        return entries.compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "com.playfin.app" }
            .suffix(300)
            .map { "\($0.date.formatted(date: .omitted, time: .standard)) [\($0.category)] \($0.composedMessage)" }
    }
}
