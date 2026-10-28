use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::net::UdpSocket;
use std::time::{Duration, Instant};

use crate::JellyfinError;

/// Jellyfin server discovered on the local network via UDP broadcast.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct DiscoveredServer {
    pub address: String,
    pub id: String,
    pub name: String,
}

/// Sends a UDP discovery request on port 7359 and collects the servers that answer.
pub async fn discover_local_servers(
    timeout_duration: Duration,
) -> Result<Vec<DiscoveredServer>, JellyfinError> {
    let run_discovery = move || -> Result<Vec<DiscoveredServer>, JellyfinError> {
        let socket = UdpSocket::bind("0.0.0.0:0")
            .map_err(|e| JellyfinError::Network(format!("UDP socket error: {e}")))?;

        socket
            .set_broadcast(true)
            .map_err(|e| JellyfinError::Network(format!("Could not enable UDP broadcast: {e}")))?;

        let read_timeout = Duration::from_millis(50).min(timeout_duration);
        socket
            .set_read_timeout(Some(read_timeout))
            .map_err(|e| JellyfinError::Network(format!("UDP timeout configuration error: {e}")))?;

        let message = b"who is JellyfinServer?";
        let broadcast_addr = "255.255.255.255:7359";
        let _ = socket.send_to(message, broadcast_addr);

        let mut discovered: Vec<DiscoveredServer> = Vec::new();
        let mut seen_ids: HashSet<String> = HashSet::new();

        let start = Instant::now();
        let mut buf = [0u8; 2048];

        while start.elapsed() < timeout_duration {
            match socket.recv_from(&mut buf) {
                Ok((len, _peer)) => {
                    #[allow(clippy::collapsible_if)]
                    if let Ok(server) = serde_json::from_slice::<DiscoveredServer>(&buf[..len]) {
                        if seen_ids.insert(server.id.clone()) {
                            discovered.push(server);
                        }
                    }
                }
                Err(ref e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut =>
                {
                    // Read timeout elapsed, continue until timeout_duration
                }
                Err(_) => break,
            }
        }

        Ok(discovered)
    };

    if tokio::runtime::Handle::try_current().is_ok() {
        tokio::task::spawn_blocking(run_discovery)
            .await
            .map_err(|e| JellyfinError::Network(format!("Discovery task interrupted: {e}")))?
    } else {
        let (tx, rx) = tokio::sync::oneshot::channel();
        std::thread::spawn(move || {
            let _ = tx.send(run_discovery());
        });
        rx.await
            .map_err(|e| JellyfinError::Network(format!("Discovery task interrupted: {e}")))?
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_discover_local_servers_timeout_graceful() {
        // With no active server on the UDP port in the test environment,
        // the function must end cleanly after the allotted time with an empty list.
        let result = discover_local_servers(Duration::from_millis(50)).await;
        assert!(result.is_ok());
    }

    #[test]
    fn test_parse_discovered_server_json() {
        let json = r#"{"Address":"http://192.168.1.150:8096","Id":"abc123456","Name":"MyServer"}"#;
        let server: DiscoveredServer = serde_json::from_str(json).unwrap();
        assert_eq!(server.address, "http://192.168.1.150:8096");
        assert_eq!(server.id, "abc123456");
        assert_eq!(server.name, "MyServer");
    }
}
