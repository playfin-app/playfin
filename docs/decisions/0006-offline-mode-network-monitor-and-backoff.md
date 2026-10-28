# 6. Offline Mode, Network Monitoring, and Background Backoff Probing

Date: 2026-10-06
Status: Accepted

## Context

Requirements:
1. Cold launch with an unreachable server must render cached Home in under 1 second, with a persistent but unobtrusive offline banner visible within 2 seconds.
2. The offline banner states: "Server unreachable — showing saved content and downloads", equipped with a manual "Retry" action.
3. In offline mode, undownloaded streaming items are dimmed and attempting to play them clearly explains that streaming requires a connection to the server.
4. Automatic recovery: The client must continuously listen for system network interface changes (via `NWPathMonitor`) to re-probe immediately upon reconnecting or switching networks (e.g. Wi-Fi / cellular). When disconnected, background probing runs with exponential backoff up to every 60 seconds.

## Decision

### 1. Cache-First Startup & Failure Transition
- `openSession` renders cached Home rows from disk instantly before dispatching network requests.
- When `client.home()` fails with a network or server unreachable error, `AppModel` switches to offline mode:
  - `isServerUnreachable = true`
  - `OfflineBanner` is presented at the top of the detail hierarchy with a smooth transition.
  - Background exponential backoff probing is engaged.

### 2. Network Change Detection (`NetworkMonitor`)
- Implemented `NetworkMonitor` wrapping Apple's `NWPathMonitor` on a dedicated utility queue.
- `AppModel` listens to path updates:
  - If network connectivity is lost (`status != .satisfied`), offline mode is flagged.
  - If network connectivity is restored or interface path changes, an immediate probe (`probeAndRecover`) is executed without waiting for the backoff timer.
  - If a primary profile has multiple configured addresses, `selectBestAddress` is evaluated to auto-switch between LAN and Remote seamlessly.

### 3. Background Backoff Probing & Manual Retry
- A background `Task` attempts reconnection starting with a 5s delay, increasing exponentially (factor 1.5x) up to a 60s ceiling.
- Manual "Try again" button triggers `retryConnection()`, immediately executing `probeAndRecover()`.
- Upon successful recovery, offline mode is cancelled, the banner animates away, the prober task cancels, and fresh data refreshes in-place.

### 4. Playback Guard in Offline Mode
- Attempting to play streaming media while offline triggers an informative macOS alert dialog, explaining that streaming requires an active connection to the Jellyfin server.
- Poster cards and continue shelves reflect offline state with dimmed opacity and contextual tooltips.

## Consequences

- Conforms strictly to latency and responsiveness budgets (< 1s cached Home, banner within 2s).
- Eliminates blank screen / broken state when traveling or during temporary server downtime.
- Seamless automatic reconnection upon waking Mac, reconnecting to Wi-Fi, or server recovery.
