# 0009 — Jellyfin versions and localization

## Jellyfin server versions

- Supported: **Jellyfin 10.9 and later**. The core refuses older servers with `UnsupportedServerVersion`.
- Endpoints that depend on this: `/UserPlayedItems/{itemId}` (mark played / unplayed), Quick Connect, `/Items` with `includeItemTypes`.
- Verified by hand against the maintainer's own 10.9+ server; automated tests use synthetic mock servers only.

## Localization

- The whole project (interface, code, comments, tests and documentation) is written in English.
- User-facing strings are literal `Text("…")` values, ready to be moved to a String Catalog (`Localizable.xcstrings`) if other languages are added later.

## Offline banner

The banner reads "Server unreachable — showing saved content". It matches the planned text without "and downloads": the Downloads section did not exist before Phase 5. The text can be completed later.
