# 0010 — Player cache presets, resume rule, languages

Date: 2026-10-07. Status: planned values applied, **not yet measured** on a real server.

## Presets (mpv)

| Preset | `demuxer-max-bytes` | `demuxer-max-back-bytes` | `cache-secs` and `demuxer-readahead-secs` | Approximate max RAM |
|---|---|---|---|---|
| Low | 50 MiB | 20 MiB | 30 | 70 MiB |
| Normal (default) | 150 MiB | 50 MiB | 120 | 200 MiB |
| High | 500 MiB | 150 MiB | 600 | 650 MiB |

Before: 512 MiB / 128 MiB hard-coded. The preset is read from the settings (`playerCachePreset`) at the start of each playback (`PlayerSettings.swift`). The settings window arrives in Phase 4; until then the value can be changed with `defaults write com.playfin.app playerCachePreset "High"`. Hardware decoding is turned off with `playerHardwareDecoding` (boolean, on by default).

## Resume rule

Under 5% of the duration, playback restarts from the beginning; beyond 90%, the item is considered finished (`ResumeRule`).

## Languages

The preferred audio and subtitle languages are the system's (`alang`, `slang`) as long as the Phase 4 settings do not exist.

## Reports to the server

At the start, then every 10 s, and also on each pause and at the end of a jump. Stop with the final position.

## To measure (Phase 3, on the real server)

First picture on the local network (< 2 s), memory actually used by each preset on a 4K file.
