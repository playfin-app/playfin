# 0012 — Segmented downloader (Phase 5)

Code: `core/src/downloads/` (`plan.rs` and `bucket.rs` pure; `store.rs` SQLite; `mod.rs` I/O). Tests: `core/src/downloads/tests.rs` (fake wiremock server that handles byte ranges).

1. **Probe**: `GET /Items/{id}/Download` with `Range: bytes=0-0`. A 206 response gives the size (`Content-Range`), the ETag, `Last-Modified` and the extension (`Content-Disposition`). A 200 response = no ranges: a single connection, no resume, and the screen says so.
2. **Splitting**: at most N segments (setting, 1 to 16, default 4) of at least 8 MiB. A free connection takes half of what remains of the biggest segment in progress (not below 2 × 2 MiB). The end of a segment is read again at each block written: the "stolen" connection stops at the right place.
3. **Writing**: pre-allocated `.part` file, written at the offset (`pwrite`), renamed only when all segments are complete and the size matches.
4. **Resume**: segment progress in `downloads.sqlite` (Application Support, never emptied with the cache) every 2 s, on pause and at the end. At restart: `resume_all`. If the size, ETag or Last-Modified changed, we start again from zero.
5. **Address**: the URL is rebuilt at each attempt with the client's active address; when the app changes address (network), the segments restart on the new one without losing what is written.
6. **Errors**: network / 5xx = new attempt with a wait of 1, 2, 4… s (capped at 30 s, adjustable count, counter reset when bytes arrive). Rights (403), not found (404), session (401) = immediate failure with a clear message. Disk space checked before starting (remaining + 1 GB).
7. **Speed**: token bucket shared by all connections (1 s capacity).
8. **Queue**: position, pause, resume, cancel, retry, reordering, limit of simultaneous downloads (1 to 5). A pause wins over starting (the "waiting → in progress" transition is conditional).
9. **Side files**: poster and background (those of the series for an episode), external subtitles (all, preferred languages or none), item metadata (JSON): one can browse and play without a server.
10. **Offline reports**: kept in the same database, sent when the server is back (`POST /UserItems/{id}/UserData`). Conflict rule: if the server has a more recent playback (`LastPlayedDate`) than our report, we keep the server.
11. **Layout**: `<Server>/Movies/<Title (Year)>.<ext>`, `<Server>/<Series>/Season N/<Series - S01E03 - Title>.<ext>`, `<Server>/Audiobooks/…`.

Measurements on a real network: to do (see the final report). The `several_connections_are_not_slower_than_one` test only checks that there is no slowdown locally.
