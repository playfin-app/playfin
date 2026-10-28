//! Application settings (the core's `settings` module): saved in a JSON file,
//! validated here, and translated into options for the player. The front end only displays them.

use crate::JellyfinError;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;

const FILE_NAME: &str = "settings.json";

/// An option of the mpv player (name, value).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MpvOption {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct AppSettings {
    /// Preferred audio language (ISO code, e.g. "fr"). Empty: system language.
    pub audio_language: String,
    /// Preferred subtitle language. Empty: system language.
    pub subtitle_language: String,
    pub skip_back_seconds: u32,
    pub skip_forward_seconds: u32,
    pub auto_play_next: bool,
    /// Player volume (0 to 100), kept from one playback to the next.
    pub player_volume: u32,
    pub hardware_decoding: bool,
    /// "small", "medium" or "large".
    pub subtitle_size: String,
    /// "white", "yellow" or "green".
    pub subtitle_color: String,
    /// "none", "translucent" or "black".
    pub subtitle_background: String,
    /// "low", "normal", "high" or "custom".
    pub cache_preset: String,
    /// "custom" preset: memory ahead (MiB), memory behind (MiB) and seconds kept ahead.
    pub custom_cache_max_mib: u32,
    pub custom_cache_back_mib: u32,
    pub custom_cache_secs: u32,
    /// Free mpv options (one `name=value` per line), used with the "custom" preset.
    pub custom_mpv_options: String,
    /// Keep the playback cache on disk rather than in memory.
    pub cache_on_disk: bool,
    pub image_cache_limit_mb: u32,
    /// Downloads: connections per file (1 to 16).
    pub download_connections: u32,
    /// Simultaneous downloads (1 to 5).
    pub download_concurrent: u32,
    /// Speed limit in KiB/s (0 = none).
    pub download_bandwidth_kbps: u32,
    /// Downloads folder (empty = ~/Movies/Playfin).
    pub download_folder: String,
    /// Attempts per segment before failing.
    pub download_retries: u32,
    /// External subtitles to download: "all", "preferred" or "none".
    pub download_subtitles: String,
    /// Delete a download once watched to the end.
    pub delete_after_watched: bool,
    /// "error", "warning", "info" or "debug".
    pub log_level: String,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            audio_language: String::new(),
            subtitle_language: String::new(),
            skip_back_seconds: 10,
            skip_forward_seconds: 10,
            auto_play_next: true,
            player_volume: 100,
            hardware_decoding: true,
            subtitle_size: "medium".into(),
            subtitle_color: "white".into(),
            subtitle_background: "none".into(),
            cache_preset: "normal".into(),
            custom_cache_max_mib: 150,
            custom_cache_back_mib: 50,
            custom_cache_secs: 120,
            custom_mpv_options: String::new(),
            cache_on_disk: false,
            image_cache_limit_mb: 1024,
            download_connections: 4,
            download_concurrent: 2,
            download_bandwidth_kbps: 0,
            download_folder: String::new(),
            download_retries: 5,
            download_subtitles: "preferred".into(),
            delete_after_watched: false,
            log_level: "info".into(),
        }
    }
}

#[uniffi::export]
pub fn default_settings() -> AppSettings {
    AppSettings::default()
}

fn one_of(value: &str, allowed: &[&str], fallback: &str) -> String {
    if allowed.contains(&value) {
        value.to_string()
    } else {
        fallback.to_string()
    }
}

fn language_code(value: &str) -> String {
    let code: String = value
        .trim()
        .chars()
        .filter(|c| c.is_ascii_alphabetic())
        .take(3)
        .collect::<String>()
        .to_ascii_lowercase();
    if code.len() >= 2 { code } else { String::new() }
}

impl AppSettings {
    /// Brings every value back into an acceptable range (a hand-edited file must not break anything).
    pub fn sanitized(mut self) -> Self {
        self.skip_back_seconds = self.skip_back_seconds.clamp(1, 120);
        self.skip_forward_seconds = self.skip_forward_seconds.clamp(1, 120);
        self.image_cache_limit_mb = self.image_cache_limit_mb.clamp(100, 100_000);
        self.player_volume = self.player_volume.min(100);
        self.custom_cache_max_mib = self.custom_cache_max_mib.clamp(16, 4096);
        self.custom_cache_back_mib = self.custom_cache_back_mib.clamp(8, 2048);
        self.custom_cache_secs = self.custom_cache_secs.clamp(10, 3600);
        self.download_connections = self.download_connections.clamp(1, 16);
        self.download_concurrent = self.download_concurrent.clamp(1, 5);
        self.download_retries = self.download_retries.min(20);
        self.download_subtitles = one_of(
            &self.download_subtitles,
            &["all", "preferred", "none"],
            "preferred",
        );
        self.download_folder = self.download_folder.trim().to_string();
        self.audio_language = language_code(&self.audio_language);
        self.subtitle_language = language_code(&self.subtitle_language);
        self.subtitle_size = one_of(&self.subtitle_size, &["small", "medium", "large"], "medium");
        self.subtitle_color = one_of(&self.subtitle_color, &["white", "yellow", "green"], "white");
        self.subtitle_background = one_of(
            &self.subtitle_background,
            &["none", "translucent", "black"],
            "none",
        );
        self.cache_preset = one_of(
            &self.cache_preset,
            &["low", "normal", "high", "custom"],
            "normal",
        );
        self.log_level = one_of(
            &self.log_level,
            &["error", "warning", "info", "debug"],
            "info",
        );
        self
    }
}

/// (demuxer-max-bytes, demuxer-max-back-bytes, cache-secs, max memory in MiB) of a preset.
fn preset_values(preset: &str) -> (&'static str, &'static str, u32, u32) {
    match preset {
        "low" => ("50MiB", "20MiB", 30, 70),
        "high" => ("500MiB", "150MiB", 600, 650),
        _ => ("150MiB", "50MiB", 120, 200),
    }
}

/// Approximate maximum memory (MiB) of a preset, to show it in the settings.
#[uniffi::export]
pub fn cache_preset_memory_mib(preset: String) -> u32 {
    preset_values(&preset).3
}

/// Approximate maximum memory (MiB) of the settings, custom preset included.
#[uniffi::export]
pub fn settings_cache_memory_mib(settings: AppSettings) -> u32 {
    let s = settings.sanitized();
    if s.cache_preset == "custom" {
        s.custom_cache_max_mib + s.custom_cache_back_mib
    } else {
        preset_values(&s.cache_preset).3
    }
}

/// mpv options allowed in the "custom" preset. Closed list: a free option such as `script`
/// or `input-ipc-server` could run code or open access to the player.
const ALLOWED_CUSTOM_PREFIXES: &[&str] = &[
    "demuxer-",
    "cache",
    "hr-seek",
    "network-timeout",
    "vd-lavc-",
    "ad-lavc-",
    "audio-buffer",
    "audio-delay",
    "sub-delay",
    "video-sync",
    "framedrop",
    "deband",
    "scale",
    "cscale",
    "dscale",
    "tone-mapping",
    "hdr-",
    "target-",
    "gamma",
];

/// Reads the free `name=value` text (one option per line, `#` for a comment) and refuses everything that
/// is not in the allowed list.
#[uniffi::export]
pub fn validate_custom_mpv_options(text: String) -> Result<Vec<MpvOption>, JellyfinError> {
    let mut options = Vec::new();
    for (index, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((name, value)) = line.split_once('=') else {
            return Err(JellyfinError::InvalidInput(format!(
                "line {}: write \"name=value\"",
                index + 1
            )));
        };
        let name = name.trim().trim_start_matches("--");
        let value = value.trim();
        let name_ok = !name.is_empty()
            && name
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
        let value_ok = !value.is_empty() && !value.chars().any(|c| c.is_control());
        if !name_ok || !value_ok {
            return Err(JellyfinError::InvalidInput(format!(
                "line {}: invalid name or value",
                index + 1
            )));
        }
        if !ALLOWED_CUSTOM_PREFIXES.iter().any(|p| name.starts_with(p)) {
            return Err(JellyfinError::InvalidInput(format!(
                "line {}: the option \"{name}\" is not allowed",
                index + 1
            )));
        }
        options.push(MpvOption {
            name: name.to_string(),
            value: value.to_string(),
        });
    }
    Ok(options)
}

fn comma_list(first: &str, system: &[String]) -> Option<String> {
    let mut codes: Vec<String> = Vec::new();
    if !first.is_empty() {
        codes.push(first.to_string());
    }
    for code in system {
        if !codes.contains(code) {
            codes.push(code.clone());
        }
    }
    (!codes.is_empty()).then(|| codes.join(","))
}

fn mpv_log_level(level: &str) -> &'static str {
    match level {
        "error" => "error",
        "warning" => "warn",
        "debug" => "v",
        _ => "info",
    }
}

/// All the mpv options to apply at the start of a playback, computed from the settings.
/// `system_languages`: the system's preferred languages (ISO codes), used after the chosen language.
#[uniffi::export]
pub fn mpv_options(settings: AppSettings, system_languages: Vec<String>) -> Vec<MpvOption> {
    let s = settings.sanitized();
    let mut options: Vec<(String, String)> = Vec::new();
    let mut add = |name: &str, value: String| options.push((name.to_string(), value));

    add(
        "hwdec",
        if s.hardware_decoding {
            "videotoolbox"
        } else {
            "no"
        }
        .into(),
    );
    add("cache", "yes".into());
    add("demuxer-seekable-cache", "yes".into());
    add(
        "cache-on-disk",
        if s.cache_on_disk { "yes" } else { "no" }.into(),
    );
    if s.cache_preset == "custom" {
        add(
            "demuxer-max-bytes",
            format!("{}MiB", s.custom_cache_max_mib),
        );
        add(
            "demuxer-max-back-bytes",
            format!("{}MiB", s.custom_cache_back_mib),
        );
        add("cache-secs", s.custom_cache_secs.to_string());
        add("demuxer-readahead-secs", s.custom_cache_secs.to_string());
    } else {
        let (max, back, secs, _) = preset_values(&s.cache_preset);
        add("demuxer-max-bytes", max.into());
        add("demuxer-max-back-bytes", back.into());
        add("cache-secs", secs.to_string());
        add("demuxer-readahead-secs", secs.to_string());
    }

    // No subtitles by default when the audio language is already the one being read (French movie, French subtitles).
    add("subs-with-matching-audio", "no".into());
    if let Some(list) = comma_list(&s.audio_language, &system_languages) {
        add("alang", list);
    }
    if let Some(list) = comma_list(&s.subtitle_language, &system_languages) {
        add("slang", list);
    }

    add(
        "sub-font-size",
        match s.subtitle_size.as_str() {
            "small" => "42",
            "large" => "72",
            _ => "55",
        }
        .into(),
    );
    add(
        "sub-color",
        match s.subtitle_color.as_str() {
            "yellow" => "#FFFF00",
            "green" => "#7CFC00",
            _ => "#FFFFFF",
        }
        .into(),
    );
    match s.subtitle_background.as_str() {
        "black" => {
            add("sub-border-style", "background-box".into());
            add("sub-back-color", "#FF000000".into());
        }
        "translucent" => {
            add("sub-border-style", "background-box".into());
            add("sub-back-color", "#99000000".into());
        }
        _ => {}
    }
    add("msg-level", format!("all={}", mpv_log_level(&s.log_level)));

    let mut result: Vec<MpvOption> = options
        .into_iter()
        .map(|(name, value)| MpvOption { name, value })
        .collect();
    // "custom" preset: the validated options replace the values above (invalid ones are ignored).
    if s.cache_preset == "custom"
        && let Ok(custom) = validate_custom_mpv_options(s.custom_mpv_options.clone())
    {
        for option in custom {
            result.retain(|o| o.name != option.name);
            result.push(option);
        }
    }
    result
}

/// Settings file of an application profile (a single one for the whole installation).
#[derive(uniffi::Object)]
pub struct SettingsStore {
    path: PathBuf,
    lock: Mutex<()>,
}

#[uniffi::export]
impl SettingsStore {
    #[uniffi::constructor]
    pub fn new(dir: &str) -> Self {
        Self {
            path: PathBuf::from(dir).join(FILE_NAME),
            lock: Mutex::new(()),
        }
    }

    /// Saved settings, or default values if there is nothing or if the file is unreadable.
    /// An unreadable file is set aside (`settings.json.corrupt`) instead of being lost.
    pub fn load(&self) -> AppSettings {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let Ok(data) = std::fs::read_to_string(&self.path) else {
            return AppSettings::default();
        };
        match serde_json::from_str::<AppSettings>(&data) {
            Ok(settings) => settings.sanitized(),
            Err(_) => {
                let _ = std::fs::rename(&self.path, self.path.with_extension("json.corrupt"));
                AppSettings::default()
            }
        }
    }

    /// Saves (after validation) and returns the values actually kept.
    pub fn save(&self, settings: AppSettings) -> Result<AppSettings, JellyfinError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let clean = settings.sanitized();
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| JellyfinError::Storage(e.to_string()))?;
        }
        let json = serde_json::to_string_pretty(&clean)
            .map_err(|e| JellyfinError::Storage(e.to_string()))?;
        // Write to a temporary file then rename: never a half-written file.
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, json).map_err(|e| JellyfinError::Storage(e.to_string()))?;
        std::fs::rename(&tmp, &self.path).map_err(|e| JellyfinError::Storage(e.to_string()))?;
        Ok(clean)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> String {
        std::env::temp_dir()
            .join(format!("jn_settings_{name}_{}", uuid::Uuid::new_v4()))
            .to_string_lossy()
            .into_owned()
    }

    fn get<'a>(options: &'a [MpvOption], name: &str) -> Option<&'a str> {
        options
            .iter()
            .find(|o| o.name == name)
            .map(|o| o.value.as_str())
    }

    #[test]
    fn defaults_match_the_spec() {
        let s = AppSettings::default();
        assert_eq!((s.skip_back_seconds, s.skip_forward_seconds), (10, 10));
        assert!(s.auto_play_next && s.hardware_decoding);
        assert_eq!(s.cache_preset, "normal");
        assert_eq!(s.image_cache_limit_mb, 1024);
        assert_eq!(s.log_level, "info");
        assert_eq!(
            (
                s.download_connections,
                s.download_concurrent,
                s.download_retries
            ),
            (4, 2, 5)
        );
        assert_eq!(
            (s.download_bandwidth_kbps, s.download_subtitles.as_str()),
            (0, "preferred")
        );
        assert!(!s.delete_after_watched);
        let wild = AppSettings {
            download_connections: 99,
            download_concurrent: 0,
            ..AppSettings::default()
        }
        .sanitized();
        assert_eq!(
            (wild.download_connections, wild.download_concurrent),
            (16, 1)
        );
    }

    #[test]
    fn save_then_load_round_trips_and_clamps_values() {
        let dir = temp("rt");
        let store = SettingsStore::new(&dir);
        assert_eq!(store.load(), AppSettings::default());

        let mut s = AppSettings::default();
        s.skip_forward_seconds = 30;
        s.cache_preset = "high".into();
        s.skip_back_seconds = 9999;
        s.log_level = "chatty".into();
        let saved = store.save(s).unwrap();
        assert_eq!(saved.skip_back_seconds, 120);
        assert_eq!(saved.player_volume, 100, "default volume");
        assert_eq!(saved.log_level, "info");
        assert_eq!(store.load(), saved);
        assert_eq!(store.load().skip_forward_seconds, 30);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn corrupt_file_falls_back_to_defaults_and_is_kept_aside() {
        let dir = temp("corrupt");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(PathBuf::from(&dir).join(FILE_NAME), "{not json").unwrap();
        let store = SettingsStore::new(&dir);
        assert_eq!(store.load(), AppSettings::default());
        assert!(PathBuf::from(&dir).join("settings.json.corrupt").exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn partial_file_keeps_defaults_for_missing_fields() {
        let dir = temp("partial");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            PathBuf::from(&dir).join(FILE_NAME),
            r#"{"skip_back_seconds": 5}"#,
        )
        .unwrap();
        let loaded = SettingsStore::new(&dir).load();
        assert_eq!(loaded.skip_back_seconds, 5);
        assert_eq!(loaded.skip_forward_seconds, 10);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn presets_match_the_spec_values() {
        for (preset, max, back, secs, mem) in [
            ("low", "50MiB", "20MiB", "30", 70),
            ("normal", "150MiB", "50MiB", "120", 200),
            ("high", "500MiB", "150MiB", "600", 650),
        ] {
            let mut s = AppSettings::default();
            s.cache_preset = preset.into();
            let o = mpv_options(s, vec![]);
            assert_eq!(get(&o, "demuxer-max-bytes"), Some(max));
            assert_eq!(get(&o, "demuxer-max-back-bytes"), Some(back));
            assert_eq!(get(&o, "cache-secs"), Some(secs));
            assert_eq!(cache_preset_memory_mib(preset.into()), mem);
        }
    }

    #[test]
    fn options_follow_hardware_languages_and_subtitle_style() {
        let mut s = AppSettings::default();
        s.hardware_decoding = false;
        s.audio_language = "ja".into();
        s.subtitle_size = "large".into();
        s.subtitle_background = "black".into();
        s.cache_on_disk = true;
        let o = mpv_options(s, vec!["fr".into(), "ja".into()]);
        assert_eq!(get(&o, "hwdec"), Some("no"));
        assert_eq!(
            get(&o, "alang"),
            Some("ja,fr"),
            "chosen language first, without duplicates"
        );
        assert_eq!(get(&o, "slang"), Some("fr,ja"));
        assert_eq!(get(&o, "sub-font-size"), Some("72"));
        assert_eq!(get(&o, "sub-border-style"), Some("background-box"));
        assert_eq!(get(&o, "cache-on-disk"), Some("yes"));

        let none = mpv_options(AppSettings::default(), vec![]);
        assert_eq!(
            get(&none, "alang"),
            None,
            "no known language: mpv chooses by itself"
        );
        assert_eq!(get(&none, "sub-border-style"), None);
    }

    #[test]
    fn custom_options_override_only_with_the_custom_preset_and_only_if_allowed() {
        let mut s = AppSettings::default();
        s.custom_mpv_options = "demuxer-max-bytes=1GiB\n# comment\ncache-secs=900".into();
        let normal = mpv_options(s.clone(), vec![]);
        assert_eq!(
            get(&normal, "demuxer-max-bytes"),
            Some("150MiB"),
            "ignored outside the custom preset"
        );
        s.cache_preset = "custom".into();
        let custom = mpv_options(s, vec![]);
        assert_eq!(get(&custom, "demuxer-max-bytes"), Some("1GiB"));
        assert_eq!(get(&custom, "cache-secs"), Some("900"));
        assert_eq!(custom.iter().filter(|o| o.name == "cache-secs").count(), 1);
    }

    #[test]
    fn custom_preset_uses_the_slider_values_and_reports_memory() {
        let mut s = AppSettings::default();
        s.cache_preset = "custom".into();
        s.custom_cache_max_mib = 300;
        s.custom_cache_back_mib = 100;
        s.custom_cache_secs = 240;
        let o = mpv_options(s.clone(), vec![]);
        assert_eq!(get(&o, "demuxer-max-bytes"), Some("300MiB"));
        assert_eq!(get(&o, "demuxer-max-back-bytes"), Some("100MiB"));
        assert_eq!(get(&o, "cache-secs"), Some("240"));
        assert_eq!(settings_cache_memory_mib(s.clone()), 400);
        s.custom_cache_max_mib = 999_999;
        assert_eq!(s.sanitized().custom_cache_max_mib, 4096);
        assert_eq!(settings_cache_memory_mib(AppSettings::default()), 200);
    }

    #[test]
    fn dangerous_or_malformed_custom_options_are_refused() {
        for bad in [
            "script=/tmp/x.lua",
            "input-ipc-server=/tmp/s",
            "run=ls",
            "no equals sign",
            "cache-secs=",
            "--include=x",
        ] {
            assert!(
                matches!(
                    validate_custom_mpv_options(bad.into()),
                    Err(JellyfinError::InvalidInput(_))
                ),
                "{bad}"
            );
        }
        assert_eq!(
            validate_custom_mpv_options("--hr-seek=yes".into())
                .unwrap()
                .len(),
            1
        );
    }
}
