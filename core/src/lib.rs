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

#[cfg(not(any(feature = "aws-lc-tls", feature = "ring-tls")))]
compile_error!("playfin_core requires a TLS backend: enable `aws-lc-tls` (default) or `ring-tls`");

#[cfg(feature = "bundled-roots")]
pub(crate) fn bundled_root_certs() -> &'static [reqwest::Certificate] {
    static BUNDLED_CERTS: std::sync::OnceLock<Vec<reqwest::Certificate>> =
        std::sync::OnceLock::new();
    BUNDLED_CERTS.get_or_init(|| {
        let mut certs = Vec::with_capacity(webpki_root_certs::TLS_SERVER_ROOT_CERTS.len());
        let mut dropped = 0usize;
        for der in webpki_root_certs::TLS_SERVER_ROOT_CERTS {
            match reqwest::Certificate::from_der(der.as_ref()) {
                Ok(cert) => certs.push(cert),
                Err(_) => dropped += 1,
            }
        }
        if dropped > 0 {
            log::warn!("dropped {dropped} unparseable bundled root certificate(s)");
        }
        certs
    })
}

/// Creates a `reqwest::ClientBuilder` configured with the active TLS provider and root store.
pub(crate) fn http_client_builder() -> reqwest::ClientBuilder {
    #[cfg(all(feature = "ring-tls", not(feature = "aws-lc-tls")))]
    {
        static RING_INIT: std::sync::Once = std::sync::Once::new();
        RING_INIT.call_once(|| {
            let _ = rustls::crypto::ring::default_provider().install_default();
        });
    }

    let builder = reqwest::Client::builder();

    #[cfg(feature = "bundled-roots")]
    {
        let certs = bundled_root_certs();
        builder.tls_certs_only(certs.iter().cloned())
    }
    #[cfg(not(feature = "bundled-roots"))]
    {
        builder
    }
}

/// Current version of the Rust core.
#[uniffi::export]
pub fn core_version() -> String {
    VERSION.to_string()
}

/// Performs a lightweight HTTPS GET using the configured TLS backend and root store.
#[doc(hidden)]
#[cfg(feature = "bundled-roots")]
pub async fn probe_https_status(url: &str) -> Result<u16, JellyfinError> {
    let client = http_client_builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| JellyfinError::Network(e.to_string()))?;
    let response = client.get(url).send().await?;
    Ok(response.status().as_u16())
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
