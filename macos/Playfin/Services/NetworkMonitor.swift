import Foundation
import Network

/// Monitors the Mac's network connectivity via `NWPathMonitor`.
/// Detects network drops or recoveries as well as interface changes (Wi-Fi, Ethernet, tethering).
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let lock = NSLock()
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.playfin.app.networkmonitor", qos: .utility)
    private var _updateHandler: (@Sendable (NWPath) -> Void)?

    private var _isConnected: Bool = true
    private var _isExpensive: Bool = false

    var isConnected: Bool {
        lock.withLock { _isConnected }
    }

    var isExpensive: Bool {
        lock.withLock { _isExpensive }
    }

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        self.monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let handler: (@Sendable (NWPath) -> Void)? = self.lock.withLock {
                self._isConnected = (path.status == .satisfied)
                self._isExpensive = path.isExpensive
                return self._updateHandler
            }
            handler?(path)
        }
        self.monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    func setUpdateHandler(_ handler: @escaping @Sendable (NWPath) -> Void) {
        lock.withLock {
            self._updateHandler = handler
        }
    }
}
