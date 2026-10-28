#![deny(clippy::unwrap_used, clippy::expect_used)]
#![cfg_attr(
    test,
    allow(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::field_reassign_with_default
    )
)]

pub mod blurhash;
mod client;
mod dates;
pub mod discovery;
pub mod downloads;
mod error;
mod media_info;
mod models;
pub mod profiles;
pub mod settings;
pub mod store;

pub use blurhash::*;
pub use client::*;
pub use dates::*;
pub use discovery::*;
pub use downloads::*;
pub use error::*;
pub use media_info::*;
pub use models::*;
pub use profiles::*;
pub use settings::*;

use std::time::Duration;

uniffi::setup_scaffolding!();

// Identity of the application, sent to the server with every request.
const CLIENT: &str = "Playfin";
const DEVICE: &str = "Mac";
/// Device identifier used before each installation had its own: sessions already
/// saved keep it until the user signs in again.
const LEGACY_DEVICE_ID: &str = "playfin-mac-dev";
const DEVICE_ID_FILE: &str = "device_id";
const MIN_DISCOVERY_TIMEOUT_MS: u64 = 250;
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Current version of the Rust core.
#[uniffi::export]
pub fn core_version() -> String {
    VERSION.to_string()
}

/// Discovers local Jellyfin servers via UDP broadcast (port 7359).
#[uniffi::export(async_runtime = "tokio")]
pub async fn discover_servers(timeout_ms: u64) -> Result<Vec<DiscoveredServer>, JellyfinError> {
    discovery::discover_local_servers(effective_discovery_timeout(timeout_ms)).await
}

/// A zero wait would leave the servers no time to answer: a minimum is imposed.
fn effective_discovery_timeout(timeout_ms: u64) -> Duration {
    Duration::from_millis(timeout_ms.max(MIN_DISCOVERY_TIMEOUT_MS))
}

/// Validates that a server URL responds to a supported Jellyfin server (>= 10.9) using the shared probe client (P14).
#[uniffi::export(async_runtime = "tokio")]
pub async fn validate_server(url: &str) -> Result<ServerPublicInfo, JellyfinError> {
    let http = profiles::probe_http_client()?;
    profiles::probe_server_address(http, url, Duration::from_millis(2500)).await
}

/// Probes candidate server addresses in parallel and returns the best reachable address using the shared probe client (P14).
#[uniffi::export(async_runtime = "tokio")]
pub async fn select_best_address(
    addresses: Vec<ServerAddress>,
    expected_server_id: &str,
) -> Result<ServerAddress, JellyfinError> {
    let http = profiles::probe_http_client()?;
    profiles::select_active_address(
        http,
        &addresses,
        expected_server_id,
        Duration::from_millis(1500),
    )
    .await
}

/// Tells whether an address corresponds to a local network (private IP, loopback, .local).
#[uniffi::export]
pub fn check_is_local_address(url: &str) -> bool {
    profiles::is_local_address(url)
}

/// Normalises a Jellyfin server URL (adds the default scheme, removes trailing slashes).
#[uniffi::export]
pub fn normalize_url(url: &str) -> String {
    profiles::normalize_server_url(url)
}

/// Decodes a BlurHash into an array of RGBA bytes (width * height * 4).
#[uniffi::export]
pub fn decode_blurhash(blur_hash: &str, width: u32, height: u32) -> Result<Vec<u8>, JellyfinError> {
    blurhash::decode_blurhash_to_rgba(blur_hash, width, height)
}
