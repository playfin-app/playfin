//! webOS launch context and persistent storage discovery inside the non-root jailer sandbox.

use std::path::{Path, PathBuf};

/// Parsed startup metadata passed by webOS SAM (`argv[1]` JSON) and environment variables.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchContext {
    pub argv1_preview: String,
    pub home_env: Option<String>,
    pub xdg_data_env: Option<String>,
    pub xdg_config_env: Option<String>,
}

impl LaunchContext {
    /// Captures launch context safely from CLI args and environment variables without panicking.
    pub fn from_env<I>(args: I) -> Self
    where
        I: IntoIterator<Item = String>,
    {
        let mut iter = args.into_iter();
        let _program = iter.next();
        let argv1_preview = match iter.next() {
            Some(arg) if !arg.trim().is_empty() => {
                let trimmed = arg.trim();
                let lower = trimmed.to_ascii_lowercase();
                if lower.contains("api_key") || lower.contains("token") || lower.contains("secret")
                {
                    "SpikeConfig JSON (redacted)".to_string()
                } else {
                    truncate_preview(trimmed, 72)
                }
            }
            _ => "none".to_string(),
        };
        Self {
            argv1_preview,
            home_env: non_empty_env("HOME"),
            xdg_data_env: non_empty_env("XDG_DATA_HOME"),
            xdg_config_env: non_empty_env("XDG_CONFIG_HOME"),
        }
    }
}

fn non_empty_env(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

fn truncate_preview(input: &str, max_chars: usize) -> String {
    let mut out: String = input.chars().take(max_chars).collect();
    if input.chars().count() > max_chars {
        out.push_str("...");
    }
    out
}

/// Result of selecting a writable persistent data directory that survives `.ipk` reinstalls.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorageProbe {
    pub data_dir: PathBuf,
    pub survives_reinstall: bool,
    pub note: String,
}

/// Returns `true` when `path` sits inside a webOS `.ipk` installation folder replaced on
/// reinstall (`/media/developer/apps/...`) or an ephemeral volatile tmpfs path.
pub fn is_ephemeral_install_path(path: &Path) -> bool {
    let s = path.to_string_lossy();
    s.starts_with("/media/developer/apps/")
        || s.starts_with("/media/cryptofs/apps/")
        || s == "/tmp"
        || s.starts_with("/tmp/")
        || s == "/var/tmp"
        || s.starts_with("/var/tmp/")
        || s == "/run"
        || s.starts_with("/run/")
}

/// Tests whether `dir` can be created and written to inside the current sandbox.
fn is_writable_dir(dir: &Path) -> bool {
    if std::fs::create_dir_all(dir).is_err() {
        return false;
    }
    let probe = dir.join(".playfin_write_probe");
    if std::fs::write(&probe, b"ok").is_err() {
        return false;
    }
    let _ = std::fs::remove_file(&probe);
    true
}

/// Resolves the best writable directory for `device_id`, cache, and `0600` token storage.
pub fn resolve_persistent_data_dir(ctx: &LaunchContext) -> StorageProbe {
    let mut candidates: Vec<(PathBuf, &str)> = Vec::new();
    if let Some(explicit) = non_empty_env("PLAYFIN_DATA_DIR") {
        candidates.push((PathBuf::from(explicit), "PLAYFIN_DATA_DIR"));
    }
    if let Some(xdg) = &ctx.xdg_data_env {
        candidates.push((PathBuf::from(xdg).join("playfin"), "XDG_DATA_HOME"));
    }
    if let Some(home) = &ctx.home_env {
        candidates.push((
            PathBuf::from(home).join(".local/share/playfin"),
            "HOME/.local/share",
        ));
        candidates.push((PathBuf::from(home).join(".playfin"), "HOME/.playfin"));
    }
    if let Ok(exe) = std::env::current_exe()
        && let Some(parent) = exe.parent()
    {
        candidates.push((parent.join("data"), "exe/data"));
    }
    candidates.push((std::env::temp_dir().join("playfin-webos"), "temp_dir"));

    resolve_from_candidates(&candidates)
}

fn resolve_from_candidates(candidates: &[(PathBuf, &str)]) -> StorageProbe {
    for (dir, source) in candidates {
        if is_writable_dir(dir) {
            let outside_install = !is_ephemeral_install_path(dir);
            return StorageProbe {
                data_dir: dir.clone(),
                survives_reinstall: outside_install && *source != "temp_dir",
                note: format!("via {source}"),
            };
        }
    }
    StorageProbe {
        data_dir: std::env::temp_dir().join("playfin-webos"),
        survives_reinstall: false,
        note: "fallback temp_dir".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launch_context_handles_webos_argv1_json_safely() {
        let args = vec![
            "/media/developer/apps/usr/palm/applications/com.playfin.webos/playfin_webos"
                .to_string(),
            r#"{"@system_native_app":true,"nid":"com.playfin.webos"}"#.to_string(),
        ];
        let ctx = LaunchContext::from_env(args);
        assert!(ctx.argv1_preview.contains("@system_native_app"));

        let secret_args = vec![
            "playfin_webos".to_string(),
            r#"{"api_key":"super-secret","mkv_url":"http://198.51.100.10:8096/v.mkv"}"#.to_string(),
        ];
        let secret_ctx = LaunchContext::from_env(secret_args);
        assert!(!secret_ctx.argv1_preview.contains("super-secret"));
        assert!(secret_ctx.argv1_preview.contains("redacted"));
    }

    #[test]
    fn detects_ephemeral_webos_install_paths() {
        assert!(is_ephemeral_install_path(Path::new(
            "/media/developer/apps/usr/palm/applications/com.playfin.webos/data"
        )));
        assert!(is_ephemeral_install_path(Path::new("/tmp/playfin")));
        assert!(is_ephemeral_install_path(Path::new("/var/tmp/playfin")));
        assert!(is_ephemeral_install_path(Path::new("/run/playfin")));
        assert!(!is_ephemeral_install_path(Path::new(
            "/home/prisoner/.local/share/playfin"
        )));
    }

    #[test]
    fn skips_unwritable_candidates_and_prefers_persistent_dir() {
        let base =
            std::env::temp_dir().join(format!("playfin-storage-probe-{}", std::process::id()));
        let good = base.join("persistent");
        let missing_parent = PathBuf::from("/proc/nonexistent/playfin");
        let probe = resolve_from_candidates(&[
            (missing_parent, "invalid"),
            (good.clone(), "XDG_DATA_HOME"),
        ]);
        assert_eq!(probe.data_dir, good);
        // On Linux `/tmp/...` is volatile, while on macOS `temp_dir` lives under `/var/folders`.
        assert_eq!(probe.survives_reinstall, !is_ephemeral_install_path(&good));
        assert_eq!(probe.note, "via XDG_DATA_HOME");
        let _ = std::fs::remove_dir_all(base);
    }
}
