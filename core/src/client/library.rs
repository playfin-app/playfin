use super::*;

// Libraries, items, home and their disk cache.
#[uniffi::export(async_runtime = "tokio")]
impl JellyfinClient {
    /// List of all movies, sorted by name.
    pub async fn movies(&self) -> Result<Vec<Movie>, JellyfinError> {
        let user_id = self.user_id()?;
        let response: ItemsResponse<Movie> = self
            .get_json(
                "/Items",
                &[
                    ("userId", user_id.as_str()),
                    ("includeItemTypes", "Movie"),
                    ("recursive", "true"),
                    ("sortBy", "SortName"),
                    (
                        "fields",
                        "Overview,Genres,DateCreated,SortName,CriticRating,PremiereDate,Width,Height,PrimaryImageAspectRatio,ImageBlurHashes",
                    ),
                ],
            )
            .await?;
        self.cache_write("movies", &response.items);
        Ok(response.items)
    }

    /// List of the user's libraries (Movies, Series, Collections...).
    /// On a network failure or in offline mode, returns the cached libraries.
    pub async fn user_views(&self) -> Result<Vec<UserView>, JellyfinError> {
        let user_id = self.user_id()?;
        let query = [
            ("userId", user_id.as_str()),
            ("fields", "PrimaryImageAspectRatio,ImageBlurHashes"),
        ];

        match self
            .get_json::<ItemsResponse<UserView>>("/UserViews", &query)
            .await
        {
            Ok(res) => {
                self.store_views(&res.items);
                Ok(res.items)
            }
            Err(err) => {
                let cached = self.cached_views();
                if !cached.is_empty() {
                    Ok(cached)
                } else {
                    Err(err)
                }
            }
        }
    }

    /// Paged request for the items of a library with sorting and paging.
    pub async fn library_items(
        &self,
        parent_id: Option<String>,
        start_index: u32,
        limit: u32,
        sort_by: Option<String>,
        sort_order: Option<String>,
        include_item_types: Option<String>,
    ) -> Result<LibraryPage, JellyfinError> {
        let user_id = self.user_id()?;
        let start_index_str = start_index.to_string();
        let limit_str = limit.to_string();
        let sort_by_val = sort_by.unwrap_or_else(|| "SortName".to_string());
        let sort_order_val = sort_order.unwrap_or_else(|| "Ascending".to_string());

        let mut query = vec![
            ("userId", user_id.as_str()),
            ("startIndex", start_index_str.as_str()),
            ("limit", limit_str.as_str()),
            ("sortBy", sort_by_val.as_str()),
            ("sortOrder", sort_order_val.as_str()),
            (
                "fields",
                "Overview,Genres,DateCreated,SortName,CriticRating,PremiereDate,Width,Height,PrimaryImageAspectRatio,ImageBlurHashes,SeriesName,SeriesId,SeasonId,SeasonName,IndexNumber,ParentIndexNumber,Type,UserData",
            ),
        ];

        if let Some(pid) = parent_id.as_deref().filter(|s| !s.is_empty()) {
            query.push(("parentId", pid));
        }

        // With a precise type: recursive search of that type (series, movies).
        // Without a type (audiobooks, music, folders…): only the first level, hence the
        // items that group the others, not their individual content.
        match include_item_types.as_deref().filter(|s| !s.is_empty()) {
            Some(types) => {
                query.push(("includeItemTypes", types));
                query.push(("recursive", "true"));
            }
            None => query.push(("recursive", "false")),
        }

        match self
            .get_json::<ItemsResponse<Movie>>("/Items", &query)
            .await
        {
            Ok(response) => {
                let total = response
                    .total_record_count
                    .unwrap_or(response.items.len() as u32);

                Ok(LibraryPage {
                    items: response.items,
                    total_record_count: total,
                    start_index,
                })
            }
            // Offline: the app already shows the latest complete list (`cached_library_items`).
            Err(err) => Err(err),
        }
    }

    /// Search across all of the user's libraries (movies, series, episodes, audiobooks, music,
    /// collections). The server does the sorting: we only download the best `limit` results.
    pub async fn search(&self, term: String, limit: u32) -> Result<Vec<Movie>, JellyfinError> {
        let term = term.trim().to_string();
        if term.is_empty() {
            return Ok(Vec::new());
        }
        let user_id = self.user_id()?;
        let limit = limit.clamp(1, 200).to_string();
        let response: ItemsResponse<Movie> = self
            .get_json(
                "/Items",
                &[
                    ("userId", user_id.as_str()),
                    ("searchTerm", term.as_str()),
                    ("recursive", "true"),
                    ("limit", limit.as_str()),
                    ("enableTotalRecordCount", "false"),
                    (
                        "includeItemTypes",
                        "Movie,Series,Episode,AudioBook,Audio,MusicAlbum,MusicArtist,BoxSet",
                    ),
                    (
                        "fields",
                        "Overview,Genres,DateCreated,SortName,PremiereDate,PrimaryImageAspectRatio,ImageBlurHashes,SeriesName,SeriesId,SeasonId,SeasonName,IndexNumber,ParentIndexNumber,Type,UserData",
                    ),
                ],
            )
            .await?;
        Ok(response.items)
    }

    /// Technical description of the file of an item: container, video, audio and subtitle tracks.
    pub async fn media_info(&self, item_id: String) -> Result<MediaInfo, JellyfinError> {
        #[derive(Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct Stream {
            #[serde(rename = "Type")]
            kind: String,
            codec: Option<String>,
            language: Option<String>,
            channels: Option<i32>,
            #[serde(default)]
            is_default: bool,
            #[serde(default)]
            is_external: bool,
            display_title: Option<String>,
            width: Option<i32>,
            height: Option<i32>,
            video_range_type: Option<String>,
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct Source {
            container: Option<String>,
            #[serde(default)]
            media_streams: Vec<Stream>,
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct Item {
            #[serde(default)]
            media_sources: Vec<Source>,
        }
        let user_id = self.user_id()?;
        let response: ItemsResponse<Item> = self
            .get_json(
                "/Items",
                &[
                    ("userId", user_id.as_str()),
                    ("ids", item_id.as_str()),
                    ("fields", "MediaSources"),
                ],
            )
            .await?;
        let source = response
            .items
            .into_iter()
            .next()
            .and_then(|i| i.media_sources.into_iter().next())
            .ok_or(JellyfinError::NotFound(item_id))?;
        let video = source.media_streams.iter().find(|s| s.kind == "Video");
        let stream = |s: &Stream| StreamInfo {
            codec: s.codec.clone().unwrap_or_default(),
            language: s.language.clone().filter(|l| !l.is_empty()),
            channels: s.channels,
            is_default: s.is_default,
            is_external: s.is_external,
            title: s.display_title.clone(),
        };
        Ok(MediaInfo {
            container: source.container.clone(),
            video_codec: video.and_then(|v| v.codec.clone()),
            width: video.and_then(|v| v.width),
            height: video.and_then(|v| v.height),
            video_range: video.and_then(|v| v.video_range_type.clone()),
            audio: source
                .media_streams
                .iter()
                .filter(|s| s.kind == "Audio")
                .map(stream)
                .collect(),
            subtitles: source
                .media_streams
                .iter()
                .filter(|s| s.kind == "Subtitle")
                .map(stream)
                .collect(),
        })
    }

    /// Movies, series and audiobooks from the user's libraries in which a person (actor,
    /// director…) appears, most recent first.
    pub async fn items_with_person(&self, person_id: String) -> Result<Vec<Movie>, JellyfinError> {
        let user_id = self.user_id()?;
        let response: ItemsResponse<Movie> = self
            .get_json(
                "/Items",
                &[
                    ("userId", user_id.as_str()),
                    ("personIds", person_id.as_str()),
                    ("recursive", "true"),
                    ("includeItemTypes", "Movie,Series,AudioBook,MusicVideo"),
                    ("sortBy", "PremiereDate,ProductionYear,SortName"),
                    ("sortOrder", "Descending"),
                    ("limit", "200"),
                    (
                        "fields",
                        "Overview,Genres,DateCreated,SortName,PremiereDate,PrimaryImageAspectRatio,ImageBlurHashes,Type,UserData",
                    ),
                ],
            )
            .await?;
        Ok(response.items)
    }

    /// Full record of an item (with the cast, absent from the lists to keep them light).
    pub async fn item_details(&self, item_id: String) -> Result<Movie, JellyfinError> {
        let user_id = self.user_id()?;
        let response: ItemsResponse<Movie> = self
            .get_json(
                "/Items",
                &[
                    ("userId", user_id.as_str()),
                    ("ids", item_id.as_str()),
                    (
                        "fields",
                        "Overview,Genres,DateCreated,SortName,People,CriticRating,PremiereDate,Width,Height,PrimaryImageAspectRatio,ImageBlurHashes,SeriesName,SeriesId,SeasonId,SeasonName,IndexNumber,ParentIndexNumber,Type,UserData",
                    ),
                ],
            )
            .await?;
        response
            .items
            .into_iter()
            .next()
            .ok_or(JellyfinError::NotFound(item_id))
    }

    /// Latest known seasons of a series (empty if none). Read from disk, no network.
    pub async fn cached_seasons(&self, series_id: String) -> Vec<Movie> {
        self.cache_read(&format!("seasons_{series_id}"))
            .unwrap_or_default()
    }

    /// Latest known episodes of a season (empty if none). Read from disk, no network.
    pub async fn cached_episodes(&self, series_id: String, season_id: String) -> Vec<Movie> {
        self.cache_read(&format!("episodes_{series_id}_{season_id}"))
            .unwrap_or_default()
    }

    /// List of the seasons of a series.
    pub async fn seasons(&self, series_id: String) -> Result<Vec<Movie>, JellyfinError> {
        let user_id = self.user_id()?;
        let path = format!("/Shows/{series_id}/Seasons");
        let query = [
            ("userId", user_id.as_str()),
            (
                "fields",
                "Overview,Genres,DateCreated,SortName,CriticRating,PremiereDate,Width,Height,PrimaryImageAspectRatio,ImageBlurHashes,SeriesName,SeriesId,IndexNumber,Type,UserData",
            ),
        ];

        match self.get_json::<ItemsResponse<Movie>>(&path, &query).await {
            Ok(response) => {
                let cache_key = format!("seasons_{series_id}");
                self.cache_write(&cache_key, &response.items);
                Ok(response.items)
            }
            Err(err) => {
                let cache_key = format!("seasons_{series_id}");
                if let Some(cached) = self.cache_read::<Vec<Movie>>(&cache_key) {
                    Ok(cached)
                } else {
                    Err(err)
                }
            }
        }
    }

    /// All the episodes of a series, in order (used to choose what to play with one click on the series).
    pub async fn series_episodes(&self, series_id: String) -> Result<Vec<Movie>, JellyfinError> {
        let user_id = self.user_id()?;
        let path = format!("/Shows/{series_id}/Episodes");
        let response: ItemsResponse<Movie> = self
            .get_json(
                &path,
                &[
                    ("userId", user_id.as_str()),
                    (
                        "fields",
                        "SeriesName,SeriesId,SeasonId,SeasonName,IndexNumber,ParentIndexNumber,Type,UserData,RunTimeTicks,PrimaryImageAspectRatio,ImageBlurHashes",
                    ),
                ],
            )
            .await?;
        Ok(response.items)
    }

    /// List of the episodes of a specific season.
    pub async fn episodes(
        &self,
        series_id: String,
        season_id: String,
    ) -> Result<Vec<Movie>, JellyfinError> {
        let user_id = self.user_id()?;
        let path = format!("/Shows/{series_id}/Episodes");
        let query = [
            ("userId", user_id.as_str()),
            ("seasonId", season_id.as_str()),
            (
                "fields",
                "Overview,Genres,DateCreated,SortName,CriticRating,PremiereDate,Width,Height,PrimaryImageAspectRatio,ImageBlurHashes,SeriesName,SeriesId,SeasonId,SeasonName,IndexNumber,ParentIndexNumber,Type,UserData",
            ),
        ];

        match self.get_json::<ItemsResponse<Movie>>(&path, &query).await {
            Ok(response) => {
                let cache_key = format!("episodes_{series_id}_{season_id}");
                self.cache_write(&cache_key, &response.items);
                Ok(response.items)
            }
            Err(err) => {
                let cache_key = format!("episodes_{series_id}_{season_id}");
                if let Some(cached) = self.cache_read::<Vec<Movie>>(&cache_key) {
                    Ok(cached)
                } else {
                    Err(err)
                }
            }
        }
    }

    /// Latest additions of a library ("Recently added in …" row of the home). The server groups
    /// the episodes by series. Keeps a copy for the next immediate display and for offline mode.
    pub async fn latest_in_library(
        &self,
        parent_id: String,
        limit: u32,
    ) -> Result<Vec<Movie>, JellyfinError> {
        let user_id = self.user_id()?;
        let limit = limit.clamp(1, 50).to_string();
        let cache_key = format!("latest_{parent_id}");
        match self
            .get_json::<ItemsOrList>(
                "/Items/Latest",
                &[
                    ("userId", user_id.as_str()),
                    ("parentId", parent_id.as_str()),
                    ("limit", limit.as_str()),
                    ("groupItems", "true"),
                    (
                        "fields",
                        "Overview,Genres,DateCreated,SortName,PremiereDate,SeriesName,SeriesId,IndexNumber,ParentIndexNumber,PrimaryImageAspectRatio,ImageBlurHashes,UserData",
                    ),
                ],
            )
            .await
        {
            Ok(res) => {
                let items = res.into_vec();
                self.cache_write(&cache_key, &items);
                Ok(items)
            }
            Err(err) => self.cache_read::<Vec<Movie>>(&cache_key).ok_or(err),
        }
    }

    /// Latest copy of the latest additions of a library (disk read, no network).
    pub async fn cached_latest_in_library(&self, parent_id: String) -> Vec<Movie> {
        self.cache_read(&format!("latest_{parent_id}"))
            .unwrap_or_default()
    }

    /// Home: movies and series in progress (/UserItems/Resume),
    /// up next (/Shows/NextUp) and latest additions (/Items/Latest).
    pub async fn home(&self) -> Result<Home, JellyfinError> {
        let user_id = self.user_id()?;
        let fields = "Overview,Genres,DateCreated,SortName,CriticRating,PremiereDate,SeriesName,SeriesId,SeasonId,SeasonName,IndexNumber,ParentIndexNumber,Width,Height,PrimaryImageAspectRatio,ImageBlurHashes";

        let resume_query = [
            ("userId", user_id.as_str()),
            ("limit", "20"),
            ("fields", fields),
            ("enableImages", "true"),
        ];

        let next_up_query = [
            ("userId", user_id.as_str()),
            ("limit", "20"),
            ("fields", fields),
            ("enableImages", "true"),
        ];

        let latest_query = [
            ("userId", user_id.as_str()),
            ("limit", "20"),
            ("fields", fields),
            ("enableImages", "true"),
        ];

        // 1. Resume (/UserItems/Resume with fallback to /Items?filters=IsResumable only on NotFound)
        let resume_fut = async {
            match self
                .get_json::<ItemsOrList>("/UserItems/Resume", &resume_query)
                .await
            {
                Ok(res) => Ok(res.into_vec()),
                Err(JellyfinError::NotFound(_)) => {
                    let fallback_query = [
                        ("userId", user_id.as_str()),
                        ("includeItemTypes", "Movie,Episode"),
                        ("recursive", "true"),
                        ("filters", "IsResumable"),
                        ("sortBy", "DatePlayed"),
                        ("sortOrder", "Descending"),
                        ("limit", "20"),
                        ("fields", fields),
                    ];
                    self.get_json::<ItemsResponse>("/Items", &fallback_query)
                        .await
                        .map(|r| r.items)
                }
                Err(err) => Err(err),
            }
        };

        // 2. Next Up (/Shows/NextUp, returns an empty list on 404, propagates network/auth errors)
        let next_up_fut = async {
            match self
                .get_json::<ItemsOrList>("/Shows/NextUp", &next_up_query)
                .await
            {
                Ok(res) => Ok(res.into_vec()),
                Err(JellyfinError::NotFound(_)) => Ok(Vec::new()),
                Err(err) => Err(err),
            }
        };

        // 3. Latest (/Items/Latest with fallback to /Items?sortBy=DateCreated only on NotFound)
        let latest_fut = async {
            match self
                .get_json::<ItemsOrList>("/Items/Latest", &latest_query)
                .await
            {
                Ok(res) => Ok(res.into_vec()),
                Err(JellyfinError::NotFound(_)) => {
                    let fallback_query = [
                        ("userId", user_id.as_str()),
                        ("includeItemTypes", "Movie,Episode"),
                        ("recursive", "true"),
                        ("sortBy", "DateCreated"),
                        ("sortOrder", "Descending"),
                        ("limit", "20"),
                        ("fields", fields),
                    ];
                    self.get_json::<ItemsResponse>("/Items", &fallback_query)
                        .await
                        .map(|r| r.items)
                }
                Err(err) => Err(err),
            }
        };

        let (resume_res, next_up_res, latest_res) =
            tokio::join!(resume_fut, next_up_fut, latest_fut);

        // If one of the requests failed (network, unreachable server, expired auth),
        // propagate the error and DO NOT overwrite the existing valid cache!
        let resume = resume_res?;
        let next_up = next_up_res?;
        let latest = latest_res?;

        let home = Home {
            resume,
            next_up,
            latest,
        };

        self.cache_write("home", &home);
        Ok(home)
    }

    /// The user's favourite movies, series and episodes, most recently added first (/Items?filters=IsFavorite).
    pub async fn favorites(&self) -> Result<Vec<Movie>, JellyfinError> {
        let user_id = self.user_id()?;
        let query = [
            ("userId", user_id.as_str()),
            ("includeItemTypes", "Movie,Series,Episode"),
            ("recursive", "true"),
            ("filters", "IsFavorite"),
            ("sortBy", "DateCreated"),
            ("sortOrder", "Descending"),
            ("limit", "300"),
            (
                "fields",
                "Overview,Genres,DateCreated,SortName,CriticRating,PremiereDate,SeriesName,SeriesId,SeasonId,SeasonName,IndexNumber,ParentIndexNumber,Width,Height,PrimaryImageAspectRatio,ImageBlurHashes,UserData",
            ),
        ];
        let items = self
            .get_json::<ItemsResponse<Movie>>("/Items", &query)
            .await?
            .items;
        self.cache_write("favorites", &items);
        Ok(items)
    }

    // ── Cache: lets the app show right away, before the server answers ──

    /// Latest known home (empty if there is none). Disk read, no network.
    pub async fn cached_home(&self) -> Home {
        self.cache_read("home").unwrap_or_default()
    }

    /// Latest known favourites (empty if there are none). Disk read, no network.
    pub async fn cached_favorites(&self) -> Vec<Movie> {
        self.cache_read("favorites").unwrap_or_default()
    }

    /// Latest known list of movies (empty if there is none). Disk read, no network.
    pub async fn cached_movies(&self) -> Vec<Movie> {
        self.cache_read("movies").unwrap_or_default()
    }

    /// Returns the cached items of a library from local SQLite store without network access (P11).
    pub async fn cached_library_items(&self, parent_id: String) -> Vec<Movie> {
        self.with_profile_store(|store| store.items_in_library(&parent_id).ok())
            .flatten()
            .map(|rows| {
                rows.iter()
                    .filter_map(|json| serde_json::from_str(json).ok())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Stores the complete library item list in local SQLite using cached connection (P11).
    pub async fn store_library_items(&self, parent_id: String, items: Vec<Movie>) {
        let rows: Vec<(String, String, String)> = items
            .iter()
            .filter_map(|m| {
                serde_json::to_string(m)
                    .ok()
                    .map(|json| (m.id.clone(), m.name.clone(), json))
            })
            .collect();
        let _ = self.with_profile_store(|store| {
            let _ = store.replace_library_items(&parent_id, &rows, unix_now());
        });
    }

    /// Returns the cached user views / libraries from local SQLite without network access.
    pub async fn cached_user_views(&self) -> Vec<UserView> {
        self.cached_views()
    }

    /// Clears the active profile's local cache on disk and releases cached database handles.
    pub fn clear_cache(&self) {
        if let Ok(mut guard) = self.profile_store.lock() {
            *guard = None;
        }
        if let Some(dir) = self.user_cache_dir() {
            let _ = std::fs::remove_dir_all(dir);
        }
    }
}
