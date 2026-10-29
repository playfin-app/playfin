# Contributing to Playfin

Thank you for contributing to Playfin!

## Project layout

```
core/src/                    Rust core (shared by every platform)
├── lib.rs                   module list and free functions exported to Swift
├── error.rs                 JellyfinError
├── models.rs                types shared with Swift, server JSON responses
├── media_info.rs            tracks of a file, direct-play support
├── dates.rs                 ISO 8601 dates
├── client/                  JellyfinClient
│   ├── mod.rs               construction, addresses, sign-in, internal HTTP helpers
│   ├── library.rs           libraries, items, home, disk cache
│   ├── media.rs             images, streams, subtitles, playback reports
│   └── tests.rs
├── profiles.rs, store.rs, settings.rs, discovery.rs, blurhash.rs
└── downloads/               segmented downloader

macos/Playfin/           SwiftUI app
├── App/                     entry point, paths, device identity, diagnostics
├── Model/                   AppModel (state in AppModel.swift, behaviour in AppModel+<topic>.swift),
│                            SettingsModel, DownloadsModel
├── Services/                sessions file, profiles file, network monitor, image cache
├── Features/<Screen>/       one folder per screen: Login, Navigation, Home, Library, Detail,
│                            Search, Downloads, Player, Settings
├── Shared/                  reusable views (cards, artwork, buttons) and Theme
└── Resources/               assets, acknowledgements

macos/Tests/                 one file per area; Support/ holds AppTestCase and MockHttpServer
```

After adding or moving a Swift file: `cd macos && xcodegen generate`.

Publishing a version, from `dev` with nothing left to commit: `scripts/release.sh X.Y.Z` (add `--dry-run` to check
first). It writes the version, commits, moves `main` to `dev` and pushes the tag `vX.Y.Z`, which runs the Release
workflow: tests, universal app, GitHub release and Homebrew cask.

## Code Conventions

### Commit Messages
We follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:
- `feat:` New features
- `fix:` Bug fixes
- `refactor:` Code improvements without functional changes
- `test:` Unit or integration tests
- `docs:` Documentation updates
- `chore:` Tooling or maintenance changes

### Rust Guidelines
- Use idiomatic Rust without `unwrap()` or `expect()` in production code (tests only).
- Structured error handling with `thiserror`.
- Ensure code passes formatting and linting:
  ```bash
  cargo clippy -- -D warnings
  cargo fmt --check
  ```

### Swift Guidelines
- Modern Swift concurrency (`async`/`await`), Swift Observation framework.
- Avoid force unwrapping (`!`).
- Maintain thin Views and decoupled ViewModels.

### Security
- Never commit secrets, server URLs, passwords, or access tokens.
- Authentication tokens are only kept by `SessionStore` (file readable by the user only, see `docs/decisions/0013`).
