use super::*;

// Images, streams, subtitles, playback reports and watched state.
#[uniffi::export(async_runtime = "tokio")]
impl JellyfinClient {
    /// Address of an image (poster, background or logo). No need to be signed in.
    /// If `tag` is provided, it is added to the address: the image is reloaded when it changes on the server.
    pub fn image_url(
        &self,
        item_id: &str,
        kind: ImageKind,
        max_height: u32,
        tag: Option<String>,
    ) -> String {
        let kind = match kind {
            ImageKind::Primary => "Primary",
            ImageKind::Backdrop => "Backdrop",
            ImageKind::Logo => "Logo",
        };
        let tag = tag
            .map(|t| {
                // Jellyfin tags are hexadecimal: any other character is dropped.
                t.chars()
                    .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
                    .collect::<String>()
            })
            .filter(|t| !t.is_empty())
            .map(|t| format!("&tag={t}"))
            .unwrap_or_default();
        format!(
            "{}/Items/{item_id}/Images/{kind}?maxHeight={max_height}&quality=90{tag}",
            self.server_url()
        )
    }

    /// Segments spotted (intro, credits…) of an item. Empty if the server does not offer them (before 10.10)
    /// or if the plugin analysed nothing: this is never an error for playback.
    pub async fn media_segments(&self, item_id: String) -> Vec<MediaSegment> {
        let path = format!("/MediaSegments/{item_id}");
        let response: Result<ItemsResponse<MediaSegment>, _> = self.get_json(&path, &[]).await;
        let mut segments: Vec<MediaSegment> = response
            .map(|r| r.items)
            .unwrap_or_default()
            .into_iter()
            .filter(|s| s.end_ticks > s.start_ticks)
            .collect();
        segments.sort_by_key(|s| s.start_ticks);
        segments
    }

    /// Does the administrator allow downloads for this account? (`Policy.EnableContentDownloading`)
    pub async fn can_download(&self) -> Result<bool, JellyfinError> {
        #[derive(Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct Policy {
            #[serde(default = "yes")]
            enable_content_downloading: bool,
        }
        fn yes() -> bool {
            true
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct Me {
            policy: Option<Policy>,
        }
        let me: Me = self.get_json("/Users/Me", &[]).await?;
        Ok(me.policy.is_none_or(|p| p.enable_content_downloading))
    }

    /// The signed-in user (name and tag of their profile picture).
    pub async fn current_user(&self) -> Result<CurrentUser, JellyfinError> {
        let user_id = self.user_id()?;
        self.get_json(&format!("/Users/{user_id}"), &[]).await
    }

    /// Address of a user's profile picture (with its tag, to refresh the cache).
    pub fn user_image_url(&self, user_id: &str, tag: &str, max_height: u32) -> String {
        let tag: String = tag
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
            .collect();
        format!(
            "{}/Users/{user_id}/Images/Primary?maxHeight={max_height}&quality=90&tag={tag}",
            self.server_url()
        )
    }

    /// Address of the picture of a person (actor or director).
    pub fn person_image_url(&self, person_id: &str, max_height: u32) -> String {
        format!(
            "{}/Items/{person_id}/Images/Primary?maxHeight={max_height}&quality=90",
            self.server_url()
        )
    }

    /// Address of the original file (Direct Play: no conversion by the server).
    pub fn stream_url(&self, item_id: &str) -> String {
        format!("{}/Videos/{item_id}/stream?static=true", self.server_url())
    }

    /// Address of an audio file (audiobook, music) in direct play.
    pub fn audio_stream_url(&self, item_id: &str) -> String {
        format!("{}/Audio/{item_id}/stream?static=true", self.server_url())
    }

    /// HTTP header to give to the video player so that it is allowed to play.
    pub fn playback_header(&self) -> Result<String, JellyfinError> {
        let session = self.lock_session();
        let token = &session
            .as_ref()
            .ok_or(JellyfinError::NotLoggedIn)?
            .access_token;
        Ok(format!(r#"Authorization: MediaBrowser Token="{token}""#))
    }

    /// Subtitles as separate files, which the player must load itself.
    pub async fn external_subtitles(
        &self,
        item_id: &str,
    ) -> Result<Vec<ExternalSubtitle>, JellyfinError> {
        let user_id = self.user_id()?;
        let item: ItemWithSources = self
            .get_json(
                &format!("/Items/{item_id}"),
                &[("userId", user_id.as_str())],
            )
            .await?;

        let Some(source) = item.media_sources.first() else {
            return Ok(Vec::new());
        };
        let subtitles = source
            .media_streams
            .iter()
            .filter(|s| s.kind == "Subtitle" && s.is_external)
            .map(|s| {
                // Jellyfin calls the SRT format "subrip".
                let format = match s.codec.as_deref() {
                    Some("subrip") | None => "srt",
                    Some(codec) => codec,
                };
                ExternalSubtitle {
                    url: format!(
                        "{}/Videos/{item_id}/{}/Subtitles/{}/Stream.{format}",
                        self.server_url(),
                        source.id,
                        s.index
                    ),
                    title: s.display_title.clone().unwrap_or_else(|| "Externe".into()),
                    language: s.language.clone(),
                }
            })
            .collect();
        Ok(subtitles)
    }

    // ── Playback tracking (to resume where we stopped) ──

    pub async fn report_playback_start(
        &self,
        item_id: &str,
        position_ticks: i64,
    ) -> Result<(), JellyfinError> {
        let body = serde_json::json!({
            "ItemId": item_id,
            "PositionTicks": position_ticks,
            "PlayMethod": "DirectPlay",
            "CanSeek": true,
        });
        self.post("/Sessions/Playing", body).await
    }

    pub async fn report_playback_progress(
        &self,
        item_id: &str,
        position_ticks: i64,
        is_paused: bool,
    ) -> Result<(), JellyfinError> {
        let body = serde_json::json!({
            "ItemId": item_id,
            "PositionTicks": position_ticks,
            "IsPaused": is_paused,
            "PlayMethod": "DirectPlay",
            "CanSeek": true,
        });
        self.post("/Sessions/Playing/Progress", body).await
    }

    pub async fn report_playback_stopped(
        &self,
        item_id: &str,
        position_ticks: i64,
    ) -> Result<(), JellyfinError> {
        let body = serde_json::json!({ "ItemId": item_id, "PositionTicks": position_ticks });
        self.post("/Sessions/Playing/Stopped", body).await
    }

    /// Marks a movie or episode as watched.
    pub async fn mark_as_played(&self, item_id: &str) -> Result<(), JellyfinError> {
        let user_id = self.user_id()?;
        let path = format!("/UserPlayedItems/{item_id}?userId={user_id}");
        self.post(&path, serde_json::json!({})).await
    }

    /// Marks a movie or episode as unwatched.
    pub async fn mark_as_unplayed(&self, item_id: &str) -> Result<(), JellyfinError> {
        let user_id = self.user_id()?;
        let path = format!("/UserPlayedItems/{item_id}?userId={user_id}");
        self.delete(&path).await
    }

    /// Adds an item to the user's favourites.
    pub async fn mark_as_favorite(&self, item_id: &str) -> Result<(), JellyfinError> {
        let user_id = self.user_id()?;
        let path = format!("/UserFavoriteItems/{item_id}?userId={user_id}");
        self.post(&path, serde_json::json!({})).await
    }

    /// Removes an item from the user's favourites.
    pub async fn unmark_as_favorite(&self, item_id: &str) -> Result<(), JellyfinError> {
        let user_id = self.user_id()?;
        let path = format!("/UserFavoriteItems/{item_id}?userId={user_id}");
        self.delete(&path).await
    }
}
