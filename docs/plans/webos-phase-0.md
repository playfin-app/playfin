# Playfin webOS — Phase 0 Plan (Decisions, Toolchain & LG C1 Spike)

Status: Consensus `9/10` (reviewed with Opus 5.5 `--effort high`)
Target hardware: **LG C1 (webOS 6.x)** in **non-root LG Developer Mode** (no root required).

## Scope & Rules
- Keep `macos/` and `scripts/test-all.sh` completely untouched and green.
- Work on `feat/webos` (branched off `dev`, rebased regularly).
- Merge `ClientIdentity` (`Task 0.3a`) into `dev` early; merge remaining `core/` changes (`bundled-roots` / `ring-tls`, `PlaySession`) in small PRs only after Gate 0.4 passes.
- Enforce `#![deny(clippy::unwrap_used, clippy::expect_used)]` and `webos/clippy.toml` from Task 0.2 onward.
- Every task stays under ~400 changed lines (`PROJECT_BRIEF.md`).

## Tasks

### Task 0.1 — ADR `0014`, Brief Alignment & Repo Hygiene (`review: self`)
- [x] Create `feat/webos` branch off `dev` and GitHub Milestone `webOS v0.1 — LG C1 MVP`.
- [x] Write `docs/decisions/0014-webos-native-ipk.md` (non-root Developer Mode requirement, Store trade-off, `0600` token threat note, major dependencies, Spike 0.4 Go/No-Go gate).
- [x] Update `private/PROJECT_BRIEF.md` (`Platform strategy`, `Security`, `Decisions made by the human`).
- [x] Update `.gitignore` (`webos/target/`, `*.ipk`, `webos_rsa*`) and `scripts/check-hosts.sh` (`webosbrew.org`, `webostv.developer.lge.com`).

### Task 0.2 — Standalone `webos/` Crate, Lints & macOS Simulator Skeleton (`review: self`)
- [x] Create standalone `webos/Cargo.toml` (`playfin_core = { path = "../core" }`), `webos/clippy.toml`, and `#![deny(clippy::unwrap_used, clippy::expect_used)]`.
- [x] Link system `sdl2` (NO `bundled` feature) + `glow` + `femtovg` + bundled OFL font.
- [x] Configure GL attributes (`SDL_GL_ALPHA_SIZE=8`, `SDL_GL_STENCIL_SIZE=8`, `SDL_GL_CONTEXT_PROFILE_MASK = SDL_GL_CONTEXT_PROFILE_ES` on webOS, desktop GL on simulator) and `glClearColor(0.0, 0.0, 0.0, 0.0)`.
- [x] Create `scripts/test-webos.sh` (`cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`) and verify `./scripts/test-all.sh` passes unchanged.

### Task 0.3a — `core/` `ClientIdentity` & Opt-In TLS Features (`review: sonnet`)
- [x] Add `JellyfinClient::new_with_identity` / `restore_with_identity` (preserving `new()`/`restore()` Mac behavior with tests). Merge `ClientIdentity` to `dev` early.
- [x] Add opt-in `bundled-roots` (`webpki-roots` + `reqwest 0.13` `ClientConfig`) and `ring-tls` features in `core/Cargo.toml` (macOS defaults unchanged).

### Task 0.3b — webOS NDK Cross-Compile, CI `.ipk` & TV Gate 1 (`review: sonnet`)
- [x] Add Dockerfile (`openlgtv/buildroot-nc4` `2026.08-webos` SDK with `SDL2_WEBOS`, SHA256-verified) targeting `armv7-unknown-linux-gnueabi` (`softfp`) + `appinfo.json` (`"type": "native"`) + `.ipk` packaging (`ares-package`) bundling `libSDL2-2.0.so*` (`$ORIGIN/lib` rpath) and linking `libglibc_polyfills.a`.
- [x] Verify `core`'s `crate-type = ["lib", "staticlib", "cdylib"]` causes no armv7 cross-link friction (`webos/build.rs`, `scripts/package-webos-ipk.sh`; CI run `45733010151` built `com.playfin.webos_0.1.0_arm.ipk` cleanly, `readelf -d` shows `libSDL2-2.0.so.0` + `RUNPATH=$ORIGIN/lib` + `GLIBC_2.4..2.12`).
- [x] Add `.github/workflows/webos.yml` (`paths: webos/**, core/**`) running host `fmt`/`clippy --all-targets`/`test` (`libsdl2-dev`) + NDK `.ipk` build (failing hard if NDK or `ares-package` is missing).
- [ ] **TV Gate 1 (Non-root Developer Mode on LG C1 — recorded log/photo + FPS):**
  1. Binary links `playfin_core` and performs a real HTTPS request inside `jailer`.
  2. Logs `$HOME` / XDG paths inside `jailer`, calls `load_or_create_device_id` into the persistent data dir (NOT install dir `/media/developer/apps/...`), **reinstalls `.ipk`**, and proves `device_id` survives.
  3. Renders `femtovg` (stencil 8, alpha 8, `SDL_GL_CONTEXT_PROFILE_MASK = SDL_GL_CONTEXT_PROFILE_ES`) at 60 fps, handles `argv[1]` JSON, and logs Magic Remote + D-pad input.

### Task 0.4 — Starfish (`libplayerAPIs`) Playback Spike & Go/No-Go Gate (`review: sonnet`, unsafe FFI)
- Minimal `webos/native/starfish_shim.cpp` (`extern "C"`) + Rust test harness running under non-root `native_devmode` `jailer`.
- **Test Matrix on LG C1:**
  1. HTTP MKV HEVC HDR10 (`static=true`) load.
  2. Jellyfin HLS remux (`master.m3u8`, video copy) load.
  3. Seek (`Seek`) accuracy & recovery.
  4. Audio track switch.
  5. Auth check (`httpHeader` vs `?api_key=`, never logging `api_key` URLs).
  6. Alpha punch-through (`SDL_GL_ALPHA_SIZE=8`, `SDL_GL_STENCIL_SIZE=8`, `glClearColor(0,0,0,0)`, premultiplied alpha in `femtovg`, no dark text fringes).
  7. Empirical DTS and TrueHD/Atmos test on LG C1 to calibrate `DeviceProfile`.
- **No-Go Trigger:** If Starfish / HLS / Luna cannot reliably play & seek 4K HEVC HDR in non-root Developer Mode, record results in ADR `0014`, **stop, and ask the user** before pivoting.
