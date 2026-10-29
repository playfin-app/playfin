use serde::{Deserialize, Serialize};
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use crate::JellyfinError;

/// Public information about a Jellyfin server (obtained via GET /System/Info/Public).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct ServerPublicInfo {
    pub id: String,
    #[serde(rename = "ServerName")]
    pub server_name: String,
    pub version: String,
}

/// An address saved for a server.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ServerAddress {
    pub url: String,
    pub label: String,
    pub priority: u32,
    pub is_local: bool,
}

/// Normalises a URL typed by the user (adds http:// if there is no scheme, handles case, removes trailing slashes).
pub fn normalize_server_url(url: &str) -> String {
    let trimmed = url.trim().trim_end_matches('/');
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("https://") {
        format!("https://{}", &trimmed[8..])
    } else if lower.starts_with("http://") {
        format!("http://{}", &trimmed[7..])
    } else {
        format!("http://{trimmed}")
    }
}

impl ServerAddress {
    pub fn new(url: &str, label: &str, priority: u32) -> Self {
        let normalized = normalize_server_url(url);
        let is_local = is_local_address(&normalized);
        Self {
            url: normalized,
            label: label.to_string(),
            priority,
            is_local,
        }
    }
}

/// User profile linking a user to a Jellyfin server.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ServerProfile {
    pub server_id: String,
    pub server_name: String,
    pub user_id: String,
    pub user_name: String,
    pub user_avatar_tag: Option<String>,
    pub addresses: Vec<ServerAddress>,
    pub is_primary: bool,
    /// Address forced by the user: used as is, without probing the others.
    #[serde(default)]
    #[uniffi(default = None)]
    pub forced_address: Option<String>,
}

/// Determines whether a URL address points to a local network (LAN, loopback, .local).
pub fn is_local_address(url_str: &str) -> bool {
    let Ok(parsed) = reqwest::Url::parse(url_str.trim()) else {
        return false;
    };

    let Some(host_str) = parsed.host_str() else {
        return false;
    };

    let unbracketed = host_str.trim_start_matches('[').trim_end_matches(']');

    if unbracketed.eq_ignore_ascii_case("localhost")
        || unbracketed.to_ascii_lowercase().ends_with(".local")
    {
        return true;
    }

    if let Ok(ip) = unbracketed.parse::<IpAddr>() {
        match ip {
            IpAddr::V4(ipv4) => ipv4.is_loopback() || ipv4.is_private() || ipv4.is_link_local(),
            IpAddr::V6(ipv6) => {
                ipv6.is_loopback()
                    || ((ipv6.segments()[0] & 0xfe00) == 0xfc00) // Unique Local Address fc00::/7
                    || ((ipv6.segments()[0] & 0xffc0) == 0xfe80) // Link-local fe80::/10
            }
        }
    } else {
        false
    }
}

/// Splits a semver version number (e.g. "10.9.7" or "10.10.0-rc1") into numeric components.
pub fn parse_version(v: &str) -> Option<(u32, u32, u32)> {
    let clean = v.split(['-', '+']).next()?;
    let mut parts = clean.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch = parts.next().unwrap_or("0").parse().ok()?;
    Some((major, minor, patch))
}

/// Checks that the server meets the minimum requirements (Jellyfin >= 10.9).
pub fn is_supported_version(version: &str) -> bool {
    if let Some((major, minor, _)) = parse_version(version) {
        major > 10 || (major == 10 && minor >= 9)
    } else {
        false
    }
}

/// Sorts a list of addresses according to these rules:
/// 1. Highest priority first (lowest numeric value).
/// 2. On a tie, local addresses first.
pub fn sort_addresses_by_priority(addresses: &mut [ServerAddress]) {
    addresses.sort_by(|a, b| {
        a.priority
            .cmp(&b.priority)
            .then_with(|| b.is_local.cmp(&a.is_local))
    });
}

/// Moves an address from `from` to `to` and renumbers the priorities (1 = the highest).
#[uniffi::export]
pub fn reorder_addresses(addresses: Vec<ServerAddress>, from: u32, to: u32) -> Vec<ServerAddress> {
    let mut list = addresses;
    let (from, to) = (from as usize, to as usize);
    if from < list.len() && to < list.len() && from != to {
        let item = list.remove(from);
        list.insert(to, item);
    }
    for (index, address) in list.iter_mut().enumerate() {
        address.priority = index as u32 + 1;
    }
    list
}

/// True if the token would travel in clear text: an `http://` address that is not on the local network.
#[uniffi::export]
pub fn address_sends_token_unencrypted(url: String) -> bool {
    let normalized = normalize_server_url(&url);
    normalized.starts_with("http://") && !is_local_address(&normalized)
}

static PROBE_CLIENT: OnceLock<reqwest::Client> = OnceLock::new();

/// Shared HTTP client for server discovery probes and validations to reuse connection pools (P14).
pub fn probe_http_client() -> Result<&'static reqwest::Client, JellyfinError> {
    if let Some(client) = PROBE_CLIENT.get() {
        return Ok(client);
    }
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_millis(3000))
        .build()
        .map_err(|e| {
            JellyfinError::Network(format!("Failed to initialize probe HTTP client: {e}"))
        })?;
    let _ = PROBE_CLIENT.set(client);
    PROBE_CLIENT.get().ok_or_else(|| {
        JellyfinError::Network("Probe HTTP client initialization failed".to_string())
    })
}

/// Tests a specific address of a server via GET /System/Info/Public.
pub async fn probe_server_address(
    http: &reqwest::Client,
    url: &str,
    timeout_duration: Duration,
) -> Result<ServerPublicInfo, JellyfinError> {
    let clean_url = normalize_server_url(url);
    let probe_url = format!("{clean_url}/System/Info/Public");
    let response = http
        .get(&probe_url)
        .timeout(timeout_duration)
        .send()
        .await
        .map_err(|e| JellyfinError::ServerUnreachable(e.to_string()))?;

    if !response.status().is_success() {
        return Err(JellyfinError::ServerError {
            code: response.status().as_u16(),
            message: format!("HTTP status code {}", response.status()),
        });
    }

    let info: ServerPublicInfo = response
        .json()
        .await
        .map_err(|e| JellyfinError::Decode(e.to_string()))?;

    if !is_supported_version(&info.version) {
        return Err(JellyfinError::UnsupportedServerVersion(info.version));
    }

    Ok(info)
}

/// Pure evaluation: selects the best address among the probe results.
/// Strictly rejects empty server identifiers (Pitfall 2) and responses whose ID does not match `expected_server_id` (Pitfalls 3 & 15).
/// Ranks valid addresses by increasing priority, then local ones first.
pub fn choose_address(
    results: &[(ServerAddress, Result<ServerPublicInfo, JellyfinError>)],
    expected_server_id: &str,
) -> Result<ServerAddress, JellyfinError> {
    if expected_server_id.trim().is_empty() {
        return Err(JellyfinError::InvalidInput(
            "The expected server identifier cannot be empty".into(),
        ));
    }

    if results.is_empty() {
        return Err(JellyfinError::InvalidInput(
            "No address configured for this server".into(),
        ));
    }

    let mut reachable_addresses: Vec<ServerAddress> = Vec::new();
    let mut mismatched_ids: Vec<(ServerAddress, String)> = Vec::new();

    for (addr, res) in results {
        if let Ok(info) = res {
            // Security rule: the response only counts if the ID matches the known server exactly
            if !info.id.trim().is_empty() && info.id.eq_ignore_ascii_case(expected_server_id) {
                reachable_addresses.push(addr.clone());
            } else {
                mismatched_ids.push((addr.clone(), info.id.clone()));
            }
        }
    }

    if reachable_addresses.is_empty() {
        if results.len() == mismatched_ids.len() && !mismatched_ids.is_empty() {
            let (addr, found_id) = &mismatched_ids[0];
            return Err(JellyfinError::ServerMismatch(format!(
                "The address {} answered with the identifier '{}', different from the expected identifier '{}'",
                addr.url, found_id, expected_server_id
            )));
        } else {
            if !mismatched_ids.is_empty() {
                log::warn!(
                    "Warning: {} address(es) answered with a non-matching identifier",
                    mismatched_ids.len()
                );
            }
            return Err(JellyfinError::ServerUnreachable(
                "No server address answered".into(),
            ));
        }
    }

    sort_addresses_by_priority(&mut reachable_addresses);
    Ok(reachable_addresses.remove(0))
}

/// Pause before trying again an address that refused the connection.
const PROBE_RETRY_DELAY: Duration = Duration::from_millis(250);

/// Probes an address until it answers or `budget` is spent.
/// At launch, macOS (local network privacy, "NECP") refuses the app's very first LAN connection
/// at once (EHOSTUNREACH) and lets the next ones through: with a single attempt, the home address
/// looked unreachable and only the remote address was left.
async fn probe_with_retry(
    http: &reqwest::Client,
    url: &str,
    budget: Duration,
) -> Result<ServerPublicInfo, JellyfinError> {
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        match probe_server_address(http, url, remaining).await {
            // Only a network failure is worth a new attempt, and only if time is left for it.
            Err(JellyfinError::ServerUnreachable(_))
                if tokio::time::Instant::now() + PROBE_RETRY_DELAY < deadline =>
            {
                tokio::time::sleep(PROBE_RETRY_DELAY).await;
            }
            other => return other,
        }
    }
}

/// Probes all the addresses of a server in parallel and selects the best reachable address.
pub async fn select_active_address(
    http: &reqwest::Client,
    addresses: &[ServerAddress],
    expected_server_id: &str,
    probe_timeout: Duration,
) -> Result<ServerAddress, JellyfinError> {
    if addresses.is_empty() {
        return Err(JellyfinError::InvalidInput(
            "No address configured for this server".into(),
        ));
    }

    let mut tasks = tokio::task::JoinSet::new();

    for (index, addr) in addresses.iter().enumerate() {
        let client = http.clone();
        let target_addr = addr.clone();
        tasks.spawn(async move {
            let res = probe_with_retry(&client, &target_addr.url, probe_timeout).await;
            (index, target_addr, res)
        });
    }

    // Order of `sort_addresses_by_priority`: priority, then local first.
    let rank = |addr: &ServerAddress| (addr.priority, !addr.is_local);
    let mut pending = vec![true; addresses.len()];
    let mut results = Vec::new();
    while let Some(res) = tasks.join_next().await {
        let Ok((index, addr, probe_res)) = res else {
            continue;
        };
        pending[index] = false;
        results.push((addr, probe_res));

        // The best address has answered: no probe still running could rank before it, so `choose_address`
        // would pick it anyway. No need to wait for the slower ones (dropping `tasks` stops them).
        let best = results
            .iter()
            .filter(|(_, res)| {
                res.as_ref().is_ok_and(|info| {
                    !info.id.trim().is_empty() && info.id.eq_ignore_ascii_case(expected_server_id)
                })
            })
            .map(|(addr, _)| rank(addr))
            .min();
        if let Some(best) = best {
            let better_pending = addresses
                .iter()
                .enumerate()
                .any(|(i, addr)| pending[i] && rank(addr) < best);
            if !better_pending {
                break;
            }
        }
    }

    choose_address(&results, expected_server_id)
}

// ───────────────────────── Backoff ─────────────────────────

/// Configuration for the exponential backoff of the reconnection probes.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RetryBackoffConfig {
    pub initial_delay_ms: u64,
    pub factor_numerator: u64,
    pub factor_denominator: u64,
    pub max_delay_ms: u64,
}

impl Default for RetryBackoffConfig {
    fn default() -> Self {
        Self {
            initial_delay_ms: 5000,
            factor_numerator: 3,
            factor_denominator: 2, // 1.5x
            max_delay_ms: 60000,
        }
    }
}

/// Gestionnaire pur de backoff exponentiel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RetryBackoff {
    initial_delay: Duration,
    current_delay: Duration,
    factor_num: u64,
    factor_den: u64,
    max_delay: Duration,
}

impl RetryBackoff {
    pub fn new(
        initial_delay: Duration,
        factor_num: u64,
        factor_den: u64,
        max_delay: Duration,
    ) -> Self {
        let clamped_initial = initial_delay.min(max_delay);
        let safe_den = factor_den.max(1);
        let safe_num = factor_num.max(safe_den); // The factor cannot be below 1.0 (non-regressing delay)
        Self {
            initial_delay: clamped_initial,
            current_delay: clamped_initial,
            factor_num: safe_num,
            factor_den: safe_den,
            max_delay,
        }
    }

    pub fn from_config(config: &RetryBackoffConfig) -> Self {
        Self::new(
            Duration::from_millis(config.initial_delay_ms),
            config.factor_numerator,
            config.factor_denominator,
            Duration::from_millis(config.max_delay_ms),
        )
    }

    pub fn next_delay(&mut self) -> Duration {
        let delay = self.current_delay;
        let next_ms = (delay.as_millis() as u64).saturating_mul(self.factor_num) / self.factor_den;
        self.current_delay = Duration::from_millis(next_ms).min(self.max_delay);
        delay
    }

    pub fn current_delay(&self) -> Duration {
        self.current_delay
    }

    pub fn reset(&mut self) {
        self.current_delay = self.initial_delay;
    }
}

/// UniFFI object to expose the backoff logic to the Swift front end.
#[derive(uniffi::Object)]
pub struct ProberBackoff {
    inner: std::sync::Mutex<RetryBackoff>,
}

#[uniffi::export]
impl ProberBackoff {
    #[uniffi::constructor]
    pub fn new_default() -> Self {
        Self {
            inner: std::sync::Mutex::new(RetryBackoff::from_config(&RetryBackoffConfig::default())),
        }
    }

    #[uniffi::constructor]
    pub fn new_custom(
        initial_delay_ms: u64,
        factor_num: u64,
        factor_den: u64,
        max_delay_ms: u64,
    ) -> Self {
        Self {
            inner: std::sync::Mutex::new(RetryBackoff::new(
                Duration::from_millis(initial_delay_ms),
                factor_num,
                factor_den,
                Duration::from_millis(max_delay_ms),
            )),
        }
    }

    pub fn next_delay_ms(&self) -> u64 {
        let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        guard.next_delay().as_millis() as u64
    }

    pub fn current_delay_ms(&self) -> u64 {
        let guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        guard.current_delay().as_millis() as u64
    }

    pub fn reset(&self) {
        let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        guard.reset();
    }
}

// ───────────────────────── Profile Storage ─────────────────────────

/// Storage abstraction trait for the profiles.
pub trait ProfileStorage: Send + Sync {
    fn load_profiles(&self) -> Result<Vec<ServerProfile>, JellyfinError>;
    fn save_profiles(&self, profiles: &[ServerProfile]) -> Result<(), JellyfinError>;
    fn backup_corrupt_file(&self) -> Result<(), JellyfinError>;
}

/// Implementation of storage on a JSON file (Application Support).
pub struct JsonFileProfileStorage {
    path: PathBuf,
}

impl JsonFileProfileStorage {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }
}

impl ProfileStorage for JsonFileProfileStorage {
    fn load_profiles(&self) -> Result<Vec<ServerProfile>, JellyfinError> {
        if !self.path.exists() {
            return Ok(Vec::new());
        }
        let data = std::fs::read_to_string(&self.path)
            .map_err(|e| JellyfinError::Storage(format!("Could not read the profiles: {e}")))?;
        serde_json::from_str(&data).map_err(|decode_err| {
            JellyfinError::Decode(format!(
                "Could not deserialise the profiles file: {decode_err}"
            ))
        })
    }

    fn backup_corrupt_file(&self) -> Result<(), JellyfinError> {
        if !self.path.exists() {
            return Ok(());
        }
        let parent = self.path.parent().unwrap_or_else(|| Path::new("."));
        let file_name = self.path.file_name().unwrap_or_default().to_string_lossy();
        let prefix = format!("{file_name}.corrupt.");

        // Limit to 3 corrupted backup files to avoid unbounded accumulation
        if let Ok(entries) = std::fs::read_dir(parent) {
            let mut corrupt_files: Vec<_> = entries
                .filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().starts_with(&prefix))
                .collect();
            if corrupt_files.len() >= 3 {
                corrupt_files.sort_by_key(|e| e.file_name());
                for old in corrupt_files.iter().take(corrupt_files.len() - 2) {
                    // Deletion error ignored: a concurrent or transient lock
                    // must not block saving the current corrupted file.
                    let _ = std::fs::remove_file(old.path());
                }
            }
        }
        let now_nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| JellyfinError::Storage(format!("Invalid system clock: {e}")))?
            .as_nanos();
        let pid = std::process::id();
        let corrupt_path = self
            .path
            .with_file_name(format!("{prefix}{now_nanos:020}.{pid}"));
        std::fs::rename(&self.path, &corrupt_path).map_err(|e| {
            JellyfinError::Storage(format!(
                "Could not back up the corrupted file to {}: {e}",
                corrupt_path.display()
            ))
        })
    }

    fn save_profiles(&self, profiles: &[ServerProfile]) -> Result<(), JellyfinError> {
        let parent = self.path.parent().unwrap_or_else(|| Path::new("."));
        std::fs::create_dir_all(parent)
            .map_err(|e| JellyfinError::Storage(format!("Could not create the folder: {e}")))?;

        let json = serde_json::to_string_pretty(profiles)
            .map_err(|e| JellyfinError::Storage(format!("Could not format the profiles: {e}")))?;

        // Unique name with PID and timestamp to avoid collisions
        let now_nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let tmp_path = parent.join(format!(
            ".profiles.tmp.{}.{}",
            std::process::id(),
            now_nanos
        ));

        let write_and_sync = || -> std::io::Result<()> {
            use std::io::Write;
            let mut file = std::fs::File::create(&tmp_path)?;
            file.write_all(json.as_bytes())?;
            file.sync_all()?;
            std::fs::rename(&tmp_path, &self.path)?;
            Ok(())
        };

        if let Err(err) = write_and_sync() {
            let _ = std::fs::remove_file(&tmp_path);
            return Err(JellyfinError::Storage(format!(
                "Could not save the profiles atomically: {err}"
            )));
        }

        Ok(())
    }
}

/// In-memory storage implementation for unit / isolated tests.
#[derive(Default)]
pub struct MemoryProfileStorage {
    profiles: std::sync::Mutex<Vec<ServerProfile>>,
}

impl MemoryProfileStorage {
    pub fn new() -> Self {
        Self::default()
    }
}

impl ProfileStorage for MemoryProfileStorage {
    fn load_profiles(&self) -> Result<Vec<ServerProfile>, JellyfinError> {
        let guard = self.profiles.lock().unwrap_or_else(|e| e.into_inner());
        Ok(guard.clone())
    }

    fn save_profiles(&self, profiles: &[ServerProfile]) -> Result<(), JellyfinError> {
        let mut guard = self.profiles.lock().unwrap_or_else(|e| e.into_inner());
        *guard = profiles.to_vec();
        Ok(())
    }

    fn backup_corrupt_file(&self) -> Result<(), JellyfinError> {
        Ok(())
    }
}

/// Thread-safe profile manager exposed to UniFFI.
#[derive(uniffi::Object)]
pub struct ProfileStoreCore {
    storage: Box<dyn ProfileStorage>,
    lock: std::sync::Mutex<()>,
}

#[uniffi::export(async_runtime = "tokio")]
impl ProfileStoreCore {
    #[uniffi::constructor]
    pub fn new(storage_dir: &str) -> Self {
        let path = PathBuf::from(storage_dir).join("profiles.json");
        Self {
            storage: Box::new(JsonFileProfileStorage::new(path)),
            lock: std::sync::Mutex::new(()),
        }
    }

    pub fn load_all(&self) -> Result<Vec<ServerProfile>, JellyfinError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        self.storage.load_profiles()
    }

    pub fn save_all(&self, profiles: Vec<ServerProfile>) -> Result<(), JellyfinError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        self.storage.save_profiles(&profiles)
    }

    pub fn primary_profile(&self) -> Result<Option<ServerProfile>, JellyfinError> {
        let all = self.load_all()?;
        Ok(all
            .iter()
            .find(|p| p.is_primary)
            .cloned()
            .or_else(|| all.first().cloned()))
    }

    pub fn save_profile(&self, profile: ServerProfile) -> Result<(), JellyfinError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let mut all = self.storage.load_profiles()?;
        if let Some(idx) = all
            .iter()
            .position(|p| p.server_id == profile.server_id && p.user_id == profile.user_id)
        {
            all[idx] = profile.clone();
        } else {
            all.push(profile.clone());
        }
        if profile.is_primary {
            for p in &mut all {
                p.is_primary = p.server_id == profile.server_id && p.user_id == profile.user_id;
            }
        }
        self.storage.save_profiles(&all)
    }

    /// Explicit reset after corruption: backs up the corrupted file
    /// to `profiles.json.corrupt.<ts>.<pid>` and initialises a new empty file.
    /// First checks that the storage is actually corrupted (Decode) before overwriting (Pitfall 19).
    pub fn reset_corrupt_storage(&self) -> Result<(), JellyfinError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        match self.storage.load_profiles() {
            Ok(_) => {
                log::info!("reset_corrupt_storage: storage is healthy, no reset needed");
                Ok(())
            }
            Err(JellyfinError::Decode(_)) => {
                log::warn!("Explicit reset of the corrupted profile storage");
                self.storage.backup_corrupt_file()?;
                self.storage.save_profiles(&[])
            }
            Err(err) => Err(err),
        }
    }

    /// Probes the address via GET /System/Info/Public, validates its identifier and version,
    /// then adds it to the saved profile safely (Pitfall 3 & 16).
    pub async fn verify_and_add_address(
        &self,
        server_id: &str,
        address: ServerAddress,
        timeout_ms: u64,
    ) -> Result<ServerPublicInfo, JellyfinError> {
        let clean_url = normalize_server_url(&address.url);
        let http = probe_http_client()?;
        let info =
            probe_server_address(http, &clean_url, Duration::from_millis(timeout_ms)).await?;
        let mut normalized_addr = address;
        normalized_addr.url = clean_url;
        self.add_address(server_id, normalized_addr, info.clone())?;
        Ok(info)
    }

    pub fn clear(&self) -> Result<(), JellyfinError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        self.storage.save_profiles(&[])
    }
}

impl ProfileStoreCore {
    /// Constructor with storage injection for the tests.
    #[cfg(test)]
    pub(crate) fn with_storage(storage: Box<dyn ProfileStorage>) -> Self {
        Self {
            storage,
            lock: std::sync::Mutex::new(()),
        }
    }

    /// Adds an address to an existing profile after strict validation of the server information.
    /// Not exported by UniFFI (Pitfall 16): only `verify_and_add_address` is accessible from Swift.
    pub(crate) fn add_address(
        &self,
        server_id: &str,
        address: ServerAddress,
        verified_info: ServerPublicInfo,
    ) -> Result<(), JellyfinError> {
        let expected = server_id.trim();
        if expected.is_empty() {
            return Err(JellyfinError::InvalidInput(
                "The server identifier cannot be empty".into(),
            ));
        }
        if !expected.eq_ignore_ascii_case(&verified_info.id) {
            return Err(JellyfinError::ServerMismatch(format!(
                "The tested address belongs to server '{}' (ID: {}), different from the expected server '{}'",
                verified_info.server_name, verified_info.id, expected
            )));
        }
        if !is_supported_version(&verified_info.version) {
            return Err(JellyfinError::UnsupportedServerVersion(
                verified_info.version,
            ));
        }
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let mut all = self.storage.load_profiles()?;
        let profile_exists = all.iter().any(|p| p.server_id == expected);
        if !profile_exists {
            return Err(JellyfinError::NotFound(format!(
                "No profile found for the server identifier {expected}"
            )));
        }
        let mut updated = false;
        let target_norm = normalize_server_url(&address.url);
        for p in &mut all {
            if p.server_id == expected
                && !p
                    .addresses
                    .iter()
                    .any(|a| normalize_server_url(&a.url) == target_norm)
            {
                let mut normalized_addr = address.clone();
                normalized_addr.url = target_norm.clone();
                p.addresses.push(normalized_addr);
                sort_addresses_by_priority(&mut p.addresses);
                updated = true;
            }
        }
        if updated {
            self.storage.save_profiles(&all)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_addr(url: &str, label: &str, p: u32) -> ServerAddress {
        ServerAddress::new(url, label, p)
    }

    fn make_info(id: &str, name: &str) -> ServerPublicInfo {
        ServerPublicInfo {
            id: id.to_string(),
            server_name: name.to_string(),
            version: "10.9.7".to_string(),
        }
    }

    fn make_profile(id: &str, name: &str, user: &str) -> ServerProfile {
        ServerProfile {
            server_id: id.into(),
            server_name: name.into(),
            user_id: user.into(),
            user_name: user.into(),
            user_avatar_tag: None,
            addresses: vec![make_addr("http://localhost:8096", "Local", 1)],
            is_primary: true,
            forced_address: None,
        }
    }

    #[test]
    fn test_is_local_address() {
        assert!(is_local_address("http://192.168.1.50:8096"));
        assert!(is_local_address("http://10.0.0.1:8096"));
        assert!(is_local_address("http://172.20.0.5:8096"));
        assert!(is_local_address("http://127.0.0.1:8096"));
        assert!(is_local_address("http://localhost:8096"));
        assert!(is_local_address("http://myserver.local:8096"));
        assert!(is_local_address("http://MYSERVER.LOCAL:8096"));
        // IPv6 tests
        assert!(is_local_address("http://[::1]:8096"));
        assert!(is_local_address("http://[fd00::1]:8096"));
        assert!(is_local_address("http://[fe80::1]:8096"));

        assert!(!is_local_address("https://jellyfin.example.com"));
        assert!(!is_local_address("http://8.8.8.8:8096"));
        assert!(!is_local_address("http://[2001:4860:4860::8888]:8096"));
        assert!(!is_local_address("invalid-url"));
    }

    #[test]
    fn test_normalize_server_url() {
        assert_eq!(
            normalize_server_url("192.168.1.50:8096"),
            "http://192.168.1.50:8096"
        );
        assert_eq!(
            normalize_server_url("http://192.168.1.50:8096/"),
            "http://192.168.1.50:8096"
        );
        assert_eq!(
            normalize_server_url("HTTP://192.168.1.50:8096/"),
            "http://192.168.1.50:8096"
        );
        assert_eq!(
            normalize_server_url("https://jellyfin.example.com/"),
            "https://jellyfin.example.com"
        );
        assert_eq!(
            normalize_server_url("HTTPS://jellyfin.example.com///"),
            "https://jellyfin.example.com"
        );
    }

    #[test]
    fn test_version_check() {
        assert!(is_supported_version("10.9.0"));
        assert!(is_supported_version("10.9.7"));
        assert!(is_supported_version("10.10.1"));
        assert!(is_supported_version("11.0.0"));

        assert!(!is_supported_version("10.8.13"));
        assert!(!is_supported_version("10.7.7"));
        assert!(!is_supported_version("9.4.0"));
        assert!(!is_supported_version("invalid"));
    }

    #[test]
    fn test_server_address_constructor() {
        let local = ServerAddress::new("http://192.168.1.20:8096/", "Home", 1);
        assert_eq!(local.url, "http://192.168.1.20:8096");
        assert!(local.is_local);
        assert_eq!(local.priority, 1);

        let remote = ServerAddress::new("https://jf.example.com/", "Outside", 2);
        assert_eq!(remote.url, "https://jf.example.com");
        assert!(!remote.is_local);
        assert_eq!(remote.priority, 2);
    }

    #[test]
    fn test_sort_addresses_by_priority() {
        let mut list = vec![
            make_addr("https://remote2.example.com", "Remote 2", 3),
            make_addr("https://remote1.example.com", "Remote 1", 1),
            make_addr("http://192.168.1.50:8096", "LAN", 1),
            make_addr("http://10.0.0.5:8096", "LAN 2", 2),
        ];
        sort_addresses_by_priority(&mut list);
        assert_eq!(list[0].url, "http://192.168.1.50:8096");
        assert_eq!(list[1].url, "https://remote1.example.com");
        assert_eq!(list[2].url, "http://10.0.0.5:8096");
        assert_eq!(list[3].url, "https://remote2.example.com");
    }

    #[test]
    fn test_choose_address_pure_evaluation_and_server_id_verification() {
        let addr_lan = make_addr("http://192.168.1.50:8096", "LAN", 1);
        let addr_wan = make_addr("https://remote.example.com", "WAN", 2);
        let addr_rogue = make_addr("http://192.168.1.99:8096", "Rogue", 1);
        let valid_info = make_info("server-uuid-123", "MyServer");
        let wrong_info = make_info("different-server-uuid", "Intruder");

        // Case 1: LAN and WAN match server ID -> LAN chosen because priority 1 vs 2
        let results = vec![
            (addr_wan.clone(), Ok(valid_info.clone())),
            (addr_lan.clone(), Ok(valid_info.clone())),
        ];
        let chosen = choose_address(&results, "server-uuid-123").expect("LAN");
        assert_eq!(chosen.url, "http://192.168.1.50:8096");

        // Case 2: LAN returns wrong server ID -> Rejected, WAN chosen
        let results_mismatch = vec![
            (addr_wan.clone(), Ok(valid_info.clone())),
            (addr_lan.clone(), Ok(wrong_info.clone())),
        ];
        let chosen_wan = choose_address(&results_mismatch, "server-uuid-123").expect("WAN");
        assert_eq!(chosen_wan.url, "https://remote.example.com");

        // Case 3: Rogue server responds with mismatch, but WAN timed out -> ServerUnreachable so prober continues
        let results_partial_mismatch = vec![
            (addr_rogue.clone(), Ok(wrong_info.clone())),
            (
                addr_wan.clone(),
                Err(JellyfinError::ServerUnreachable("timeout".into())),
            ),
        ];
        match choose_address(&results_partial_mismatch, "server-uuid-123") {
            Err(JellyfinError::ServerUnreachable(_)) => {}
            other => panic!(
                "Expected ServerUnreachable for partial mismatch, got {:?}",
                other
            ),
        }

        // Case 3a: ALL servers respond with wrong server ID -> ServerMismatch
        let results_all_mismatched = vec![
            (addr_rogue, Ok(wrong_info.clone())),
            (addr_lan.clone(), Ok(wrong_info)),
        ];
        match choose_address(&results_all_mismatched, "server-uuid-123") {
            Err(JellyfinError::ServerMismatch(msg)) => {
                assert!(msg.contains("different-server-uuid"))
            }
            other => panic!(
                "Expected ServerMismatch error when all mismatch, got {:?}",
                other
            ),
        }

        // Case 3b: All servers unreachable -> ServerUnreachable
        let results_all_down = vec![
            (
                addr_wan.clone(),
                Err(JellyfinError::ServerUnreachable("timeout".into())),
            ),
            (
                addr_lan.clone(),
                Err(JellyfinError::ServerUnreachable("refused".into())),
            ),
        ];
        match choose_address(&results_all_down, "server-uuid-123") {
            Err(JellyfinError::ServerUnreachable(_)) => {}
            other => panic!("Expected ServerUnreachable when all down, got {:?}", other),
        }

        // Case 3c: Tie break on priority -> local address wins
        let tie_results = vec![
            (
                make_addr("https://remote.example.com", "R", 1),
                Ok(valid_info.clone()),
            ),
            (
                make_addr("http://192.168.1.50:8096", "L", 1),
                Ok(valid_info),
            ),
        ];
        let chosen_tie = choose_address(&tie_results, "server-uuid-123").expect("Tie break");
        assert_eq!(chosen_tie.url, "http://192.168.1.50:8096");

        // Case 3d: Server returns empty ID -> Rejected as mismatch
        let results_empty_id = vec![(addr_lan.clone(), Ok(make_info("", "No ID")))];
        match choose_address(&results_empty_id, "server-uuid-123") {
            Err(JellyfinError::ServerMismatch(_)) => {}
            other => panic!(
                "Expected ServerMismatch on empty server ID response, got {:?}",
                other
            ),
        }

        // Case 4: Empty results -> InvalidInput
        match choose_address(&[], "server-uuid-123") {
            Err(JellyfinError::InvalidInput(_)) => {}
            other => panic!("Expected InvalidInput for empty results, got: {:?}", other),
        }

        // Case 5: Empty expected server ID -> InvalidInput (Pitfall 1 & 2)
        match choose_address(&results, "") {
            Err(JellyfinError::InvalidInput(_)) => {}
            other => panic!(
                "Expected InvalidInput for empty server ID, got: {:?}",
                other
            ),
        }
        match choose_address(&results, "   ") {
            Err(JellyfinError::InvalidInput(_)) => {}
            other => panic!(
                "Expected InvalidInput for whitespace server ID, got: {:?}",
                other
            ),
        }
    }

    #[test]
    fn test_retry_backoff_progression() {
        let mut backoff = RetryBackoff::new(
            Duration::from_millis(1000),
            3,
            2, // 1.5x
            Duration::from_millis(5000),
        );

        assert_eq!(backoff.next_delay(), Duration::from_millis(1000));
        assert_eq!(backoff.next_delay(), Duration::from_millis(1500));
        assert_eq!(backoff.next_delay(), Duration::from_millis(2250));
        assert_eq!(backoff.next_delay(), Duration::from_millis(3375));
        assert_eq!(backoff.next_delay(), Duration::from_millis(5000));
        // Clamped at max
        assert_eq!(backoff.next_delay(), Duration::from_millis(5000));

        backoff.reset();
        assert_eq!(backoff.next_delay(), Duration::from_millis(1000));
    }

    #[test]
    fn test_retry_backoff_edge_cases() {
        // Initial delay greater than max_delay -> Clamped to max_delay
        let mut b1 = RetryBackoff::new(
            Duration::from_millis(10000),
            2,
            1,
            Duration::from_millis(5000),
        );
        assert_eq!(b1.current_delay(), Duration::from_millis(5000));
        assert_eq!(b1.next_delay(), Duration::from_millis(5000));

        // Zero factor numerator / denominator clamped to at least 1
        let mut b2 = RetryBackoff::new(
            Duration::from_millis(1000),
            0,
            0,
            Duration::from_millis(5000),
        );
        assert_eq!(b2.next_delay(), Duration::from_millis(1000));
        assert_eq!(b2.next_delay(), Duration::from_millis(1000));

        // Denominator greater than numerator (factor < 1.0) is clamped to 1.0 (non-shrinking delay)
        let mut b3 = RetryBackoff::new(
            Duration::from_millis(4000),
            1,
            2, // 0.5x -> clamped to 1.0x
            Duration::from_millis(5000),
        );
        assert_eq!(b3.next_delay(), Duration::from_millis(4000));
        assert_eq!(b3.next_delay(), Duration::from_millis(4000));
        assert_eq!(b3.next_delay(), Duration::from_millis(4000));

        // From config
        let cfg = RetryBackoffConfig::default();
        let b4 = RetryBackoff::from_config(&cfg);
        assert_eq!(b4.current_delay(), Duration::from_millis(5000));
    }

    #[test]
    fn test_prober_backoff_uniffi_object() {
        let prober = ProberBackoff::new_default();
        assert_eq!(prober.current_delay_ms(), 5000);
        assert_eq!(prober.next_delay_ms(), 5000);
        assert_eq!(prober.next_delay_ms(), 7500);
        prober.reset();
        assert_eq!(prober.current_delay_ms(), 5000);

        let custom = ProberBackoff::new_custom(200, 2, 1, 1000);
        assert_eq!(custom.next_delay_ms(), 200);
        assert_eq!(custom.next_delay_ms(), 400);
    }

    #[test]
    fn test_memory_profile_storage() {
        let storage = MemoryProfileStorage::new();
        assert_eq!(storage.load_profiles().unwrap(), vec![]);

        let profile = make_profile("s1", "TestServer", "Alice");
        storage.save_profiles(&[profile]).unwrap();
        let loaded = storage.load_profiles().unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].server_id, "s1");
    }

    #[test]
    fn test_legacy_fixture_deserialization_and_store_load() {
        let fixture_data = include_str!("../tests/fixtures/legacy_profiles.json");
        let profiles: Vec<ServerProfile> =
            serde_json::from_str(fixture_data).expect("Must deserialize camelCase legacy profiles");

        assert_eq!(profiles.len(), 1);
        let p = &profiles[0];
        assert_eq!(p.server_id, "srv-legacy-uuid-1");
        assert_eq!(p.server_name, "Legacy Server");
        assert_eq!(p.user_id, "user-uuid-1");
        assert_eq!(p.user_name, "Alice");
        assert!(p.is_primary);
        assert_eq!(p.addresses.len(), 2);
        assert_eq!(p.addresses[0].url, "http://192.0.2.10:8096");
        assert!(p.addresses[0].is_local);
        assert_eq!(p.addresses[1].url, "https://jellyfin.example.com");
        assert!(!p.addresses[1].is_local);

        // Test loading through ProfileStoreCore from disk (Pitfall 10)
        let temp_dir =
            std::env::temp_dir().join(format!("jn_test_legacy_fixture_{}", std::process::id()));
        std::fs::create_dir_all(&temp_dir).unwrap();
        let file_path = temp_dir.join("profiles.json");
        std::fs::write(&file_path, fixture_data).unwrap();

        let store = ProfileStoreCore::new(temp_dir.to_str().unwrap());
        let loaded = store
            .load_all()
            .expect("Must load legacy profiles via ProfileStoreCore");
        assert_eq!(loaded, profiles);

        // Test omitted userAvatarTag (when JSONEncoder serializes nil as missing key)
        let json_omitted_avatar = r#"[
            {
                "serverId": "srv-omitted-avatar",
                "serverName": "Server Without Avatar",
                "userId": "user-uuid-2",
                "userName": "Bob",
                "addresses": [
                    {
                        "url": "http://192.0.2.20:8096",
                        "label": "Home",
                        "priority": 1,
                        "isLocal": true
                    }
                ],
                "isPrimary": false
            }
        ]"#;
        let parsed: Vec<ServerProfile> = serde_json::from_str(json_omitted_avatar)
            .expect("Must deserialize profile when optional userAvatarTag is omitted");
        assert_eq!(parsed[0].user_avatar_tag, None);

        let _ = std::fs::remove_dir_all(temp_dir);
    }

    #[test]
    fn test_profile_store_core_operations() {
        let temp_dir = std::env::temp_dir().join(format!("jn_test_ops_{}", std::process::id()));
        let store = ProfileStoreCore::new(temp_dir.to_str().unwrap());

        store
            .save_profile(make_profile("s1", "Server 1", "Alice"))
            .unwrap();
        assert_eq!(store.primary_profile().unwrap().unwrap().server_id, "s1");

        // Add secondary address with verified info
        store
            .add_address(
                "s1",
                make_addr("https://remote.example.com", "Remote", 2),
                make_info("s1", "Server 1"),
            )
            .unwrap();

        let updated = store.primary_profile().unwrap().unwrap();
        assert_eq!(updated.addresses.len(), 2);
        assert_eq!(updated.addresses[1].url, "https://remote.example.com");

        // Duplicate address with trailing slash / normalization must be deduplicated
        store
            .add_address(
                "s1",
                make_addr("http://localhost:8096/", "Duplicate", 1),
                make_info("s1", "Server 1"),
            )
            .unwrap();
        let after_dup = store.primary_profile().unwrap().unwrap();
        assert_eq!(after_dup.addresses.len(), 2);

        // Server mismatch must return ServerMismatch error
        match store.add_address(
            "s1",
            make_addr("http://192.0.2.1:8096", "Other", 1),
            make_info("rogue-server", "Rogue"),
        ) {
            Err(JellyfinError::ServerMismatch(_)) => {}
            other => panic!("Expected ServerMismatch, got: {:?}", other),
        }

        // Non-existent server ID must return NotFound error
        match store.add_address(
            "unknown",
            make_addr("http://192.0.2.1:8096", "Other", 1),
            make_info("unknown", "Unknown"),
        ) {
            Err(JellyfinError::NotFound(_)) => {}
            other => panic!("Expected NotFound, got: {:?}", other),
        }

        // Empty server ID must return InvalidInput error
        match store.add_address(
            "",
            make_addr("http://192.0.2.1:8096", "Other", 1),
            make_info("", "Empty"),
        ) {
            Err(JellyfinError::InvalidInput(_)) => {}
            other => panic!("Expected InvalidInput, got: {:?}", other),
        }

        store.clear().unwrap();
        assert_eq!(store.load_all().unwrap().len(), 0);
        let _ = std::fs::remove_dir_all(temp_dir);
    }

    #[test]
    fn test_profile_store_core_corrupt_file_handling() {
        let temp_dir = std::env::temp_dir().join(format!("jn_test_corrupt_{}", std::process::id()));
        std::fs::create_dir_all(&temp_dir).unwrap();
        let file_path = temp_dir.join("profiles.json");
        let corrupt_content = "not a valid json content";
        std::fs::write(&file_path, corrupt_content).unwrap();

        let store = ProfileStoreCore::new(temp_dir.to_str().unwrap());

        // load_all must return Err and not swallow (Pitfall 1)
        assert!(
            store.load_all().is_err(),
            "Must propagate error on corrupt file"
        );

        // load_all must be idempotent and free of side effects (does not delete or rename on read)
        assert!(
            store.load_all().is_err(),
            "Repeated load_all must consistently return error"
        );
        let backups_before_save: Vec<_> = std::fs::read_dir(&temp_dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".corrupt."))
            .collect();
        assert_eq!(
            backups_before_save.len(),
            0,
            "No corrupt backup should be created by read operations"
        );

        // save_profile must refuse to overwrite corrupt file to prevent silent data loss
        let save_res = store.save_profile(make_profile("s1", "Server 1", "Alice"));
        assert!(save_res.is_err(), "Must refuse to overwrite corrupt file");

        // Explicit reset after corruption backs up the corrupt file and initializes a fresh store
        store.reset_corrupt_storage().unwrap();

        let corrupt_backups: Vec<_> = std::fs::read_dir(&temp_dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".corrupt."))
            .collect();
        assert_eq!(
            corrupt_backups.len(),
            1,
            "Must create 1 corrupt backup file during explicit reset"
        );
        let backup_content = std::fs::read_to_string(corrupt_backups[0].path()).unwrap();
        assert_eq!(
            backup_content, corrupt_content,
            "Backup file must preserve original corrupt content exactly"
        );

        // Now save_profile succeeds on the freshly reset store
        store
            .save_profile(make_profile("s1", "Server 1", "Alice"))
            .unwrap();
        let reloaded = store.load_all().unwrap();
        assert_eq!(reloaded.len(), 1);
        assert_eq!(reloaded[0].server_id, "s1");

        let _ = std::fs::remove_dir_all(temp_dir);
    }

    struct FailingBackupStorage {
        is_corrupt: bool,
        save_called: std::sync::Arc<std::sync::atomic::AtomicBool>,
    }

    impl ProfileStorage for FailingBackupStorage {
        fn load_profiles(&self) -> Result<Vec<ServerProfile>, JellyfinError> {
            if self.is_corrupt {
                Err(JellyfinError::Decode("corrupt json".into()))
            } else {
                Ok(Vec::new())
            }
        }

        fn save_profiles(&self, _profiles: &[ServerProfile]) -> Result<(), JellyfinError> {
            self.save_called
                .store(true, std::sync::atomic::Ordering::SeqCst);
            Ok(())
        }

        fn backup_corrupt_file(&self) -> Result<(), JellyfinError> {
            Err(JellyfinError::Storage("Simulated rename error".into()))
        }
    }

    #[test]
    fn test_profile_store_corrupt_rename_failure_does_not_overwrite() {
        use std::sync::Arc;
        use std::sync::atomic::Ordering;
        let save_called = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let storage = Box::new(FailingBackupStorage {
            is_corrupt: true,
            save_called: Arc::clone(&save_called),
        });
        let store = ProfileStoreCore::with_storage(storage);
        let reset_res = store.reset_corrupt_storage();
        match reset_res {
            Err(JellyfinError::Storage(msg)) => {
                assert!(msg.contains("Simulated rename error"));
            }
            other => panic!("Expected JellyfinError::Storage, got {:?}", other),
        }
        assert!(
            !save_called.load(Ordering::SeqCst),
            "save_profiles must not be called when backup_corrupt_file fails"
        );
    }

    #[test]
    fn test_profile_store_reset_corrupt_storage_on_healthy_store_does_nothing() {
        let storage = MemoryProfileStorage::new();
        let p = ServerProfile {
            server_id: "s1".into(),
            server_name: "Server 1".into(),
            user_id: "u1".into(),
            user_name: "Alice".into(),
            user_avatar_tag: None,
            addresses: vec![ServerAddress::new("http://example.com", "Main", 1)],
            is_primary: true,
            forced_address: None,
        };
        storage.save_profiles(&[p]).unwrap();
        let store = ProfileStoreCore::with_storage(Box::new(storage));

        // Calling reset on healthy storage must return Ok and NOT wipe profiles
        let res = store.reset_corrupt_storage();
        assert!(res.is_ok());
        let all = store.load_all().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].server_id, "s1");
    }

    #[test]
    fn test_add_address_sorts_by_priority_and_locality() {
        let store = ProfileStoreCore::with_storage(Box::new(MemoryProfileStorage::new()));
        let p = ServerProfile {
            server_id: "srv-order".into(),
            server_name: "Server".into(),
            user_id: "u1".into(),
            user_name: "Alice".into(),
            user_avatar_tag: None,
            addresses: vec![ServerAddress {
                url: "http://remote-p2.example.com".into(),
                label: "Remote P2".into(),
                priority: 2,
                is_local: false,
            }],
            is_primary: true,
            forced_address: None,
        };
        store.save_profile(p).unwrap();

        let info = ServerPublicInfo {
            id: "srv-order".into(),
            server_name: "Server".into(),
            version: "10.9.0".into(),
        };

        // Add remote p1
        store
            .add_address(
                "srv-order",
                ServerAddress {
                    url: "http://remote-p1.example.com".into(),
                    label: "Remote P1".into(),
                    priority: 1,
                    is_local: false,
                },
                info.clone(),
            )
            .unwrap();

        // Add local p1
        store
            .add_address(
                "srv-order",
                ServerAddress {
                    url: "http://local-p1.example.com".into(),
                    label: "Local P1".into(),
                    priority: 1,
                    is_local: true,
                },
                info.clone(),
            )
            .unwrap();

        let profile = store.primary_profile().unwrap().unwrap();
        assert_eq!(profile.addresses.len(), 3);
        // Order must be: 1. local p1, 2. remote p1, 3. remote p2
        assert_eq!(profile.addresses[0].url, "http://local-p1.example.com");
        assert_eq!(profile.addresses[1].url, "http://remote-p1.example.com");
        assert_eq!(profile.addresses[2].url, "http://remote-p2.example.com");
    }

    #[tokio::test]
    async fn test_verify_and_add_address_tokio() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();

        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let mut buf = [0u8; 1024];
                    let _ = socket.read(&mut buf).await;
                    let body = r#"{"Id":"srv-verify-1","ServerName":"Verified Server","Version":"10.9.7"}"#;
                    let resp = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = socket.write_all(resp.as_bytes()).await;
                });
            }
        });

        let store = ProfileStoreCore::with_storage(Box::new(MemoryProfileStorage::new()));
        let p = ServerProfile {
            server_id: "srv-verify-1".into(),
            server_name: "Verified Server".into(),
            user_id: "u1".into(),
            user_name: "Bob".into(),
            user_avatar_tag: None,
            addresses: vec![ServerAddress::new("http://initial.example.com", "Init", 1)],
            is_primary: true,
            forced_address: None,
        };
        store.save_profile(p).unwrap();

        let unnormalized_url = format!("http://127.0.0.1:{port}///");
        let new_addr = ServerAddress {
            url: unnormalized_url,
            label: "Mock LAN".into(),
            priority: 1,
            is_local: true,
        };

        // 1. Success with matching server_id and normalizes URL
        let info = store
            .verify_and_add_address("srv-verify-1", new_addr.clone(), 3000)
            .await
            .unwrap();
        assert_eq!(info.id, "srv-verify-1");
        assert_eq!(info.version, "10.9.7");

        let reloaded = store.primary_profile().unwrap().unwrap();
        assert_eq!(reloaded.addresses.len(), 2);
        // Trailing slashes must be stripped in stored URL
        assert_eq!(
            reloaded.addresses[0].url,
            format!("http://127.0.0.1:{port}")
        );

        // 2. Mismatched server ID returns ServerMismatch, profile addresses unmodified
        let mismatch_addr = ServerAddress {
            url: format!("http://127.0.0.1:{port}"),
            label: "Mismatch".into(),
            priority: 2,
            is_local: false,
        };
        let mismatch_err = store
            .verify_and_add_address("different-srv", mismatch_addr, 3000)
            .await;
        match mismatch_err {
            Err(JellyfinError::ServerMismatch(_)) => {}
            other => panic!("Expected ServerMismatch, got {:?}", other),
        }
        assert_eq!(store.primary_profile().unwrap().unwrap().addresses.len(), 2);

        // 3. Unsupported server version
        let listener_old = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port_old = listener_old.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener_old.accept().await {
                tokio::spawn(async move {
                    let mut buf = [0u8; 1024];
                    let _ = socket.read(&mut buf).await;
                    let body = r#"{"Id":"srv-old","ServerName":"Old Server","Version":"10.8.13"}"#;
                    let resp = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = socket.write_all(resp.as_bytes()).await;
                });
            }
        });

        let p_old = ServerProfile {
            server_id: "srv-old".into(),
            server_name: "Old Server".into(),
            user_id: "u1".into(),
            user_name: "Bob".into(),
            user_avatar_tag: None,
            addresses: vec![ServerAddress::new("http://initial.example.com", "Init", 1)],
            is_primary: false,
            forced_address: None,
        };
        store.save_profile(p_old).unwrap();

        let old_addr = ServerAddress {
            url: format!("http://127.0.0.1:{port_old}"),
            label: "Old".into(),
            priority: 1,
            is_local: true,
        };
        let old_err = store
            .verify_and_add_address("srv-old", old_addr, 3000)
            .await;
        match old_err {
            Err(JellyfinError::UnsupportedServerVersion(v)) => {
                assert_eq!(v, "10.8.13");
            }
            other => panic!("Expected UnsupportedServerVersion, got {:?}", other),
        }

        // 4. Unreachable address
        let dead_addr = ServerAddress {
            url: "http://127.0.0.1:1".into(),
            label: "Dead".into(),
            priority: 1,
            is_local: true,
        };
        let unreachable_err = store
            .verify_and_add_address("srv-verify-1", dead_addr, 1000)
            .await;
        match unreachable_err {
            Err(JellyfinError::ServerUnreachable(_)) => {}
            other => panic!("Expected ServerUnreachable, got {:?}", other),
        }
    }

    #[test]
    fn test_profile_store_corrupt_retention_limit_keeps_latest_3() {
        let temp_dir =
            std::env::temp_dir().join(format!("jn_test_retention_{}", std::process::id()));
        std::fs::create_dir_all(&temp_dir).unwrap();
        let file_path = temp_dir.join("profiles.json");

        // Creates 4 old backups with timestamps sortable by file name
        for i in 1..=4 {
            let old_backup = temp_dir.join(format!("profiles.json.corrupt.{i:020}.{i}"));
            std::fs::write(&old_backup, format!("corrupt content {i}")).unwrap();
        }

        // Creates a new corrupted file
        std::fs::write(&file_path, "corrupt content current").unwrap();

        let storage = JsonFileProfileStorage::new(file_path.clone());
        storage.backup_corrupt_file().unwrap();

        let prefix = "profiles.json.corrupt.";
        let remaining_backups: Vec<_> = std::fs::read_dir(&temp_dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().starts_with(prefix))
            .collect();

        assert_eq!(
            remaining_backups.len(),
            3,
            "Must retain exactly 3 corrupt backups"
        );

        let _ = std::fs::remove_dir_all(temp_dir);
    }

    #[test]
    fn reorder_moves_an_address_and_renumbers_priorities() {
        let list = vec![
            ServerAddress::new("http://192.0.2.10:8096", "Home", 1),
            ServerAddress::new("https://jf.example.com", "Remote", 2),
            ServerAddress::new("https://backup.example.com", "Backup", 3),
        ];
        let moved = reorder_addresses(list.clone(), 2, 0);
        assert_eq!(
            moved.iter().map(|a| a.label.as_str()).collect::<Vec<_>>(),
            ["Backup", "Home", "Remote"]
        );
        assert_eq!(
            moved.iter().map(|a| a.priority).collect::<Vec<_>>(),
            [1, 2, 3]
        );
        let same = reorder_addresses(list, 0, 9);
        assert_eq!(same[0].label, "Home");
    }

    #[test]
    fn plain_http_on_a_remote_host_is_flagged() {
        assert!(address_sends_token_unencrypted(
            "http://jf.example.com:8096".into()
        ));
        assert!(address_sends_token_unencrypted("jf.example.com".into()));
        assert!(!address_sends_token_unencrypted(
            "https://jf.example.com".into()
        ));
        assert!(!address_sends_token_unencrypted(
            "http://192.168.1.10:8096".into()
        ));
        assert!(!address_sends_token_unencrypted(
            "http://localhost:8096".into()
        ));
    }
}
