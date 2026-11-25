# ADR 0014: Native Rust webOS App (.ipk via Developer Mode)

## Context
Playfin targets LG webOS as its second platform after macOS (`docs/decisions/0003-rust-core-and-uniffi.md`). Earlier planning assumed a Chromium-based Web app (`HTML5 <video>` + WASM/JS service). However:
1. Web apps on webOS suffer browser/DOM overhead on TV SoCs and lack the responsiveness of native GPU interfaces (such as PlxNative).
2. We want both the UI and backend on webOS written in Rust, sharing `playfin_core` directly without UniFFI or JavaScript bridges.
3. The initial hardware target is the **LG C1 (webOS 6.x)** running **unrooted LG Developer Mode**—no rooting or jailbreak may ever be required for end users.

## Decision

1. **Native `.ipk` via Non-Root LG Developer Mode (and Unrooted Homebrew Channel):**
   - Package `webos/` as a standalone native webOS application (`"type": "native"` in `appinfo.json`) built as an `.ipk` for `armv7-unknown-linux-gnueabihf`.
   - The app **must run 100% without root** under webOS's `native_devmode` `jailer` sandbox (installed via `ares-install` / webOS Dev Manager, subject to LG's Developer Mode session renewal). Users with the Homebrew Channel installed (also possible without root via Dev Mode) can install the same `.ipk`.
   - **Trade-off:** Official LG Content Store distribution only accepts Web apps and is excluded by this path.

2. **Target LG C1 (webOS 6.x / `Starfish` `libplayerAPIs`) First:**
   - Primary playback target is webOS 5/6+ (`Starfish` / `libplayerAPIs`) via a thin `extern "C"` C++ shim (`starfish_shim.cpp`), with an alpha-punched GLES UI overlay rendered on top (`SDL_GL_ALPHA_SIZE=8`, `SDL_GL_STENCIL_SIZE=8`, `glClearColor(0, 0, 0, 0)`).
   - Legacy webOS 4 (`libndl-directmedia2`) is deferred until after the LG C1 playback spike succeeds and a `MediaPlayerBackend` trait is extracted from real Starfish constraints.

3. **Major New Dependencies (`webos/` and opt-in `core/` features):**
   - `SDL2` (`webosbrew/SDL-webOS` on TV, system SDL2 on desktop simulator) for windowing, Wayland/EGL surface setup, and Magic Remote / D-pad input.
   - `glow` + `femtovg` (MIT/Apache-2.0) for pure-Rust OpenGL ES 2/3 rendering and text/vector UI (avoiding custom shader maintenance and Slint GPLv3 restrictions).
   - Opt-in `webpki-roots` (`bundled-roots` feature, plus optional `ring-tls` feature if needed for armv7 cross-compilation) in `core/` so TLS certificate verification works inside the `jailer` sandbox without changing macOS defaults.

4. **Standalone `webos/` Crate (Zero Impact on macOS):**
   - `webos/Cargo.toml` depends on `playfin_core = { path = "../core" }` as a standalone crate (no root Cargo workspace in Phase 0), preserving `core/Cargo.toml` release profile (`lto = true`, `panic = "abort"`), `core/Cargo.lock`, and all macOS build/release scripts.

5. **Token Storage Exception (Aligned with ADR 0013):**
   - webOS native `jailer` apps have no macOS Keychain. Access tokens are stored in `tokens.json` with `0600` permissions (atomic temp-file write + rename) inside the TV's persistent app data directory (never in purgeable cache or the install directory).
   - **Threat note:** Anyone with Developer Mode SSH access or root on the TV can read the app's data directory; tokens are not user passwords and can be revoked from the Jellyfin server dashboard.

6. **Spike 0.4 Go/No-Go Gate & Fallback Policy:**
   - Before building the UI or features, Task 0.4 must prove HTTP MKV HEVC HDR10 and/or Jellyfin HLS remux (`master.m3u8`), seeking, audio track switching, authentication (`httpHeader` vs `?api_key=`), and clean alpha punch-through on the LG C1 under non-root Developer Mode.
   - **Pre-declared fallbacks:** HTTP MKV direct stream → Jellyfin HLS remux (`DirectStream`) → `com.webos.media` (`uMediaServer` via Luna).
   - **No-Go trigger:** If none of those reliably plays & seeks 4K HEVC HDR with clean alpha OSD in non-root Developer Mode, record the failure here, **stop, and ask the user** before pivoting `webos/` to a Web app (`HTML5 <video>`).

## Consequences
- No root/jailbreak required for developers or users; standard LG Developer Mode suffices.
- Zero disruption to the macOS SwiftUI + MPVKit app (`main`/`dev`).
- Requires a Linux/Docker NDK cross-compilation setup (`webosbrew/meta-lg-webos-ndk`) for `.ipk` packaging, paired with a macOS SDL2 desktop simulator for fast local UI iteration.
- Subtitles in v0.1 use Jellyfin's `/Stream.vtt` endpoint rendered by a pure-Rust WebVTT overlay on the GLES HUD.
