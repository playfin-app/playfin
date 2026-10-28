# 5. Onboarding, Quick Connect, and Multi-Address Architecture

Date: 2026-10-06
Status: Accepted

## Context

Onboarding for first launch requires:
1. Automatic local network discovery of Jellyfin servers (UDP broadcast on port 7359) alongside manual URL entry.
2. Mandatory server validation prior to prompting for credentials (checking reachability, Jellyfin compatibility, and version >= 10.9).
3. Support for both standard credential authentication (username/password) and Quick Connect device-pairing flow.
4. Prompting the user to register a secondary address (such as a remote HTTPS or alternative local IP) immediately following first login, enabling automatic address selection across network changes.

## Decision

### 1. Discovery and Live Validation
- `scanLocalServers` leverages the Rust core's `discover_servers` UDP broadcast.
- Manual URL entry or selecting a discovered server triggers `validateServerURL`, calling `validate_server` in Rust to inspect `/System/Info/Public`. Servers reporting versions earlier than 10.9 or failing to respond are rejected with clear error feedback.

### 2. Quick Connect Flow
- Exposed via `quick_connect_initiate`, `quick_connect_poll`, and `quick_connect_authenticate` on `JellyfinClient`.
- Calls `POST /QuickConnect/Initiate` to generate a 6-character user code and temporary secret.
- The macOS client displays the code prominently and polls `GET /QuickConnect/Connect?secret={secret}` every 2.5 seconds.
- Upon authorization from another Jellyfin client/browser, calls `POST /Users/AuthenticateWithQuickConnect` to complete session login and obtain tokens.

### 3. Multi-Address Profile Storage & Address Probing
- Non-secret server profiles and ordered addresses are managed via `ProfileStore.swift` stored in `Application Support/com.playfin.app/profiles.json`.
- Access tokens strictly remain inside macOS Keychain via `SessionStore.swift`.
- When adding a secondary address, the core verifies that the server's unique ID matches the active profile's `serverId`, preventing accidental mix-ups.
- At launch and profile activation, if multiple addresses exist, `selectBestAddress` probes all addresses in parallel with a 1.5s timeout, prioritizing low-latency LAN addresses while falling back to remote addresses when off-site.

## Consequences

- Frictionless onboarding experience without manual IP typing when on LAN.
- Support for modern passwordless device pairing via Quick Connect.
- Robust multi-homed address switching ensuring uninterrupted connectivity across home and remote environments.
