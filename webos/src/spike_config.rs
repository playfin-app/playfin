//! Configuration and secret-safe URL handling for Task 0.4 Starfish playback tests.

use serde::Deserialize;
use std::path::Path;

/// Authentication mechanism tested in Gate 0.4 (`httpHeader` vs `?api_key=` query param).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum AuthTransportMode {
    #[default]
    HttpHeader,
    QueryApiKey,
}

impl AuthTransportMode {
    pub fn toggle(self) -> Self {
        match self {
            Self::HttpHeader => Self::QueryApiKey,
            Self::QueryApiKey => Self::HttpHeader,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::HttpHeader => "httpHeader",
            Self::QueryApiKey => "?api_key",
        }
    }
}

/// Optional test URLs loaded at runtime from `<data_dir>/spike_config.json` or `argv[1]`.
#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct SpikeConfig {
    pub mkv_url: Option<String>,
    pub hls_url: Option<String>,
    pub dts_url: Option<String>,
    pub truehd_url: Option<String>,
    pub api_key: Option<String>,
    pub app_id: Option<String>,
    /// Dev only: spike buttons pressed automatically after launch, one per
    /// `auto_interval_ms` (1-8 = the on-screen actions, 0 = Back/stop playback).
    pub auto_actions: Vec<u8>,
    pub auto_interval_ms: Option<u64>,
}

impl SpikeConfig {
    fn non_empty(v: Option<String>) -> Option<String> {
        v.map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
    }

    fn normalize(self) -> Self {
        Self {
            mkv_url: Self::non_empty(self.mkv_url),
            hls_url: Self::non_empty(self.hls_url),
            dts_url: Self::non_empty(self.dts_url),
            truehd_url: Self::non_empty(self.truehd_url),
            api_key: Self::non_empty(self.api_key),
            app_id: Self::non_empty(self.app_id),
            auto_actions: self.auto_actions,
            auto_interval_ms: self.auto_interval_ms,
        }
    }

    pub fn has_any_stream(&self) -> bool {
        self.mkv_url.is_some()
            || self.hls_url.is_some()
            || self.dts_url.is_some()
            || self.truehd_url.is_some()
    }
}

/// Loads `SpikeConfig` from `argv[1]` JSON if stream keys exist, otherwise `<data_dir>/spike_config.json`.
pub fn load_spike_config(data_dir: &Path, argv1: Option<&str>) -> (SpikeConfig, String) {
    if let Some(arg) = argv1
        && let Ok(parsed) = serde_json::from_str::<SpikeConfig>(arg)
    {
        let norm = parsed.normalize();
        if norm.has_any_stream() || norm.api_key.is_some() || norm.app_id.is_some() {
            return (norm, "argv[1] JSON".to_string());
        }
    }

    let path = data_dir.join("spike_config.json");
    match std::fs::read_to_string(&path) {
        Ok(raw) => match serde_json::from_str::<SpikeConfig>(&raw) {
            Ok(parsed) => (parsed.normalize(), format!("{}", path.display())),
            Err(err) => (
                SpikeConfig::default(),
                format!("invalid {}: {err}", path.display()),
            ),
        },
        Err(_) => (
            SpikeConfig::default(),
            format!("none (add {})", path.display()),
        ),
    }
}

/// Redacts sensitive query parameters (`api_key`, `token`, etc.) so tokens never hit logs or UI.
pub fn redact_url_for_log(url: &str) -> String {
    let Some((base, query)) = url.split_once('?') else {
        return url.to_string();
    };
    let mut parts = Vec::new();
    for pair in query.split('&') {
        if let Some((k, _)) = pair.split_once('=') {
            let lower = k.to_ascii_lowercase();
            if lower.contains("key") || lower.contains("token") || lower.contains("auth") {
                parts.push(format!("{k}=REDACTED"));
                continue;
            }
        }
        parts.push(pair.to_string());
    }
    format!("{base}?{}", parts.join("&"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_api_key_and_tokens_from_logged_urls() {
        let raw = "https://jellyfin.example.com:8096/Videos/abc/stream.mkv?static=true&api_key=secret123&X-Emby-Token=tok";
        let redacted = redact_url_for_log(raw);
        assert!(!redacted.contains("secret123"));
        assert!(!redacted.contains("tok"));
        assert!(redacted.contains("static=true"));
        assert!(redacted.contains("api_key=REDACTED"));
    }

    #[test]
    fn loads_spike_config_from_data_dir_or_argv1() {
        let dir = std::env::temp_dir().join(format!("playfin-spike-cfg-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        std::fs::write(
            dir.join("spike_config.json"),
            r#"{"mkv_url":"http://198.51.100.10:8096/v.mkv","api_key":"abc"}"#,
        )
        .unwrap();

        let (cfg, src) = load_spike_config(&dir, Some(r#"{"@system_native_app":true}"#));
        assert!(src.contains("spike_config.json"));
        assert_eq!(
            cfg.mkv_url.as_deref(),
            Some("http://198.51.100.10:8096/v.mkv")
        );
        assert_eq!(cfg.api_key.as_deref(), Some("abc"));

        let (arg_cfg, arg_src) = load_spike_config(
            &dir,
            Some(r#"{"hls_url":"http://198.51.100.10:8096/m.m3u8"}"#),
        );
        assert_eq!(arg_src, "argv[1] JSON");
        assert_eq!(
            arg_cfg.hls_url.as_deref(),
            Some("http://198.51.100.10:8096/m.m3u8")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
