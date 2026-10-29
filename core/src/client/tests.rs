use super::*;

fn client(server_id: &str, user_id: &str) -> (JellyfinClient, PathBuf) {
    // One unique folder per call: the tests run in parallel and one of them deletes its folder at the end.
    let dir = std::env::temp_dir().join(format!(
        "playfin-test-{}-{server_id}-{user_id}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let info = SessionInfo {
        server_url: "http://localhost:8096".into(),
        server_id: server_id.into(),
        user_id: user_id.into(),
        access_token: "token".into(),
    };
    (JellyfinClient::restore(info, dir.to_str().unwrap()), dir)
}

fn movie() -> Movie {
    serde_json::from_str(
        r#"{"Id":"abc","Name":"Zoë","ProductionYear":2001,"Genres":["Comedy"],
            "UserData":{"PlaybackPositionTicks":6000000000,"Played":false,"PlayedPercentage":12.5}}"#,
    )
    .unwrap()
}

#[test]
fn image_tags_parse_from_jellyfin_and_survive_the_disk_cache() {
    let m: Movie = serde_json::from_str(
        r#"{"Id":"e1","Name":"Ep","ImageTags":{"Primary":"aaa","Logo":"bbb"},
            "BackdropImageTags":["ccc"],"SeriesPrimaryImageTag":"ddd","ParentBackdropImageTags":["eee"]}"#,
    )
    .unwrap();
    assert_eq!(m.image_tags.len(), 2);
    assert_eq!(m.backdrop_image_tags, vec!["ccc"]);
    assert_eq!(m.series_primary_image_tag.as_deref(), Some("ddd"));
    assert_eq!(m.parent_backdrop_image_tags, vec!["eee"]);

    let back: Movie = serde_json::from_str(&serde_json::to_string(&m).unwrap()).unwrap();
    assert_eq!(back.image_tags.len(), 2);
    assert!(
        back.image_tags
            .iter()
            .any(|t| t.kind == "Logo" && t.tag == "bbb")
    );

    // Old cache or item without an image: no required field.
    assert!(movie().image_tags.is_empty());
}

#[test]
fn backdrop_blur_hash_is_copied_from_image_blur_hashes() {
    let mut value: serde_json::Value = serde_json::from_str(
        r#"{"Items":[{"Id":"a","Name":"A","ImageBlurHashes":{"Primary":{"t1":"PRIM"},"Backdrop":{"t2":"BACK"}}},
                     {"Id":"b","Name":"B"}],"TotalRecordCount":2}"#,
    )
    .unwrap();
    copy_backdrop_blur_hashes(&mut value);
    let a: Movie = serde_json::from_value(value["Items"][0].clone()).unwrap();
    let b: Movie = serde_json::from_value(value["Items"][1].clone()).unwrap();
    assert_eq!(a.backdrop_blur_hash.as_deref(), Some("BACK"));
    assert_eq!(a.primary_blur_hash.as_deref(), Some("PRIM"));
    assert_eq!(b.backdrop_blur_hash, None);
}

#[test]
fn image_url_includes_a_sanitized_tag() {
    let (client, dir) = client("srv1", "user1");
    let plain = client.image_url("abc", ImageKind::Primary, 450, None);
    assert!(!plain.contains("tag="));
    let tagged = client.image_url("abc", ImageKind::Primary, 450, Some("a1b2&x=y".into()));
    assert!(tagged.ends_with("&tag=a1b2xy"));
    assert!(
        !client
            .image_url("abc", ImageKind::Logo, 100, Some(String::new()))
            .contains("tag=")
    );
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn cache_round_trip() {
    let (client, dir) = client("srv1", "user1");
    assert!(client.cache_read::<Vec<Movie>>("movies").is_none());

    client.cache_write("movies", &vec![movie()]);
    let back: Vec<Movie> = client.cache_read("movies").unwrap();
    assert_eq!(back.len(), 1);
    assert_eq!(back[0].name, "Zoë");
    assert_eq!(
        back[0].user_data.as_ref().unwrap().playback_position_ticks,
        6_000_000_000
    );

    client.clear_cache();
    assert!(client.cache_read::<Vec<Movie>>("movies").is_none());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn cache_isolation_by_server_and_user() {
    let base_dir = std::env::temp_dir().join(format!("playfin-isolation-{}", std::process::id()));
    let base_str = base_dir.to_str().unwrap();

    // Server A, User 1
    let client_a1 = JellyfinClient::restore(
        SessionInfo {
            server_url: "http://srv-a:8096".into(),
            server_id: "server-a".into(),
            user_id: "user-1".into(),
            access_token: "tok-a1".into(),
        },
        base_str,
    );

    // Server B, User 1 (same user ID on different server)
    let client_b1 = JellyfinClient::restore(
        SessionInfo {
            server_url: "http://srv-b:8096".into(),
            server_id: "server-b".into(),
            user_id: "user-1".into(),
            access_token: "tok-b1".into(),
        },
        base_str,
    );

    // Server A, User 2 (different user on same server)
    let client_a2 = JellyfinClient::restore(
        SessionInfo {
            server_url: "http://srv-a:8096".into(),
            server_id: "server-a".into(),
            user_id: "user-2".into(),
            access_token: "tok-a2".into(),
        },
        base_str,
    );

    // Write movie to Server A, User 1
    client_a1.cache_write("movies", &vec![movie()]);

    // Verify Server A User 1 can read it
    assert_eq!(
        client_a1.cache_read::<Vec<Movie>>("movies").unwrap().len(),
        1
    );

    // Verify Server B User 1 cannot see it (isolated by server_id)
    assert!(client_b1.cache_read::<Vec<Movie>>("movies").is_none());

    // Verify Server A User 2 cannot see it (isolated by user_id)
    assert!(client_a2.cache_read::<Vec<Movie>>("movies").is_none());

    // Clearing Server A User 1 cache does not affect other paths
    client_a1.clear_cache();
    assert!(client_a1.cache_read::<Vec<Movie>>("movies").is_none());

    let _ = std::fs::remove_dir_all(base_dir);
}

#[test]
fn corrupt_cache_is_ignored() {
    let (client, dir) = client("srv2", "user2");
    client.cache_write("home", &Home::default());
    std::fs::write(dir.join("srv2").join("user2").join("home.json"), "not json").unwrap();
    assert!(client.cache_read::<Home>("home").is_none());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn path_traversal_is_prevented() {
    let (client, dir) = client("../../evil_srv", "../../evil_user");
    let expected = dir.join("evil_srv").join("evil_user");
    assert_eq!(client.profile_cache_dir().unwrap(), expected);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn items_or_list_deserializes_both_formats() {
    let object_json = r#"{"Items":[{"Id":"m1","Name":"Film 1"}]}"#;
    let list_json = r#"[{"Id":"m2","Name":"Film 2"}]"#;

    let obj: ItemsOrList = serde_json::from_str(object_json).unwrap();
    let list: ItemsOrList = serde_json::from_str(list_json).unwrap();

    let v1 = obj.into_vec();
    assert_eq!(v1.len(), 1);
    assert_eq!(v1[0].name, "Film 1");

    let v2 = list.into_vec();
    assert_eq!(v2.len(), 1);
    assert_eq!(v2[0].name, "Film 2");
}

#[tokio::test]
async fn test_home_unreachable_server_preserves_cache() {
    let dir = std::env::temp_dir().join(format!("playfin-home-unreachable-{}", std::process::id()));
    let dir_str = dir.to_str().unwrap();

    // Client configured towards an unreachable port
    let client = JellyfinClient::restore(
        SessionInfo {
            server_url: "http://127.0.0.1:54321".into(),
            server_id: "test-srv".into(),
            user_id: "test-usr".into(),
            access_token: "test-token".into(),
        },
        dir_str,
    );

    // Valid home data pre-saved in the cache
    let initial_home = Home {
        resume: vec![movie()],
        next_up: vec![],
        latest: vec![movie()],
    };
    client.cache_write("home", &initial_home);

    let cached_before = client.cached_home().await;
    assert_eq!(cached_before.resume.len(), 1);

    // home() must fail with ServerUnreachable or Network, and NOT return Ok(empty)
    let result = client.home().await;
    assert!(
        result.is_err(),
        "home() must fail when the server is unreachable"
    );
    match result.unwrap_err() {
        JellyfinError::ServerUnreachable(_) | JellyfinError::Network(_) => {}
        other => panic!("Expected ServerUnreachable or Network, got {:?}", other),
    }

    // The cache on disk MUST NOT have been overwritten
    let cached_after = client.cached_home().await;
    assert_eq!(
        cached_after.resume.len(),
        1,
        "The valid cache must not be overwritten on a network failure"
    );
    assert_eq!(cached_after.resume[0].name, "Zoë");

    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn test_quick_connect_state_deserialization() {
    let json_init = r#"{"Code":"849201","Secret":"sec-abc-123","Authenticated":false}"#;
    let state_init: QuickConnectState = serde_json::from_str(json_init).unwrap();
    assert_eq!(state_init.code, "849201");
    assert_eq!(state_init.secret, "sec-abc-123");
    assert!(!state_init.authenticated);

    let json_auth = r#"{"Code":"849201","Secret":"sec-abc-123","Authenticated":true}"#;
    let state_auth: QuickConnectState = serde_json::from_str(json_auth).unwrap();
    assert!(state_auth.authenticated);
}

#[test]
fn test_core_version() {
    assert_eq!(core_version(), env!("CARGO_PKG_VERSION"));
}

#[test]
fn test_decode_blurhash_export() {
    let hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj";
    let rgba = decode_blurhash(hash, 20, 20).expect("Should decode successfully");
    assert_eq!(rgba.len(), 20 * 20 * 4);
    for (i, &b) in rgba.iter().enumerate() {
        if i % 4 == 3 {
            assert_eq!(b, 255);
        }
    }

    let invalid = decode_blurhash("invalid", 20, 20);
    assert!(matches!(invalid, Err(JellyfinError::Decode(_))));
}

#[test]
fn test_movie_deserialization_with_image_blur_hashes_tagged() {
    let json = r#"{
        "Id": "mov-1",
        "Name": "Inception",
        "PrimaryImageAspectRatio": 1.7777777777777777,
        "ImageBlurHashes": {
            "Primary": {
                "tag1": "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
            },
            "Backdrop": {
                "tag2": "LGF5?xYk^6#M@-5c2xXT8^ofIzqe"
            }
        }
    }"#;

    let movie: Movie = serde_json::from_str(json).unwrap();
    assert_eq!(movie.id, "mov-1");
    assert_eq!(movie.name, "Inception");
    assert_eq!(
        movie.primary_blur_hash.as_deref(),
        Some("LEHV6nWB2yk8pyo0adR*.7kCMdnj")
    );
    assert_eq!(movie.primary_image_aspect_ratio, Some(1.7777777777777777));
}

#[test]
fn test_movie_deserialization_with_image_blur_hashes_untagged_string() {
    let json = r#"{
        "Id": "mov-2",
        "Name": "The Matrix",
        "PrimaryImageAspectRatio": 1.5,
        "ImageBlurHashes": {
            "Primary": "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        }
    }"#;

    let movie: Movie = serde_json::from_str(json).unwrap();
    assert_eq!(movie.id, "mov-2");
    assert_eq!(
        movie.primary_blur_hash.as_deref(),
        Some("LEHV6nWB2yk8pyo0adR*.7kCMdnj")
    );
    assert_eq!(movie.primary_image_aspect_ratio, Some(1.5));
}

#[test]
fn test_movie_deserialization_from_cache_and_roundtrip() {
    let json = r#"{
        "Id": "mov-3",
        "Name": "Interstellar",
        "PrimaryBlurHash": "LEHV6nWB2yk8pyo0adR*.7kCMdnj",
        "PrimaryImageAspectRatio": 1.78
    }"#;

    let movie: Movie = serde_json::from_str(json).unwrap();
    assert_eq!(
        movie.primary_blur_hash.as_deref(),
        Some("LEHV6nWB2yk8pyo0adR*.7kCMdnj")
    );
    assert_eq!(movie.primary_image_aspect_ratio, Some(1.78));

    let serialized = serde_json::to_string(&movie).unwrap();
    let back: Movie = serde_json::from_str(&serialized).unwrap();
    assert_eq!(back.primary_blur_hash, movie.primary_blur_hash);
    assert_eq!(
        back.primary_image_aspect_ratio,
        movie.primary_image_aspect_ratio
    );
}

#[test]
fn test_movie_deserialization_without_primary_blur_hash() {
    let json1 = r#"{"Id":"m1","Name":"Film 1"}"#;
    let m1: Movie = serde_json::from_str(json1).unwrap();
    assert_eq!(m1.primary_blur_hash, None);
    assert_eq!(m1.primary_image_aspect_ratio, None);

    let json2 = r#"{
        "Id": "m2",
        "Name": "Film 2",
        "ImageBlurHashes": {
            "Backdrop": { "tag": "LGF5?xYk^6#M@-5c2xXT8^ofIzqe" }
        }
    }"#;
    let m2: Movie = serde_json::from_str(json2).unwrap();
    assert_eq!(m2.primary_blur_hash, None);

    let json3 = r#"{
        "Id": "m3",
        "Name": "Film 3",
        "ImageBlurHashes": {
            "Primary": {}
        }
    }"#;
    let m3: Movie = serde_json::from_str(json3).unwrap();
    assert_eq!(m3.primary_blur_hash, None);
}

#[tokio::test]
async fn test_on_network_changed_empty_addresses() {
    let temp = std::env::temp_dir().join(format!("test_client_{}", std::process::id()));
    let client = JellyfinClient::new("http://localhost:8096", temp.to_str().unwrap());
    let res = client.on_network_changed(vec![], "server-123").await;
    match res {
        Err(JellyfinError::InvalidInput(_)) => {}
        other => panic!("Expected InvalidInput on empty addresses, got {:?}", other),
    }
    let _ = std::fs::remove_dir_all(temp);
}

#[tokio::test]
async fn test_on_network_changed_unreachable_server_returns_err() {
    let temp = std::env::temp_dir().join(format!("test_client_err_{}", std::process::id()));
    let client = JellyfinClient::new("http://localhost:8096", temp.to_str().unwrap());
    let addrs = vec![ServerAddress::new("http://127.0.0.1:1", "Dead", 1)];
    let res = client.on_network_changed(addrs, "server-123").await;
    match res {
        Err(JellyfinError::ServerUnreachable(_)) => {}
        other => panic!("Expected ServerUnreachable on dead host, got {:?}", other),
    }
    let _ = std::fs::remove_dir_all(temp);
}

#[tokio::test]
async fn test_on_network_changed_success_and_mismatch() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let port = addr.port();

    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut buf = [0u8; 1024];
                let _ = socket.read(&mut buf).await;
                let body = r#"{"Id":"srv-target-1","ServerName":"Mock Server","Version":"10.9.7"}"#;
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = socket.write_all(resp.as_bytes()).await;
            });
        }
    });

    let temp = std::env::temp_dir().join(format!("test_client_mock_{}", std::process::id()));
    let client = JellyfinClient::new("http://localhost:8096", temp.to_str().unwrap());
    let mock_url = format!("http://127.0.0.1:{port}");
    let addrs = vec![ServerAddress::new(&mock_url, "Mock", 1)];

    // Success when expected_server_id matches
    let res = client
        .on_network_changed(addrs.clone(), "srv-target-1")
        .await
        .unwrap();
    assert!(res.is_some());
    assert_eq!(res.unwrap().url, mock_url);

    // Mismatch when expected_server_id does not match returns ServerMismatch
    let err = client.on_network_changed(addrs, "different-id").await;
    match err {
        Err(JellyfinError::ServerMismatch(msg)) => {
            assert!(msg.contains("different-id"));
        }
        other => panic!("Expected ServerMismatch on ID mismatch, got {:?}", other),
    }

    let _ = std::fs::remove_dir_all(temp);
}

/// Fake server: authentication succeeds without `ServerId`; `/System/Info/Public` answers
/// with `public_status` (200 = identifier `srv-probed`).
async fn spawn_auth_server(public_status: u16) -> u16 {
    spawn_auth_server_logging(public_status, std::sync::Arc::new(Mutex::new(Vec::new()))).await
}

async fn spawn_auth_server_logging(
    public_status: u16,
    log: std::sync::Arc<Mutex<Vec<String>>>,
) -> u16 {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let log = log.clone();
            tokio::spawn(async move {
                let mut buf = [0u8; 2048];
                let n = socket.read(&mut buf).await.unwrap_or(0);
                let request = String::from_utf8_lossy(&buf[..n]).to_string();
                log.lock()
                    .unwrap()
                    .push(request.lines().next().unwrap_or("").to_string());
                let (status, body) = if request.contains("/Users/AuthenticateByName") {
                    (
                        200,
                        r#"{"AccessToken":"tok","User":{"Id":"user-1","Name":"Ana"}}"#,
                    )
                } else if public_status == 200 {
                    (
                        200,
                        r#"{"Id":"srv-probed","ServerName":"Mock","Version":"10.9.7"}"#,
                    )
                } else {
                    (public_status, "{}")
                };
                let resp = format!(
                    "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = socket.write_all(resp.as_bytes()).await;
            });
        }
    });
    port
}

#[tokio::test]
async fn test_login_without_server_id_uses_probed_id() {
    let port = spawn_auth_server(200).await;
    let temp = std::env::temp_dir().join(format!("test_login_probe_{}", std::process::id()));
    let client = JellyfinClient::new(&format!("http://127.0.0.1:{port}"), temp.to_str().unwrap());
    client.login("ana", "pw").await.unwrap();
    assert_eq!(client.server_id().as_deref(), Some("srv-probed"));
    let _ = std::fs::remove_dir_all(temp);
}

#[tokio::test]
async fn test_login_without_server_id_fails_when_probe_fails() {
    let log = std::sync::Arc::new(Mutex::new(Vec::new()));
    let port = spawn_auth_server_logging(500, log.clone()).await;
    let temp = std::env::temp_dir().join(format!("test_login_noprobe_{}", std::process::id()));
    let client = JellyfinClient::new(&format!("http://127.0.0.1:{port}"), temp.to_str().unwrap());
    // No "default" session: sign-in fails rather than bypassing the check.
    assert!(client.login("ana", "pw").await.is_err());
    assert_eq!(client.server_id(), None);
    // The token created by the server is revoked as best we can.
    assert!(
        log.lock()
            .unwrap()
            .iter()
            .any(|l| l.starts_with("POST /Sessions/Logout"))
    );
    let _ = std::fs::remove_dir_all(temp);
}

fn fresh_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("{name}_{}", uuid::Uuid::new_v4()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn sample_session() -> SessionInfo {
    SessionInfo {
        server_url: "http://127.0.0.1:1".into(),
        server_id: "srv".into(),
        user_id: "user".into(),
        access_token: "tok".into(),
    }
}

#[test]
fn test_new_installation_gets_unique_persisted_device_id() {
    let dir_a = fresh_dir("dev_a");
    let dir_b = fresh_dir("dev_b");
    let a1 = JellyfinClient::new("http://127.0.0.1:1", dir_a.to_str().unwrap());
    let a2 = JellyfinClient::new("http://127.0.0.1:1", dir_a.to_str().unwrap());
    let b = JellyfinClient::new("http://127.0.0.1:1", dir_b.to_str().unwrap());

    assert_ne!(a1.device_id, LEGACY_DEVICE_ID);
    assert_eq!(
        a1.device_id, a2.device_id,
        "the identifier must survive a restart"
    );
    assert_ne!(
        a1.device_id, b.device_id,
        "two installations do not share an identifier"
    );
    assert!(
        a1.auth_header()
            .contains(&format!(r#"DeviceId="{}""#, a1.device_id))
    );
    let _ = std::fs::remove_dir_all(dir_a);
    let _ = std::fs::remove_dir_all(dir_b);
}

#[test]
fn test_legacy_session_keeps_legacy_device_id_until_relogin() {
    let dir = fresh_dir("dev_legacy");
    // No recent installation: an already saved session keeps the old identifier.
    let restored = JellyfinClient::restore(sample_session(), dir.to_str().unwrap());
    assert_eq!(restored.device_id, LEGACY_DEVICE_ID);
    assert!(
        !dir.join(DEVICE_ID_FILE).exists(),
        "restore does not create a new identifier"
    );

    // After a new sign-in (client created by `new`), the own identifier is used.
    let fresh = JellyfinClient::new("http://127.0.0.1:1", dir.to_str().unwrap());
    let restored_again = JellyfinClient::restore(sample_session(), dir.to_str().unwrap());
    assert_eq!(restored_again.device_id, fresh.device_id);
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn test_library_cache_is_a_separate_sqlite_file_per_profile() {
    let dir = fresh_dir("lib_sqlite");
    let a = JellyfinClient::restore(sample_session(), dir.to_str().unwrap());
    let mut other = sample_session();
    other.user_id = "other-user".into();
    let b = JellyfinClient::restore(other, dir.to_str().unwrap());

    a.store_library_items("lib".into(), vec![movie()]).await;
    assert_eq!(a.cached_library_items("lib".into()).await.len(), 1);
    assert!(b.cached_library_items("lib".into()).await.is_empty());
    let db_a = a.user_cache_dir().unwrap().join("profile.sqlite");
    let db_b = b.user_cache_dir().unwrap().join("profile.sqlite");
    assert!(db_a.exists());
    assert_ne!(db_a, db_b);
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn test_library_cache_keeps_the_whole_list() {
    let dir = fresh_dir("lib_cache");
    let client = JellyfinClient::restore(sample_session(), dir.to_str().unwrap());
    let items: Vec<Movie> = (0..250)
        .map(|i| serde_json::from_str(&format!(r#"{{"Id":"id-{i}","Name":"Film {i}"}}"#)).unwrap())
        .collect();

    assert!(client.cached_library_items("lib".into()).await.is_empty());
    client.store_library_items("lib".into(), items).await;

    let cached = client.cached_library_items("lib".into()).await;
    assert_eq!(
        cached.len(),
        250,
        "the whole library, not just the first page"
    );
    assert_eq!(cached[249].id, "id-249");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn test_audio_and_video_stream_urls() {
    let dir = fresh_dir("stream_urls");
    let client = JellyfinClient::new("http://127.0.0.1:8096/", dir.to_str().unwrap());
    assert_eq!(
        client.stream_url("abc"),
        "http://127.0.0.1:8096/Videos/abc/stream?static=true"
    );
    assert_eq!(
        client.audio_stream_url("abc"),
        "http://127.0.0.1:8096/Audio/abc/stream?static=true"
    );
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn test_discovery_timeout_has_a_minimum() {
    assert_eq!(effective_discovery_timeout(0), Duration::from_millis(250));
    assert_eq!(
        effective_discovery_timeout(1500),
        Duration::from_millis(1500)
    );
}

#[test]
fn test_user_views_deserialization() {
    let json = r#"{
        "Items": [
            {
                "Id": "lib-1",
                "Name": "Films",
                "CollectionType": "movies",
                "ImageBlurHashes": {
                    "Primary": { "tag1": "LEHV6nWB2yk8pyo0adR*.7kCMdnj" }
                }
            },
            {
                "Id": "lib-2",
                "Name": "TV Shows",
                "CollectionType": "tvshows"
            }
        ],
        "TotalRecordCount": 2
    }"#;

    let response: ItemsResponse<UserView> = serde_json::from_str(json).unwrap();
    assert_eq!(response.total_record_count, Some(2));
    assert_eq!(response.items.len(), 2);
    assert_eq!(response.items[0].id, "lib-1");
    assert_eq!(response.items[0].name, "Films");
    assert_eq!(response.items[0].collection_type.as_deref(), Some("movies"));
    assert_eq!(
        response.items[0].primary_blur_hash.as_deref(),
        Some("LEHV6nWB2yk8pyo0adR*.7kCMdnj")
    );
    assert_eq!(response.items[1].id, "lib-2");
    assert_eq!(response.items[1].name, "TV Shows");
    assert_eq!(
        response.items[1].collection_type.as_deref(),
        Some("tvshows")
    );
    assert_eq!(response.items[1].primary_blur_hash, None);
}

#[test]
fn test_library_page_deserialization() {
    let json = r#"{
        "Items": [
            {
                "Id": "mov-1",
                "Name": "Inception",
                "Type": "Movie",
                "ProductionYear": 2010
            }
        ],
        "TotalRecordCount": 1482
    }"#;

    let response: ItemsResponse<Movie> = serde_json::from_str(json).unwrap();
    assert_eq!(response.total_record_count, Some(1482));
    assert_eq!(response.items.len(), 1);
    assert_eq!(response.items[0].name, "Inception");

    let page = LibraryPage {
        items: response.items,
        total_record_count: response.total_record_count.unwrap(),
        start_index: 0,
    };
    assert_eq!(page.total_record_count, 1482);
    assert_eq!(page.start_index, 0);
    assert_eq!(page.items.len(), 1);
}

#[test]
fn favorite_flag_parses_and_defaults_to_false() {
    let fav: Movie = serde_json::from_str(
        r#"{"Id":"f1","Name":"Fav","UserData":{"Played":false,"IsFavorite":true}}"#,
    )
    .unwrap();
    assert!(fav.user_data.unwrap().is_favorite);
    // Old cache, written before the favourites: no required field.
    assert!(!movie().user_data.unwrap().is_favorite);
}
