# ADR 0008: Dynamic Libraries, Paged 60/120 Hz Grid, and TV Series Hierarchy

## Context
In Phase 2 of Playfin, the client moves beyond hardcoded "Movies" lists to fully dynamic server libraries (`UserViews`), high-performance paged grid browsing (100 items/page), full TV series detail and episode playback, and seamless macOS keyboard navigation.

## Decisions

### 1. Dynamic Server Libraries (`/UserViews`)
- Query `GET /UserViews` via Rust core `JellyfinClient::user_views()` with disk caching in `libraries.json`.
- Expose `UserView` records containing `id`, `name`, `collection_type`, and `primary_blur_hash`.
- In `SidebarView.swift`, render dynamic "Libraries" sections with SF Symbols tailored to collection types (`movies` -> `film`, `tvshows` -> `tv`, `boxsets` -> `square.stack`, fallback -> `folder`).

### 2. Paginated Grid with Server Sorting (`LibraryPage`)
- Paginate queries through `GET /Items` with `parentId`, `startIndex`, `limit: 100`, `sortBy`, `sortOrder`, and `recursive: true`.
- Disk caching for first page per library (`library_{parentId}.json`) for instant offline display.
- Server-side sorting for Title (Asc/Desc), Date Added (`DateCreated`), Release Date (`PremiereDate`), Community Rating (`CommunityRating`), and Duration (`Runtime`).
- Infinite scrolling: as the user scrolls into the final 20 items of the current batch, `loadMoreLibraryItemsIfNeeded()` seamlessly queries the next page without frame drops.
- Pinned alphabetical jump bar for rapid index-based jumping.

### 3. TV Series Hierarchy & Series Detail Screen
- `JellyfinClient::seasons(series_id)`: queries `GET /Shows/{series_id}/Seasons` with caching in `seasons_{series_id}.json`.
- `JellyfinClient::episodes(series_id, season_id)`: queries `GET /Shows/{series_id}/Episodes` with caching in `episodes_{series_id}_{season_id}.json`.
- Route discrimination: in `LibraryView.swift`, when navigating to `.movie(id)`, inspect `movie.isSeries`. If true, display `SeriesDetailView(series: movie)`, otherwise `MovieDetailView(movie: movie)`.
- `SeriesDetailView.swift`:
  - Hero backdrop, ClearLogo/Title, ratings, and series synopsis.
  - Primary "Play / Resume Series" capsule button targeting the next unwatched episode.
  - Horizontal season picker capsule tabs.
  - Episode cards with 16:9 BlurHash thumbnails, episode index, title, played checkmark, runtime, and direct playback button.

### 4. Full Keyboard Navigation
- **Detail Screens (`MovieDetailView`, `SeriesDetailView`)**:
  - Primary Play / Resume button is focused automatically (`@FocusState`) on appear.
  - `Space` or `Return`: triggers direct video playback.
  - `Esc`: dismisses view and returns to previous navigation depth.
- **Grids & Shelves (`LibraryGridView`, `MoviesGridView`, `HomeView`)**:
  - Poster cards participate in keyboard focus (`.focused($focusedId, equals: movie.id)`).
  - `Space`: instant direct playback of the focused card without mouse interaction.
  - `Return`: pushes the detail destination view.

## Consequences
- 100-item batch pagination ensures memory usage remains strictly under the < 300 MB budget even with large (2,000+ item) libraries.
- The app maintains fluid 60/120 Hz scrolling with rigid card geometries and BlurHash placeholders.
- Offline mode seamlessly reads from `library_{parentId}.json`, `seasons_{series_id}.json`, and `episodes_{series_id}_{season_id}.json`.
