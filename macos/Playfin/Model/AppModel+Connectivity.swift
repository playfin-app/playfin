import Foundation
import os

/// Network changes, offline mode, reconnection attempts and error handling.
extension AppModel {

    func setupNetworkMonitor() {
        NetworkMonitor.shared.setUpdateHandler { [weak self] path in
            let satisfied = path.status == .satisfied
            let signature = "\(satisfied)-" + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            Task { @MainActor [weak self] in
                self?.scheduleNetworkPathUpdate(isSatisfied: satisfied, signature: signature)
            }
        }
    }

    /// NWPathMonitor often sends several events in a row (wake-up, Wi-Fi, VPN): we ignore a state
    /// identical to the previous one and wait 1 s of calm before probing the server once.
    func scheduleNetworkPathUpdate(isSatisfied: Bool, signature: String) {
        // The very first event describes the state at launch: the session opening already takes care of it.
        guard lastNetworkSignature != nil else { lastNetworkSignature = signature; return }
        guard signature != lastNetworkSignature else { return }
        lastNetworkSignature = signature
        networkDebounceTask?.cancel()
        networkDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.handleNetworkPathUpdate(isSatisfied: isSatisfied)
        }
    }

    @discardableResult
    private func handleTerminalFailure(for client: JellyfinClient, error: Error) -> ProbeResult {
        guard self.client === client else { return .terminal }
        stopBackgroundProber()
        isServerUnreachable = false

        if let jErr = error as? JellyfinError {
            switch jErr {
            case .Unauthorized:
                logger.error("Session expired (401 Unauthorized), signing out...")
                logout()
                loginError = "Your session has expired. Please sign in again."
                return .terminal
            case .ServerMismatch(let msg):
                logger.error("Unexpected server (mismatch): \(msg, privacy: .private)")
                offlineAlertMessage = "Warning: the detected server does not match the configured server."
                return .terminal
            case .ServerError(let msg):
                logger.error("Server error: \(msg, privacy: .private)")
                offlineAlertMessage = "Server error: the server encountered an error."
                return .terminal
            case .Decode(let msg):
                logger.error("Data decoding error: \(msg, privacy: .private)")
                offlineAlertMessage = "Format error in the data received from the server."
                return .terminal
            default:
                break
            }
        }
        logger.error("Unexpected error: \(error.localizedDescription, privacy: .private)")
        offlineAlertMessage = "Unexpected error: \(message(for: error))"
        return .terminal
    }

    enum HandledErrorOutcome {
        case offline
        case terminal
    }

    @discardableResult
    func handleAsyncOperationError(
        _ error: Error,
        for client: JellyfinClient,
        onNetworkError: () -> HandledErrorOutcome
    ) -> HandledErrorOutcome {
        #if DEBUG
        onProbeErrorCaught?(error)
        #endif

        if let jErr = error as? JellyfinError {
            switch jErr {
            case .Network, .ServerUnreachable:
                if Task.isCancelled { return .terminal }
                guard self.client === client else { return .terminal }
                return onNetworkError()
            case .Unauthorized:
                // Always handled even if the task is cancelled: revoked session (Pitfall 1)
                _ = handleTerminalFailure(for: client, error: jErr)
                return .terminal
            default:
                // Server error or terminal failure: no alert if the task is already cancelled
                if Task.isCancelled { return .terminal }
                _ = handleTerminalFailure(for: client, error: jErr)
                return .terminal
            }
        } else if error is CancellationError {
            return .terminal
        } else {
            if Task.isCancelled { return .terminal }
            _ = handleTerminalFailure(for: client, error: error)
            return .terminal
        }
    }

    func handleNetworkPathUpdate(isSatisfied: Bool) async {
        guard let client, screen == .library else { return }
        guard isSatisfied else {
            isServerUnreachable = true
            stopBackgroundProber()
            return
        }
        let profile: ServerProfile?
        do {
            profile = try ProfileStore.primaryProfile()
        } catch {
            logger.error("Error reading the profile during a network change: \(error.localizedDescription, privacy: .private)")
            profile = nil
        }
        if let profile, profile.serverId == client.serverId(), !profile.addresses.isEmpty {
            do {
                if let selected = try await client.onNetworkChanged(
                    addresses: profile.addresses,
                    expectedServerId: profile.serverId
                ) {
                    guard self.client === client else { return }
                    Self.rememberServer(selected.url)
                }
                guard self.client === client else { return }
                let result = await probeAndRecover(skipAddressSelection: true)
                guard self.client === client else { return }
                if result == .offline {
                    isServerUnreachable = true
                    startBackgroundProber()
                }
            } catch {
                handleAsyncOperationError(error, for: client) {
                    logger.error("Server unreachable on the new network: switching to offline mode (\(error.localizedDescription, privacy: .private))")
                    isServerUnreachable = true
                    startBackgroundProber()
                    return .offline
                }
            }
        } else {
            let result = await probeAndRecover()
            guard self.client === client else { return }
            if result == .offline {
                isServerUnreachable = true
                startBackgroundProber()
            }
        }
    }

    /// Tries to re-establish the connection to the server and leaves offline mode if successful.
    func retryConnection() async {
        guard !isRetryingConnection else { return }
        isRetryingConnection = true
        defer { isRetryingConnection = false }
        let result = await probeAndRecover()
        if result == .offline {
            isServerUnreachable = true
            startBackgroundProber()
        }
    }

    /// Tries to reach the active server or to switch to another reachable address.
    @discardableResult
    func probeAndRecover(skipAddressSelection: Bool = false) async -> ProbeResult {
        guard let client, let session = client.sessionInfo() else { return .terminal }

        // If the primary profile has several addresses, the core chooses the reachable address
        let profile: ServerProfile?
        do {
            profile = try ProfileStore.primaryProfile()
        } catch {
            logger.error("Error reading the primary profile in probeAndRecover: \(error.localizedDescription, privacy: .private)")
            profile = nil
        }
        if !skipAddressSelection, let profile, profile.serverId == session.serverId, profile.addresses.count > 1 {
            do {
                try Task.checkCancellation()
                let best = try await client.autoSelectAddress(addresses: profile.addresses, expectedServerId: profile.serverId)
                try Task.checkCancellation()
                guard self.client === client else { return .terminal }
                Self.rememberServer(best.url)
            } catch {
                let outcome = handleAsyncOperationError(error, for: client) {
                    logger.error(
                        "No valid address answers: switching to offline mode (\(error.localizedDescription, privacy: .private))"
                    )
                    isServerUnreachable = true
                    return .offline
                }
                if outcome == .offline { return .offline }
                if Task.isCancelled || outcome == .terminal { return .terminal }
            }
        }

        do {
            try Task.checkCancellation()
            let fresh = try await client.home()
            try Task.checkCancellation()
            guard self.client === client else { return .terminal }
            setHome(fresh)
            isServerUnreachable = false
            stopBackgroundProber()
            Task {
                await self.loadLibraries(client)
                await self.downloads.flushReports()
            }
            return .recovered
        } catch {
            let outcome = handleAsyncOperationError(error, for: client) {
                logger.error("Failed to connect to the server in probeAndRecover: \(error.localizedDescription, privacy: .private)")
                isServerUnreachable = true
                return .offline
            }
            if outcome == .offline { return .offline }
            return .terminal
        }
    }

    /// Starts reconnection attempts in the background with the backoff computed by the core.
    func startBackgroundProber() {
        guard proberTask == nil else { return }
        proberBackoff.reset()
        proberTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delayMs = self?.proberBackoff.nextDelayMs() else { break }
                do {
                    try await Task.sleep(nanoseconds: delayMs * 1_000_000)
                } catch {
                    break
                }
                guard !Task.isCancelled, let self else { break }
                let result = await self.probeAndRecover()
                if result != .offline {
                    break
                }
            }
        }
    }

    /// Stops the background reconnection attempts.
    func stopBackgroundProber() {
        proberTask?.cancel()
        proberTask = nil
    }
}
