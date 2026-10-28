# ADR 0002: MPVKit LGPL Integration, Compliance Obligations, and Rendering

## Context
High-performance video playback is the foundation of Playfin. Standard Jellyfin web and desktop players often incur heavy CPU usage, frame drops on 4K HDR streams, or server-side transcoding due to incomplete codec support.

Our requirements:
1. **Direct Play:** Direct playback of all common video and audio codecs (HEVC, AV1, VP9, H.264, VC-1, DTS-HD, TrueHD, EAC3) and SSA/ASS styled subtitles.
2. **Hardware Decoding:** Native Apple VideoToolbox hardware decoding (`hwdec=videotoolbox`) across Apple Silicon and Intel Macs.
3. **Portability:** Standalone distribution without requiring external runtime dependencies such as Homebrew (`/opt/homebrew`).
4. **License Compliance:** Strict LGPL compliance for all distributed binaries to maintain compatibility with our MPL-2.0 application codebase without GPL infection.

Initially, development linked against local Homebrew `mpv` binaries. However, Homebrew builds are non-portable (hardcoded `/opt/homebrew` rpaths) and often bundle GPL-licensed dependencies (e.g., `x264`, `x265`).

## Decision

1. **Package Integration via MPVKit:**
   - Integrate `MPVKit` via Swift Package Manager pinned to release tag `1.1.0-n9.0.2` (mpv v0.41.0, FFmpeg n9.0.2).
   - Use the LGPL package product (`MPVKit`), which configures FFmpeg with `--disable-gpl` and mpv in LGPL mode, excluding all GPL-only codecs and tools.
   - Fully remove all Homebrew header/library search paths and linker flags (`-lmpv`).

2. **Legal and Licensing Obligations (LGPL v3 / LGPL v2.1):**
   To comply with the LGPL requirements while distributing Playfin under MPL-2.0:
   - **Dynamic Linking:** MPVKit components (`Libmpv.framework`, `Libavcodec.framework`, `Libavformat.framework`, etc.) are linked as dynamic frameworks inside `Contents/Frameworks` using `@rpath`. Users retain the legal and practical ability to replace these dynamic libraries with custom or updated builds.
   - **License Notices:** The complete text of the LGPL v3 license (as well as component licenses) must be provided in the repository and displayed in the application's third-party Acknowledgements screen.
   - **Source Code Availability:** Playfin provides clear notices pointing users to the upstream source repository and build recipes for MPVKit (`https://github.com/mpvkit/MPVKit`) and upstream mpv / FFmpeg source trees, ensuring recipients can obtain the exact corresponding source code.

3. **Hardware Acceleration:**
   - Enable VideoToolbox hardware acceleration (`hwdec=videotoolbox`) in the player controller.

4. **Rendering Surface:**
   - Retain the Cocoa OpenGL layer architecture (`MPVNSView` / `MPVLayer` with `mpv_render_context`) for Phase 0 and Phase 1 to guarantee proven 4K playback stability.
   - The Metal rendering pipeline decision and spike remain scheduled for Phase 3.

## Consequences
- Zero dependency on host Homebrew or pre-installed tools; the application bundle is fully portable.
- Ad-hoc signed releases pass `codesign --verify --deep --strict`.
- Direct Play works out of the box with VideoToolbox hardware acceleration.
- Complete licensing compliance: clear boundary between MPL-2.0 application code and LGPL dynamic libraries.
