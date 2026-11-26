//! Pure-Rust Starfish playback spike controller (`com.webos.media` + `libplayerAPIs` symbol probe).

use crate::exported_window::{ExportedVideoWindow, probe_support as probe_exported_window};
use crate::luna::{LunaClient, LunaMessage, probe_runtime as probe_luna_runtime};
use crate::spike_config::{AuthTransportMode, redact_url_for_log};
use serde_json::{Value, json};
use std::ffi::{CStr, c_void};
use std::sync::mpsc;

/// Stream kind exercised in the Task 0.4 LG C1 matrix.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamKind {
    MkvDirect,
    HlsRemux,
    AudioCodecTest,
}

/// Live UI-visible summary of the Spike 0.4 media pipeline and runtime probes.
#[derive(Debug, Clone, Default)]
pub struct StarfishStatus {
    pub runtime_probe: String,
    pub playback_state: String,
    pub media_id: Option<String>,
    pub window_id: Option<String>,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub video_info: String,
    pub audio_info: String,
    pub current_audio_track: usize,
    pub audio_track_count: usize,
    pub last_event: String,
}

/// Checks if `libplayerAPIs.so` is readable in the sandbox and which Starfish symbols it exports.
/// Does NOT call the C++ constructor so firmwares checking process role cannot terminate the app.
pub fn probe_inprocess_starfish_symbols() -> String {
    #[cfg(unix)]
    {
        // SAFETY: `RTLD_LAZY` inspects symbol table without invoking class constructors.
        let handle = unsafe { libc::dlopen(c"libplayerAPIs.so.1".as_ptr(), libc::RTLD_LAZY) };
        let handle = if handle.is_null() {
            // SAFETY: Fallback unversioned SONAME probe.
            unsafe { libc::dlopen(c"libplayerAPIs.so".as_ptr(), libc::RTLD_LAZY) }
        } else {
            handle
        };
        if handle.is_null() {
            return "libplayerAPIs: absent".to_string();
        }
        let checks: [(&str, &CStr); 4] = [
            ("C1", c"_ZN17StarfishMediaAPIsC1EPKc"),
            ("LoadCtx", c"_ZN17StarfishMediaAPIs4LoadEPKcPFvixS1_PvES2_"),
            ("Seek", c"_ZN17StarfishMediaAPIs4SeekEPKc"),
            ("Unload", c"_ZN17StarfishMediaAPIs6UnloadEv"),
        ];
        let mut found = Vec::new();
        for (label, sym) in checks {
            // SAFETY: `handle` is non-null and `sym` is static NUL-terminated.
            let ptr: *mut c_void = unsafe { libc::dlsym(handle, sym.as_ptr()) };
            if !ptr.is_null() {
                found.push(label);
            }
        }
        // SAFETY: Balances `dlopen` cleanly.
        unsafe {
            libc::dlclose(handle);
        }
        if found.is_empty() {
            "libplayerAPIs: opened (0 symbols)".to_string()
        } else {
            format!("libplayerAPIs: OK ({})", found.join(","))
        }
    }
    #[cfg(not(unix))]
    {
        "libplayerAPIs: non-unix".to_string()
    }
}

/// Runs non-destructive runtime probes for Gate 1 / Spike 0.4 (`LS2`, `SDL_webOS`, `libplayerAPIs`).
pub fn collect_runtime_probe_summary() -> String {
    let ls2 = match probe_luna_runtime() {
        Ok(s) => s,
        Err(e) => e,
    };
    let win = probe_exported_window().detail;
    let smp = probe_inprocess_starfish_symbols();
    format!("{ls2} | {win} | {smp}")
}

/// Appends `api_key` cleanly to `url` only when `QueryApiKey` mode is selected.
pub fn attach_auth_query(url: &str, api_key: Option<&str>, mode: AuthTransportMode) -> String {
    match (mode, api_key) {
        (AuthTransportMode::QueryApiKey, Some(key)) if !key.is_empty() => {
            let sep = if url.contains('?') { '&' } else { '?' };
            format!("{url}{sep}api_key={key}")
        }
        _ => url.to_string(),
    }
}

/// Builds the JSON payload sent to `luna://com.webos.media/load`.
pub fn build_load_payload(
    url: &str,
    kind: StreamKind,
    window_id: &str,
    app_id: &str,
    api_key: Option<&str>,
    auth_mode: AuthTransportMode,
) -> (String, String) {
    let effective_uri = attach_auth_query(url, api_key, auth_mode);
    let mut option = json!({
        "appId": app_id,
        "windowId": window_id,
    });
    if let Some(obj) = option.as_object_mut() {
        if kind == StreamKind::HlsRemux {
            obj.insert("mediaTransportType".to_string(), json!("HLS"));
        }
        if auth_mode == AuthTransportMode::HttpHeader
            && let Some(key) = api_key
            && !key.is_empty()
        {
            obj.insert(
                "transmission".to_string(),
                json!({
                    "httpHeader": {
                        "X-Emby-Token": key
                    }
                }),
            );
        }
    }

    let body = json!({
        "uri": effective_uri,
        "type": "media",
        "payload": {
            "option": option
        }
    })
    .to_string();
    (effective_uri, body)
}

/// Drives LG webOS `com.webos.media` + `ExportedVideoWindow` completely from pure Rust.
pub struct StarfishController {
    app_id: String,
    luna: Option<LunaClient>,
    rx: Option<mpsc::Receiver<LunaMessage>>,
    window: Option<ExportedVideoWindow>,
    subscribed_media_id: Option<String>,
    pub status: StarfishStatus,
}

impl StarfishController {
    pub fn new(app_id: String) -> Self {
        let probe = collect_runtime_probe_summary();
        eprintln!("[playfin_webos] runtime probe: {probe}");
        Self {
            app_id,
            luna: None,
            rx: None,
            window: None,
            subscribed_media_id: None,
            status: StarfishStatus {
                runtime_probe: probe,
                playback_state: "Idle".to_string(),
                video_info: "none".to_string(),
                audio_info: "none".to_string(),
                last_event: "ready".to_string(),
                ..StarfishStatus::default()
            },
        }
    }

    pub fn refresh_probe(&mut self) {
        self.status.runtime_probe = collect_runtime_probe_summary();
        eprintln!(
            "[playfin_webos] runtime probe: {}",
            self.status.runtime_probe
        );
    }

    /// Loads `url` into the hardware pipeline via `com.webos.media/load` + SDL exported window.
    pub fn load_stream(
        &mut self,
        url: &str,
        kind: StreamKind,
        api_key: Option<&str>,
        auth_mode: AuthTransportMode,
    ) {
        self.unload();

        if self.luna.is_none() {
            match LunaClient::connect(Some(&self.app_id)) {
                Ok((client, rx)) => {
                    self.status.last_event =
                        format!("LS2 connected ({})", client.registration_shape());
                    self.luna = Some(client);
                    self.rx = Some(rx);
                }
                Err(err) => {
                    self.status.playback_state = format!("LS2 error: {err}");
                    self.status.last_event = self.status.playback_state.clone();
                    return;
                }
            }
        }

        if self.window.is_none() {
            match ExportedVideoWindow::create(1920, 1080) {
                Ok(win) => {
                    let _ = win.place(1920, 1080);
                    self.status.window_id = Some(win.window_id().to_string());
                    self.window = Some(win);
                }
                Err(err) => {
                    self.status.playback_state = format!("Window error: {err}");
                    self.status.last_event = self.status.playback_state.clone();
                    return;
                }
            }
        }

        let window_id = self
            .window
            .as_ref()
            .map(|w| w.window_id().to_string())
            .unwrap_or_default();
        let (_effective_uri, load_json) =
            build_load_payload(url, kind, &window_id, &self.app_id, api_key, auth_mode);
        let safe_url = redact_url_for_log(url);
        eprintln!(
            "[playfin_webos] com.webos.media/load kind={kind:?} auth={} uri={safe_url} window={window_id}",
            auth_mode.label()
        );

        if let Some(client) = &self.luna
            && let Err(err) = client.call_once("luna://com.webos.media/load", &load_json)
        {
            self.status.playback_state = format!("Load call failed: {err}");
            self.status.last_event = self.status.playback_state.clone();
            return;
        }
        self.status.playback_state = format!("Loading ({:?}, {})", kind, auth_mode.label());
        self.status.media_id = None;
        self.subscribed_media_id = None;
    }

    pub fn toggle_play_pause(&mut self) {
        let Some(id) = self.status.media_id.clone() else {
            self.status.last_event = "No active mediaId".to_string();
            return;
        };
        let paused = self.status.playback_state.starts_with("Playing");
        let method = if paused {
            "luna://com.webos.media/pause"
        } else {
            "luna://com.webos.media/play"
        };
        if let Some(client) = &self.luna {
            let payload = json!({ "mediaId": id }).to_string();
            let _ = client.call_once(method, &payload);
            self.status.last_event = format!("Sent {method}");
        }
    }

    pub fn seek_by_ms(&mut self, delta_ms: i64) {
        let Some(id) = self.status.media_id.clone() else {
            self.status.last_event = "No active mediaId".to_string();
            return;
        };
        let target = (self.status.position_ms as i64)
            .saturating_add(delta_ms)
            .max(0) as u64;
        if let Some(client) = &self.luna {
            let payload = json!({ "mediaId": id, "position": target }).to_string();
            let _ = client.call_once("luna://com.webos.media/seek", &payload);
            self.status.last_event = format!("Seek -> {target} ms");
        }
    }

    pub fn cycle_audio_track(&mut self) {
        let Some(id) = self.status.media_id.clone() else {
            self.status.last_event = "No active mediaId".to_string();
            return;
        };
        let max_tracks = self.status.audio_track_count.max(2);
        let next = (self.status.current_audio_track + 1) % max_tracks;
        if let Some(client) = &self.luna {
            let payload = json!({ "mediaId": id, "type": "audio", "index": next }).to_string();
            let _ = client.call_once("luna://com.webos.media/selectTrack", &payload);
            self.status.current_audio_track = next;
            self.status.last_event = format!("selectTrack audio={next}");
        }
    }

    pub fn unload(&mut self) {
        if let (Some(client), Some(id)) = (&self.luna, self.status.media_id.take()) {
            let payload = json!({ "mediaId": id }).to_string();
            let _ = client.call_once("luna://com.webos.media/unload", &payload);
        }
        self.subscribed_media_id = None;
        if self.status.playback_state != "Idle" {
            self.status.playback_state = "Idle".to_string();
        }
    }

    /// Drains asynchronous LS2 replies/events and updates on-screen state + video geometry.
    pub fn poll_events(&mut self) {
        let mut msgs = Vec::new();
        if let Some(rx) = &self.rx {
            while let Ok(msg) = rx.try_recv() {
                msgs.push(msg);
            }
        }
        for msg in msgs {
            self.apply_luna_message(&msg);
        }
    }

    fn apply_luna_message(&mut self, msg: &LunaMessage) {
        let Ok(val) = serde_json::from_str::<Value>(&msg.payload) else {
            self.status.last_event = format!("non-JSON from {}", msg.uri);
            return;
        };

        if val.get("returnValue").and_then(Value::as_bool) == Some(false) {
            let code = val.get("errorCode").and_then(Value::as_i64).unwrap_or(-1);
            let text = val
                .get("errorText")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            self.status.playback_state = format!("Error {code}: {text}");
            self.status.last_event = self.status.playback_state.clone();
            return;
        }

        if let Some(id) = val.get("mediaId").and_then(Value::as_str) {
            self.status.media_id = Some(id.to_string());
            if self.subscribed_media_id.as_deref() != Some(id) {
                self.subscribed_media_id = Some(id.to_string());
                if let Some(client) = &self.luna {
                    let sub_payload = json!({ "mediaId": id, "subscribe": true }).to_string();
                    let _ = client.subscribe("luna://com.webos.media/subscribe", &sub_payload);
                }
            }
        }

        if let Some(ct) = val.get("currentTime").and_then(Value::as_object)
            && let Some(ms) = ct.get("currentTime").and_then(Value::as_u64)
        {
            self.status.position_ms = ms;
        } else if let Some(ms) = val.get("currentTime").and_then(Value::as_u64) {
            self.status.position_ms = ms;
        }

        if let Some(vi) = val.get("videoInfo").and_then(Value::as_object) {
            let w = vi.get("width").and_then(Value::as_i64).unwrap_or(0) as i32;
            let h = vi.get("height").and_then(Value::as_i64).unwrap_or(0) as i32;
            let hdr = vi.get("hdrType").and_then(Value::as_str).unwrap_or("sdr");
            if w > 0 && h > 0 {
                if let Some(win) = &self.window {
                    let _ = win.place(w, h);
                }
                self.status.video_info = format!("{w}x{h} {hdr}");
            }
        }

        if let Some(ai) = val.get("audioInfo").and_then(Value::as_object) {
            let codec = ai.get("codec").and_then(Value::as_str).unwrap_or("?");
            let ch = ai.get("channels").and_then(Value::as_u64).unwrap_or(0);
            self.status.audio_info = format!("{codec} {ch}ch");
        }

        if let Some(si) = val.get("sourceInfo").and_then(Value::as_object)
            && let Some(programs) = si.get("programInfo").and_then(Value::as_array)
            && let Some(p0) = programs.first().and_then(Value::as_object)
        {
            if let Some(dur) = p0.get("duration").and_then(Value::as_u64) {
                self.status.duration_ms = dur;
            }
            if let Some(num_aud) = p0.get("numAudioTracks").and_then(Value::as_u64) {
                self.status.audio_track_count = num_aud as usize;
            }
        }

        if val.get("loadCompleted").is_some() {
            self.status.playback_state = "Loaded -> Play".to_string();
            self.status.last_event = "loadCompleted".to_string();
            if let (Some(client), Some(id)) = (&self.luna, &self.status.media_id) {
                let _ = client.call_once(
                    "luna://com.webos.media/play",
                    &json!({ "mediaId": id }).to_string(),
                );
            }
        } else if val.get("playing").is_some() {
            self.status.playback_state = "Playing".to_string();
            self.status.last_event = "playing".to_string();
        } else if val.get("paused").is_some() {
            self.status.playback_state = "Paused".to_string();
            self.status.last_event = "paused".to_string();
        } else if val.get("seekDone").is_some() {
            self.status.last_event = format!("seekDone @ {} ms", self.status.position_ms);
        } else if val.get("trackSelected").is_some() {
            self.status.last_event = "trackSelected".to_string();
        } else if val.get("endOfStream").is_some() {
            self.status.playback_state = "Ended".to_string();
            self.status.last_event = "endOfStream".to_string();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_payload_places_token_in_header_or_query_according_to_mode() {
        let (uri_hdr, body_hdr) = build_load_payload(
            "http://198.51.100.10:8096/Items/1/Download",
            StreamKind::MkvDirect,
            "_Window_Id_1",
            "com.playfin.webos",
            Some("secret-token"),
            AuthTransportMode::HttpHeader,
        );
        assert_eq!(uri_hdr, "http://198.51.100.10:8096/Items/1/Download");
        let parsed: Value = serde_json::from_str(&body_hdr).unwrap();
        assert_eq!(parsed["payload"]["option"]["windowId"], "_Window_Id_1");
        assert_eq!(
            parsed["payload"]["option"]["transmission"]["httpHeader"]["X-Emby-Token"],
            "secret-token"
        );
        assert!(parsed["payload"]["option"]["mediaTransportType"].is_null());

        let (uri_q, body_q) = build_load_payload(
            "http://198.51.100.10:8096/Videos/1/master.m3u8?Static=false",
            StreamKind::HlsRemux,
            "_Window_Id_2",
            "com.playfin.webos",
            Some("secret-token"),
            AuthTransportMode::QueryApiKey,
        );
        assert!(uri_q.ends_with("&api_key=secret-token"));
        let parsed_q: Value = serde_json::from_str(&body_q).unwrap();
        assert_eq!(parsed_q["payload"]["option"]["mediaTransportType"], "HLS");
        assert!(parsed_q["payload"]["option"]["transmission"].is_null());
    }

    #[test]
    fn parses_luna_media_events_and_error_replies() {
        let mut ctrl = StarfishController::new("com.playfin.webos".to_string());
        ctrl.apply_luna_message(&LunaMessage {
            uri: "luna://com.webos.media/subscribe".into(),
            payload:
                r#"{"videoInfo":{"width":3840,"height":2160,"hdrType":"hdr10"},"mediaId":"_M1"}"#
                    .into(),
            is_subscription: true,
        });
        assert_eq!(ctrl.status.media_id.as_deref(), Some("_M1"));
        assert_eq!(ctrl.status.video_info, "3840x2160 hdr10");

        ctrl.apply_luna_message(&LunaMessage {
            uri: "luna://com.webos.media/subscribe".into(),
            payload: r#"{"sourceInfo":{"programInfo":[{"duration":125000,"numAudioTracks":3}]}}"#
                .into(),
            is_subscription: true,
        });
        assert_eq!(ctrl.status.duration_ms, 125000);
        assert_eq!(ctrl.status.audio_track_count, 3);

        ctrl.apply_luna_message(&LunaMessage {
            uri: "luna://com.webos.media/selectTrack".into(),
            payload:
                r#"{"returnValue":false,"errorCode":200,"errorText":"Audio Codec Not Supported"}"#
                    .into(),
            is_subscription: false,
        });
        assert!(
            ctrl.status
                .playback_state
                .contains("Audio Codec Not Supported")
        );
    }
}
