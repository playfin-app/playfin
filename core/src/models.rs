//! Types shared with Swift and the JSON responses of the server.

use serde::{Deserialize, Serialize};

/// What must be saved to stay signed in.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SessionInfo {
    pub server_url: String,
    pub server_id: String,
    pub user_id: String,
    pub access_token: String,
}

/// The user's progress on a movie.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct UserData {
    #[serde(default)]
    pub playback_position_ticks: i64,
    #[serde(default)]
    pub played: bool,
    pub played_percentage: Option<f64>,
}

/// A person linked to a movie (actor, director...).
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct Person {
    pub id: Option<String>,
    pub name: String,
    #[serde(rename = "Type")]
    pub role_type: Option<String>,
    pub role: Option<String>,
}

/// A movie or an episode as returned by Jellyfin.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct Movie {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub sort_name: Option<String>,
    pub production_year: Option<i32>,
    #[serde(default)]
    pub premiere_date: Option<String>,
    /// Duration in "ticks" (1 tick = 100 nanoseconds).
    pub run_time_ticks: Option<i64>,
    /// File format (e.g. "mkv", "mp4").
    pub container: Option<String>,
    pub overview: Option<String>,
    pub community_rating: Option<f32>,
    #[serde(default)]
    pub critic_rating: Option<f32>,
    pub official_rating: Option<String>,
    #[serde(default)]
    pub genres: Vec<String>,
    #[serde(default)]
    pub date_created: Option<String>,
    #[serde(default)]
    pub people: Vec<Person>,
    pub user_data: Option<UserData>,
    #[serde(default, rename = "SeriesName")]
    pub series_name: Option<String>,
    #[serde(default, rename = "SeriesId")]
    pub series_id: Option<String>,
    #[serde(default, rename = "SeasonId")]
    pub season_id: Option<String>,
    #[serde(default, rename = "SeasonName")]
    pub season_name: Option<String>,
    #[serde(default, rename = "IndexNumber")]
    pub index_number: Option<i32>,
    #[serde(default, rename = "ParentIndexNumber")]
    pub parent_index_number: Option<i32>,
    #[serde(default, rename = "Type")]
    pub item_type: Option<String>,
    #[serde(default)]
    pub width: Option<i32>,
    #[serde(default)]
    pub height: Option<i32>,
    #[serde(
        default,
        deserialize_with = "deserialize_primary_blur_hash",
        alias = "ImageBlurHashes"
    )]
    pub primary_blur_hash: Option<String>,
    #[serde(default)]
    pub primary_image_aspect_ratio: Option<f64>,
    /// BlurHash of the background image, copied from `ImageBlurHashes.Backdrop` by `get_json`.
    #[serde(default)]
    #[uniffi(default = None)]
    pub backdrop_blur_hash: Option<String>,
    /// Tags of the item's images (`Primary`, `Logo`…): they change when the image changes on the server.
    #[serde(default, deserialize_with = "deserialize_image_tags")]
    #[uniffi(default = [])]
    pub image_tags: Vec<ImageTag>,
    /// Tags of the item's own background images (the first one is the one used).
    #[serde(default)]
    #[uniffi(default = [])]
    pub backdrop_image_tags: Vec<String>,
    /// Tag of the series poster (for an episode, which shows its series').
    #[serde(default)]
    #[uniffi(default = None)]
    pub series_primary_image_tag: Option<String>,
    /// Tags of the parent's backgrounds (for an episode, which shows its series' background).
    #[serde(default)]
    #[uniffi(default = [])]
    pub parent_backdrop_image_tags: Vec<String>,
}

/// Tag of an image: used to refresh the cache when the image changes on the server.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct ImageTag {
    /// `Primary`, `Logo`…
    pub kind: String,
    pub tag: String,
}

/// Accepts the Jellyfin object `{ "Primary": "<tag>" }` or the list written by the disk cache.
pub(crate) fn deserialize_image_tags<'de, D>(deserializer: D) -> Result<Vec<ImageTag>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Shape {
        Map(std::collections::BTreeMap<String, String>),
        List(Vec<ImageTag>),
    }
    Ok(match Option::<Shape>::deserialize(deserializer)? {
        Some(Shape::Map(m)) => m
            .into_iter()
            .map(|(kind, tag)| ImageTag { kind, tag })
            .collect(),
        Some(Shape::List(l)) => l,
        None => Vec::new(),
    })
}

/// Deserialises `primary_blur_hash` from either a direct string (e.g. disk cache `"PrimaryBlurHash": "..."`),
/// or a Jellyfin object `"ImageBlurHashes": { "Primary": { "<tag>": "<hash>" } }` or `"ImageBlurHashes": { "Primary": "<hash>" }`.
pub(crate) fn deserialize_primary_blur_hash<'de, D>(
    deserializer: D,
) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let opt = Option::<serde_json::Value>::deserialize(deserializer)?;
    let Some(val) = opt else {
        return Ok(None);
    };

    match val {
        serde_json::Value::String(s) => {
            let trimmed = s.trim();
            if trimmed.is_empty() {
                Ok(None)
            } else {
                Ok(Some(trimmed.to_string()))
            }
        }
        serde_json::Value::Object(map) => {
            let primary_val = map.get("Primary").or_else(|| map.get("primary"));
            match primary_val {
                Some(serde_json::Value::String(s)) => {
                    let trimmed = s.trim();
                    if trimmed.is_empty() {
                        Ok(None)
                    } else {
                        Ok(Some(trimmed.to_string()))
                    }
                }
                Some(serde_json::Value::Object(sub_map)) => {
                    let mut entries: Vec<(&String, &serde_json::Value)> = sub_map.iter().collect();
                    entries.sort_by_key(|(k, _)| *k);
                    for (_, v) in entries {
                        if let serde_json::Value::String(s) = v {
                            let trimmed = s.trim();
                            if !trimmed.is_empty() {
                                return Ok(Some(trimmed.to_string()));
                            }
                        }
                    }
                    Ok(None)
                }
                _ => Ok(None),
            }
        }
        _ => Ok(None),
    }
}

/// Jellyfin stores BlurHashes in `ImageBlurHashes.{Primary,Backdrop}.<tag>`: we copy the background one
/// into `BackdropBlurHash` (flat field of `Movie`) for every item of the response.
pub(crate) fn copy_backdrop_blur_hashes(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Array(list) => list.iter_mut().for_each(copy_backdrop_blur_hashes),
        serde_json::Value::Object(map) => {
            if let Some(items) = map.get_mut("Items") {
                copy_backdrop_blur_hashes(items);
            }
            let hash = map
                .get("ImageBlurHashes")
                .and_then(|h| h.get("Backdrop"))
                .and_then(|b| match b {
                    serde_json::Value::String(s) => Some(s.clone()),
                    serde_json::Value::Object(tags) => {
                        let mut entries: Vec<_> = tags.iter().collect();
                        entries.sort_by_key(|(k, _)| k.as_str());
                        entries
                            .into_iter()
                            .find_map(|(_, v)| v.as_str().map(str::to_string))
                    }
                    _ => None,
                })
                .filter(|h| !h.trim().is_empty());
            if let Some(hash) = hash {
                map.insert("BackdropBlurHash".into(), serde_json::Value::String(hash));
            }
        }
        _ => {}
    }
}

impl Movie {
    pub fn duration_minutes(&self) -> Option<i64> {
        self.run_time_ticks.map(|t| t / 600_000_000)
    }
}

/// Content of the home screen.
#[derive(Debug, Clone, Default, Serialize, Deserialize, uniffi::Record)]
pub struct Home {
    /// Movies and episodes in progress, most recently watched first.
    pub resume: Vec<Movie>,
    /// Next episodes to watch (series in progress).
    pub next_up: Vec<Movie>,
    /// Recently added movies and episodes, most recent first.
    pub latest: Vec<Movie>,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum ImageKind {
    /// Affiche (format portrait).
    Primary,
    /// Background image (landscape format).
    Backdrop,
    /// Graphic logo of the title (clearlogo).
    Logo,
}

/// Separate subtitle file (e.g. movie.fr.srt next to the movie).
#[derive(Debug, Clone, uniffi::Record)]
pub struct ExternalSubtitle {
    pub url: String,
    pub title: String,
    pub language: Option<String>,
}

/// State of a Quick Connect session.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct QuickConnectState {
    pub code: String,
    pub secret: String,
    #[serde(default)]
    pub authenticated: bool,
}

/// A Jellyfin user library (Movies, Series, Cartoons...).
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record, PartialEq, Eq)]
#[serde(rename_all = "PascalCase")]
pub struct UserView {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub collection_type: Option<String>,
    #[serde(
        default,
        deserialize_with = "deserialize_primary_blur_hash",
        alias = "ImageBlurHashes"
    )]
    pub primary_blur_hash: Option<String>,
}

/// Paged result of a library items request.
#[derive(Debug, Clone, Default, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct LibraryPage {
    pub items: Vec<Movie>,
    pub total_record_count: u32,
    pub start_index: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub(crate) struct AuthResponse {
    pub(crate) access_token: String,
    pub(crate) server_id: Option<String>,
    pub(crate) user: User,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub(crate) struct User {
    pub(crate) id: String,
    pub(crate) name: Option<String>,
    pub(crate) server_id: Option<String>,
}

/// Passage spotted by the server in an episode or a movie (opening, end credits…), Jellyfin 10.10+.
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct MediaSegment {
    /// "Intro", "Outro", "Recap", "Preview", "Commercial"…
    #[serde(rename = "Type")]
    pub kind: String,
    pub start_ticks: i64,
    pub end_ticks: i64,
}

/// What the server knows about the playback of an item (for the conflict rule of offline reports).
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct UserDataState {
    pub last_played_unix: Option<i64>,
    pub run_time_ticks: Option<i64>,
}

/// The signed-in user, as the server describes them.
#[derive(Debug, Clone, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct CurrentUser {
    pub id: String,
    pub name: String,
    /// Tag of the profile picture (absent if the user has none).
    #[serde(default, rename = "PrimaryImageTag")]
    pub avatar_tag: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub(crate) struct ItemsResponse<T = Movie> {
    pub(crate) items: Vec<T>,
    #[serde(default)]
    pub(crate) total_record_count: Option<u32>,
}

/// Allows deserialising either an envelope `{"Items": [...]}` or a raw list `[...]` indifferently.
#[derive(Deserialize)]
#[serde(untagged)]
pub(crate) enum ItemsOrList {
    Object(ItemsResponse<Movie>),
    List(Vec<Movie>),
}

impl ItemsOrList {
    pub(crate) fn into_vec(self) -> Vec<Movie> {
        match self {
            Self::Object(r) => r.items,
            Self::List(l) => l,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub(crate) struct ItemWithSources {
    #[serde(default)]
    pub(crate) media_sources: Vec<MediaSource>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub(crate) struct MediaSource {
    pub(crate) id: String,
    #[serde(default)]
    pub(crate) media_streams: Vec<MediaStream>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub(crate) struct MediaStream {
    #[serde(rename = "Type")]
    pub(crate) kind: String,
    pub(crate) index: i32,
    pub(crate) codec: Option<String>,
    pub(crate) language: Option<String>,
    pub(crate) display_title: Option<String>,
    #[serde(default)]
    pub(crate) is_external: bool,
}
