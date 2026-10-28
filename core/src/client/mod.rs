//! The Jellyfin HTTP client. Exported methods are split by topic in the sibling files.

mod library;
mod media;
#[cfg(test)]
mod tests;

use crate::*;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

#[derive(uniffi::Object)]
pub struct JellyfinClient {
    /// `Err` if the HTTP client could not be built: every request then fails cleanly.
    http: Result<reqwest::Client, String>,
    server_url: Mutex<String>,
    /// Folder where the latest server responses are kept (see "Cache").
    cache_dir: PathBuf,
    // Mutex: the session can be modified even if the client is shared.
    session: Mutex<Option<SessionInfo>>,
    /// Unique identifier of this installation, sent to the server in the authentication header.
    device_id: String,
    /// Cached open SQLite store for the active profile, avoiding reopening and schema checks on every access (P11).
    profile_store: Mutex<Option<(PathBuf, store::ProfileStore)>>,
}

fn read_device_id(cache_dir: &Path) -> Option<String> {
    let id = std::fs::read_to_string(cache_dir.join(DEVICE_ID_FILE)).ok()?;
    let id = id.trim();
    (!id.is_empty()).then(|| id.to_string())
}

/// Reads the identifier of this installation, or creates one and keeps it on disk.
fn load_or_create_device_id(cache_dir: &Path) -> String {
    if let Some(id) = read_device_id(cache_dir) {
        return id;
    }
    let id = format!("playfin-{}", uuid::Uuid::new_v4());
    let _ = std::fs::create_dir_all(cache_dir);
    let _ = std::fs::write(cache_dir.join(DEVICE_ID_FILE), &id);
    id
}

impl JellyfinClient {
    /// Last known server read and duration of an item.
    pub(crate) async fn user_data_state(
        &self,
        item_id: &str,
    ) -> Result<UserDataState, JellyfinError> {
        #[derive(Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct Data {
            last_played_date: Option<String>,
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct Item {
            run_time_ticks: Option<i64>,
            user_data: Option<Data>,
        }
        let user_id = self.user_id()?;
        let response: ItemsResponse<Item> = self
            .get_json(
                "/Items",
                &[
                    ("userId", user_id.as_str()),
                    ("ids", item_id),
                    ("fields", "UserData"),
                ],
            )
            .await?;
        let item = response.items.into_iter().next();
        Ok(UserDataState {
            last_played_unix: item
                .as_ref()
                .and_then(|i| i.user_data.as_ref())
                .and_then(|d| d.last_played_date.as_deref())
                .and_then(parse_iso8601_utc),
            run_time_ticks: item.and_then(|i| i.run_time_ticks),
        })
    }

    /// Records on the server a position made offline (`POST /UserItems/{id}/UserData`).
    pub(crate) async fn save_user_data(
        &self,
        item_id: &str,
        position_ticks: i64,
        played: bool,
        played_at_unix: i64,
    ) -> Result<(), JellyfinError> {
        let user_id = self.user_id()?;
        let body = serde_json::json!({
            "PlaybackPositionTicks": if played { 0 } else { position_ticks.max(0) },
            "Played": played,
            "LastPlayedDate": format_iso8601_utc(played_at_unix),
        });
        self.send(
            self.http()?
                .post(self.url(&format!("/UserItems/{item_id}/UserData")))
                .query(&[("userId", user_id.as_str())])
                .json(&body),
        )
        .await?;
        Ok(())
    }

    fn http(&self) -> Result<&reqwest::Client, JellyfinError> {
        self.http
            .as_ref()
            .map_err(|e| JellyfinError::Network(format!("HTTP client unavailable: {e}")))
    }

    fn build(server_url: &str, cache_dir: &str, device_id: String) -> Self {
        Self {
            device_id,
            http: reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(3))
                .timeout(Duration::from_secs(20))
                .build()
                .map_err(|e| e.to_string()),
            server_url: Mutex::new(server_url.trim_end_matches('/').to_string()),
            cache_dir: PathBuf::from(cache_dir),
            session: Mutex::new(None),
            profile_store: Mutex::new(None),
        }
    }
}

// Session: construction, addresses, sign-in, Quick Connect, sign-out.
#[uniffi::export(async_runtime = "tokio")]
impl JellyfinClient {
    #[uniffi::constructor]
    pub fn new(server_url: &str, cache_dir: &str) -> Self {
        let device_id = load_or_create_device_id(Path::new(cache_dir));
        Self::build(server_url, cache_dir, device_id)
    }

    /// Recreates a signed-in client from a saved session.
    #[uniffi::constructor]
    pub fn restore(info: SessionInfo, cache_dir: &str) -> Self {
        // A session created before the per-installation identifier keeps the old one until the next sign-in.
        let device_id =
            read_device_id(Path::new(cache_dir)).unwrap_or_else(|| LEGACY_DEVICE_ID.to_string());
        let client = Self::build(&info.server_url, cache_dir, device_id);
        *client.lock_session() = Some(info);
        client
    }

    /// Current session, to be saved to stay signed in.
    pub fn session_info(&self) -> Option<SessionInfo> {
        self.lock_session().clone()
    }

    /// Address of the Jellyfin server.
    pub fn server_url(&self) -> String {
        self.server_url
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// Changes the active address used to talk to the server.
    pub fn set_server_url(&self, new_url: &str) {
        let trimmed = new_url.trim_end_matches('/').to_string();
        *self.server_url.lock().unwrap_or_else(|e| e.into_inner()) = trimmed.clone();
        let mut session = self.lock_session();
        if let Some(ref mut info) = *session {
            info.server_url = trimmed;
        }
    }

    /// Probes a list of addresses for this server and automatically switches to the best one.
    pub async fn auto_select_address(
        &self,
        addresses: Vec<ServerAddress>,
        expected_server_id: &str,
    ) -> Result<ServerAddress, JellyfinError> {
        let best = profiles::select_active_address(
            self.http()?,
            &addresses,
            expected_server_id,
            Duration::from_millis(1500),
        )
        .await?;
        self.set_server_url(&best.url);
        Ok(best)
    }

    /// Reacts to a network change and automatically switches to the best available address.
    pub async fn on_network_changed(
        &self,
        addresses: Vec<ServerAddress>,
        expected_server_id: &str,
    ) -> Result<Option<ServerAddress>, JellyfinError> {
        if addresses.is_empty() {
            return Err(JellyfinError::InvalidInput(
                "No address provided for the server check".into(),
            ));
        }
        let best = self
            .auto_select_address(addresses, expected_server_id)
            .await?;
        Ok(Some(best))
    }

    /// Identifier of the server: that of the authentication response, otherwise the one read from the server.
    /// Never a fallback value: without a reliable identifier, the server identity check
    /// (address change) would be bypassed, so the error is passed on.
    async fn resolve_server_id(
        &self,
        from_response: Option<String>,
        url: &str,
        access_token: &str,
    ) -> Result<String, JellyfinError> {
        if let Some(id) = from_response.filter(|id| !id.is_empty()) {
            return Ok(id);
        }
        match profiles::probe_server_address(self.http()?, url, Duration::from_millis(2000)).await {
            Ok(info) => Ok(info.id),
            Err(err) => {
                // The server already created a token for this sign-in: we revoke it as best we can.
                self.revoke_token_best_effort(url, access_token).await;
                Err(err)
            }
        }
    }

    /// Closes the session of a token we do not keep. No visible effect if the server does not answer.
    async fn revoke_token_best_effort(&self, url: &str, access_token: &str) {
        let device_id = &self.device_id;
        let header = format!(
            r#"MediaBrowser Client="{CLIENT}", Device="{DEVICE}", DeviceId="{device_id}", Version="{VERSION}", Token="{access_token}""#
        );
        let Ok(http) = self.http() else { return };
        let _ = http
            .post(format!("{url}/Sessions/Logout"))
            .header("Authorization", header)
            .timeout(Duration::from_secs(3))
            .send()
            .await;
    }

    /// Unique identifier of the server (returned by Jellyfin or retrieved during sign-in).
    pub fn server_id(&self) -> Option<String> {
        self.lock_session().as_ref().map(|s| s.server_id.clone())
    }

    /// Sign-in with username and password.
    pub async fn login(&self, username: &str, password: &str) -> Result<(), JellyfinError> {
        let body = serde_json::json!({ "Username": username, "Pw": password });
        let response: AuthResponse = self
            .send(
                self.http()?
                    .post(self.url("/Users/AuthenticateByName"))
                    .json(&body),
            )
            .await?
            .json()
            .await?;

        let current_url = self.server_url();
        let server_id = self
            .resolve_server_id(
                response.server_id.or(response.user.server_id),
                &current_url,
                &response.access_token,
            )
            .await?;

        *self.lock_session() = Some(SessionInfo {
            server_url: current_url,
            server_id,
            user_id: response.user.id,
            access_token: response.access_token,
        });
        Ok(())
    }

    /// Starts the Quick Connect process and generates a temporary code to show to the user.
    pub async fn quick_connect_initiate(&self) -> Result<QuickConnectState, JellyfinError> {
        let response: QuickConnectState = self
            .send(
                self.http()?
                    .post(self.url("/QuickConnect/Initiate"))
                    .json(&serde_json::json!({})),
            )
            .await?
            .json()
            .await?;
        Ok(response)
    }

    /// Checks whether the Quick Connect code was approved on another device.
    pub async fn quick_connect_poll(&self, secret: &str) -> Result<bool, JellyfinError> {
        let response: QuickConnectState = self
            .send(
                self.http()?
                    .get(self.url("/QuickConnect/Connect"))
                    .query(&[("secret", secret)]),
            )
            .await?
            .json()
            .await?;
        Ok(response.authenticated)
    }

    /// Completes the Quick Connect authentication once the code is approved.
    /// Returns the username associated with the signed-in account.
    pub async fn quick_connect_authenticate(&self, secret: &str) -> Result<String, JellyfinError> {
        let body = serde_json::json!({ "Secret": secret });
        let response: AuthResponse = self
            .send(
                self.http()?
                    .post(self.url("/Users/AuthenticateWithQuickConnect"))
                    .json(&body),
            )
            .await?
            .json()
            .await?;

        let current_url = self.server_url();
        let server_id = self
            .resolve_server_id(
                response.server_id.or(response.user.server_id),
                &current_url,
                &response.access_token,
            )
            .await?;

        let user_name = response.user.name.unwrap_or_else(|| "User".to_string());

        *self.lock_session() = Some(SessionInfo {
            server_url: current_url,
            server_id,
            user_id: response.user.id,
            access_token: response.access_token,
        });
        Ok(user_name)
    }

    /// Sign-out: the token is no longer valid on the server.
    pub async fn logout(&self) -> Result<(), JellyfinError> {
        let result = self.post("/Sessions/Logout", serde_json::json!({})).await;
        self.clear_cache();
        *self.lock_session() = None;
        result
    }
}

// Internal functions, not visible from Swift.
impl JellyfinClient {
    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.server_url())
    }

    /// One subfolder per profile (server identifier + user identifier).
    /// Only letters, digits and "-" are kept:
    /// identifiers come from the server, they must never be able to escape the folder.
    fn profile_cache_dir(&self) -> Option<PathBuf> {
        let (server_id, user_id) = {
            let session = self.lock_session();
            let s = session.as_ref()?;
            (s.server_id.clone(), s.user_id.clone())
        };
        let clean_user: String = user_id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
            .collect();
        if clean_user.is_empty() {
            return None;
        }

        let clean_server: String = server_id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
            .collect();

        if clean_server.is_empty() {
            Some(self.cache_dir.join(clean_user))
        } else {
            Some(self.cache_dir.join(clean_server).join(clean_user))
        }
    }

    /// Backwards compatibility / internal alias for the profile cache folder.
    pub fn user_cache_dir(&self) -> Option<PathBuf> {
        self.profile_cache_dir()
    }

    /// Executes an operation on the cached SQLite profile store, opening it on first access or when profile path changes (P11).
    fn with_profile_store<R>(&self, f: impl FnOnce(&mut store::ProfileStore) -> R) -> Option<R> {
        let expected_path = self.profile_cache_dir()?.join("profile.sqlite");
        let mut guard = self.profile_store.lock().ok()?;

        let is_match = guard.as_ref().is_some_and(|(p, _)| *p == expected_path);
        if !is_match {
            let new_store = store::ProfileStore::open(&expected_path).ok()?;
            *guard = Some((expected_path, new_store));
        }

        let (_, store) = guard.as_mut()?;
        Some(f(store))
    }

    fn cached_views(&self) -> Vec<UserView> {
        self.with_profile_store(|store| store.library_jsons().ok())
            .flatten()
            .map(|rows| {
                rows.iter()
                    .filter_map(|json| serde_json::from_str(json).ok())
                    .collect()
            })
            .unwrap_or_default()
    }

    fn store_views(&self, views: &[UserView]) {
        let rows: Vec<(String, String, String)> = views
            .iter()
            .filter_map(|v| {
                serde_json::to_string(v)
                    .ok()
                    .map(|json| (v.id.clone(), v.name.clone(), json))
            })
            .collect();
        let _ = self.with_profile_store(|store| {
            let _ = store.replace_libraries(&rows);
        });
    }

    fn cache_read<T: DeserializeOwned>(&self, name: &str) -> Option<T> {
        let path = self.profile_cache_dir()?.join(format!("{name}.json"));
        serde_json::from_slice(&std::fs::read(path).ok()?).ok()
    }

    /// The cache is a convenience: if it cannot be written, we carry on without it.
    fn cache_write<T: Serialize>(&self, name: &str, value: &T) {
        let Some(dir) = self.profile_cache_dir() else {
            return;
        };
        let Ok(json) = serde_json::to_vec(value) else {
            return;
        };
        if std::fs::create_dir_all(&dir).is_err() {
            return;
        }
        // Temporary file then rename: we never read a half-written file.
        let tmp = dir.join(format!("{name}.json.tmp"));
        if std::fs::write(&tmp, json).is_ok() {
            let _ = std::fs::rename(tmp, dir.join(format!("{name}.json")));
        }
    }

    fn lock_session(&self) -> std::sync::MutexGuard<'_, Option<SessionInfo>> {
        self.session.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn user_id(&self) -> Result<String, JellyfinError> {
        let session = self.lock_session();
        Ok(session
            .as_ref()
            .ok_or(JellyfinError::NotLoggedIn)?
            .user_id
            .clone())
    }

    /// Authentication header expected by Jellyfin.
    pub(crate) fn auth_header(&self) -> String {
        let device_id = &self.device_id;
        let mut header = format!(
            r#"MediaBrowser Client="{CLIENT}", Device="{DEVICE}", DeviceId="{device_id}", Version="{VERSION}""#
        );
        if let Some(session) = self.lock_session().as_ref() {
            header.push_str(&format!(r#", Token="{}""#, session.access_token));
        }
        header
    }

    /// Sends a request with the authentication header and checks the response.
    async fn send(
        &self,
        request: reqwest::RequestBuilder,
    ) -> Result<reqwest::Response, JellyfinError> {
        let response = request
            .header("Authorization", self.auth_header())
            .send()
            .await?;
        if response.status() == reqwest::StatusCode::UNAUTHORIZED {
            return Err(JellyfinError::Unauthorized);
        }
        if response.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(JellyfinError::NotFound(response.url().path().to_string()));
        }
        if response.status() == reqwest::StatusCode::FORBIDDEN {
            return Err(JellyfinError::Forbidden(response.url().path().to_string()));
        }
        let status = response.status();
        if status.is_server_error() {
            return Err(JellyfinError::ServerError {
                code: status.as_u16(),
                message: status.to_string(),
            });
        }
        Ok(response.error_for_status()?)
    }

    async fn get_json<T: DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, &str)],
    ) -> Result<T, JellyfinError> {
        let request = self.http()?.get(self.url(path)).query(query);
        let mut value: serde_json::Value = self.send(request).await?.json().await?;
        copy_backdrop_blur_hashes(&mut value);
        serde_json::from_value(value).map_err(|e| JellyfinError::Decode(e.to_string()))
    }

    async fn post(&self, path: &str, body: serde_json::Value) -> Result<(), JellyfinError> {
        self.send(self.http()?.post(self.url(path)).json(&body))
            .await?;
        Ok(())
    }

    async fn delete(&self, path: &str) -> Result<(), JellyfinError> {
        self.send(self.http()?.delete(self.url(path))).await?;
        Ok(())
    }
}
