# Playfin

**A fast, native macOS app for watching your Jellyfin library.**

![Home](docs/screenshots/home.png)

Playfin connects to your [Jellyfin](https://jellyfin.org) server and lets you browse and play your movies and shows like you would on a TV: a large artwork at the top, rows of posters below, and playback one click away. It is an independent open-source project, not affiliated with the Jellyfin team.

## What it does

**It opens instantly.** Your home screen, libraries and episodes are kept in a local cache, so they appear right away and refresh quietly in the background.

**It plays almost anything.** Playback uses mpv with hardware decoding, so most files play directly without the server having to convert them. HDR10 and HLG are shown in real HDR on screens that support it, and 5.1 / 7.1 sound can go straight to your amplifier. You also get audio and subtitle menus sorted by language, adjustable subtitles, "Skip intro" and "Skip credits" buttons, automatic next episode, and picture in picture.

**It fits in with macOS.** The play/pause keys and the Now Playing widget control the player, and most actions have a keyboard shortcut (press ⇧⌘/ to see them all).

**It works at home and away.** You can give a server several addresses, for example one for your home network and one for outside. Playfin tries them all and uses the one that answers, and switches by itself when you change networks.

**It works offline.** Download a movie or a whole season and watch it without a connection. Downloads resume after a crash or a restart, and what you watched offline is synced to the server once you are back online.

**It handles several people.** Each profile has its own server, account, cache and downloads. You can switch between them from the Profiles menu.

There is also search across all your libraries and a Favourites tab.

| | |
|---|---|
| ![Movie](docs/screenshots/movie.png) | ![Player](docs/screenshots/player.png) |
| ![Profiles](docs/screenshots/settings-profiles.png) | ![Player cache](docs/screenshots/settings-player-cache.png) |

*The screenshots use demo data, not a real server.*

## Requirements

- A Mac with macOS 14 Sonoma or later (Apple silicon or Intel).
- A Jellyfin server, version 10.9 or later. "Skip intro" needs 10.10 or later.

## Install

### With Homebrew

```bash
brew tap playfin-app/tap
brew trust playfin-app/tap
brew install --cask playfin
```

The `trust` line is only needed once, on recent versions of Homebrew. To update later, run `brew upgrade --cask playfin`.

### By hand

Download `Playfin-macOS.zip` from the [Releases page](https://github.com/playfin-app/playfin/releases), unzip it and move `Playfin.app` to your Applications folder.

The app is not notarized by Apple yet, so macOS blocks it the first time you open it. To allow it, go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run this in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Playfin.app
```

Homebrew does this step for you.

## Privacy

Playfin only talks to your own Jellyfin server. There are no analytics and no third-party services. Your login token is stored in the macOS Keychain and never appears in logs or diagnostic exports.

## Building from source

Playfin has two parts: a core written in Rust (`core/`) that handles the server, the cache and the downloads, and a SwiftUI app (`macos/`) on top of it. The two are connected with UniFFI.

```bash
brew install xcodegen swiftlint gitleaks
rustup target add aarch64-apple-darwin x86_64-apple-darwin
scripts/build-xcframework.sh   # builds the Rust core and generates the Xcode project
scripts/test-all.sh            # runs all tests and checks
scripts/package-release.sh     # builds the final app in build/Release
```

The reasons behind the main technical choices are written down in [`docs/decisions/`](docs/decisions/).

## Contributing

Bug reports and ideas are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) to get started.

## Licence

Playfin is released under the [Mozilla Public License 2.0](LICENSE). It includes mpv and FFmpeg (LGPL build). The full list of third-party components is in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) and in the app under Settings → About.
