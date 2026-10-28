# 4. Jellyfin Home Endpoints and Cache Isolation

Date: 2026-10-06
Status: Accepted

## Context

The project requires Jellyfin minimum supported version is 10.9.
Home screen content must display three rows:
1. Continue Watching
2. Next Up (episodes in progress / next episode for series)
3. Recently Added

Furthermore, local SQLite/JSON caching must be isolated per profile (`serverId` + `userId`) so that switching profiles or servers never shares or corrupts cached data across accounts or servers, preventing data leakage and race conditions.

## Decision

### 1. Jellyfin Endpoints (10.9+)
- **Continue Watching**: `GET /UserItems/Resume` (with fallback to `/Items?filters=IsResumable&sortBy=DatePlayed`).
- **Next Up**: `GET /Shows/NextUp` (non-blocking, gracefully returns empty if user has no shows or endpoint returns 404).
- **Recently Added**: `GET /Items/Latest` (with fallback to `/Items?sortBy=DateCreated`).
- An untagged enum `ItemsOrList` is used to deserialize both query result envelopes (`{"Items": [...]}`) and bare JSON lists (`[...]`) seamlessly, accommodating endpoint variations across Jellyfin versions.

### 2. Multi-Profile Cache Directory Isolation
- Every profile is keyed by `(serverId, userId)`.
- Directory structure: `<cacheDir>/<sanitized_server_id>/<sanitized_user_id>/`.
- Both identifiers are sanitized by stripping non-alphanumeric and non-hyphen characters, strictly preventing directory traversal attacks (`../`).
- If `serverId` is omitted (legacy session), cache falls back safely to `<cacheDir>/<sanitized_user_id>/`.
- `clear_cache` strictly purges only the active profile's directory without touching other profiles' caches or downloads.

## Consequences

- Clean separation of user data across servers and accounts.
- Zero cache collision when switching profiles.
- Resilient Home data fetching supporting Movies and Series.
