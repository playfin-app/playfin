# ADR 0003: Rust Core Architecture and UniFFI Bridge

## Context
The application targets multiple platforms in sequence (macOS first, then webOS, Linux, and Windows).
To maximize code reuse, all business logic, networking, token handling, caching, and download segment planning must reside in a cross-platform core, while platform layers only implement presentation and rendering.

## Decision
1. **Language:** Rust (stable) for memory safety, concurrency, and cross-platform portability.
2. **Bridge:** Mozilla UniFFI with async Tokio runtime support to generate native Swift bindings.
3. **Packaging:** Compiled into an XCFramework with a universal macOS slice (`arm64` and `x86_64`).
4. **Portability:** Keep domain logic decoupled from platform-specific I/O to facilitate future WebAssembly or other target compilations.

## Consequences
- Single source of truth for Jellyfin API, playback tracking, and download state.
- Zero boilerplate C-bridge maintenance thanks to UniFFI macro scaffolding.
- Type-safe, asynchronous Swift API (`async`/`await`).
