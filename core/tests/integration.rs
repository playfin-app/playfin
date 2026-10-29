//! Integration tests of the core against a fake Jellyfin server (wiremock).
//! The responses come from `tests/fixtures/`: synthetic data only.

use playfin_core::{JellyfinClient, JellyfinError, ServerAddress, validate_server};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

const PUBLIC_INFO: &str = include_str!("fixtures/public_info.json");
const AUTH: &str = include_str!("fixtures/auth.json");
const RESUME: &str = include_str!("fixtures/items_resume.json");
const NEXT_UP: &str = include_str!("fixtures/items_next_up.json");
const LATEST: &str = include_str!("fixtures/items_latest.json");

fn json(body: &str) -> ResponseTemplate {
    ResponseTemplate::new(200).set_body_raw(body.to_string(), "application/json")
}

fn temp_dir(name: &str) -> String {
    let dir = std::env::temp_dir().join(format!("jn_it_{name}_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir.to_string_lossy().into_owned()
}

async fn server_with_public_info(body: &str) -> MockServer {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(json(body))
        .mount(&server)
        .await;
    server
}

async fn logged_in_client(server: &MockServer, name: &str) -> JellyfinClient {
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(json(AUTH))
        .mount(server)
        .await;
    let client = JellyfinClient::new(&server.uri(), &temp_dir(name));
    client.login("ana", "pw").await.expect("login");
    client
}

// ── Connexion ──────────────────────────────────────────────

#[tokio::test]
async fn login_success_keeps_session_and_server_id() {
    let server = MockServer::start().await;
    let client = logged_in_client(&server, "login_ok").await;

    let session = client.session_info().expect("session");
    assert_eq!(session.user_id, "user-fixture-1");
    assert_eq!(session.access_token, "fixture-token");
    assert_eq!(session.server_id, "srv-fixture-1");
}

#[tokio::test]
async fn login_with_wrong_password_is_unauthorized() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(401))
        .mount(&server)
        .await;

    let client = JellyfinClient::new(&server.uri(), &temp_dir("login_401"));
    let err = client.login("ana", "wrong").await.unwrap_err();
    assert!(matches!(err, JellyfinError::Unauthorized), "{err:?}");
    assert!(client.session_info().is_none());
}

#[tokio::test]
async fn login_on_server_error_reports_status_code() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(503))
        .mount(&server)
        .await;

    let client = JellyfinClient::new(&server.uri(), &temp_dir("login_503"));
    let err = client.login("ana", "pw").await.unwrap_err();
    assert!(
        matches!(err, JellyfinError::ServerError { code: 503, .. }),
        "{err:?}"
    );
}

// ── Address choice and server identity check ─────────

#[tokio::test]
async fn address_selection_picks_the_server_with_the_expected_id() {
    let right = server_with_public_info(PUBLIC_INFO).await;
    let other = server_with_public_info(
        r#"{"Id":"srv-someone-else","ServerName":"Other","Version":"10.9.7"}"#,
    )
    .await;
    let client = JellyfinClient::new(&other.uri(), &temp_dir("addr_ok"));

    let best = client
        .auto_select_address(
            vec![
                ServerAddress::new(&other.uri(), "Other", 1),
                ServerAddress::new(&right.uri(), "Good server", 2),
            ],
            "srv-fixture-1",
        )
        .await
        .expect("an address matches");

    assert_eq!(best.url, right.uri());
    assert_eq!(
        client.server_url(),
        right.uri(),
        "the client switches to the right address"
    );
}

async fn server_with_slow_public_info(delay_ms: u64) -> MockServer {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(json(PUBLIC_INFO).set_delay(std::time::Duration::from_millis(delay_ms)))
        .mount(&server)
        .await;
    server
}

#[tokio::test]
async fn address_selection_does_not_wait_for_a_slower_address_of_lower_priority() {
    let first = server_with_public_info(PUBLIC_INFO).await;
    let slow = server_with_slow_public_info(5_000).await;
    let client = JellyfinClient::new(&first.uri(), &temp_dir("addr_early"));

    let started = std::time::Instant::now();
    let best = client
        .auto_select_address(
            vec![
                ServerAddress::new(&first.uri(), "Home", 1),
                ServerAddress::new(&slow.uri(), "Remote", 2),
            ],
            "srv-fixture-1",
        )
        .await
        .expect("the first address answers");

    assert_eq!(best.url, first.uri());
    assert!(
        started.elapsed() < std::time::Duration::from_millis(1_000),
        "returned without waiting for the slow address: {:?}",
        started.elapsed()
    );
}

#[tokio::test]
async fn address_selection_still_waits_for_a_slower_address_of_higher_priority() {
    let slow_first = server_with_slow_public_info(400).await;
    let fast = server_with_public_info(PUBLIC_INFO).await;
    let client = JellyfinClient::new(&fast.uri(), &temp_dir("addr_wait"));

    let best = client
        .auto_select_address(
            vec![
                ServerAddress::new(&slow_first.uri(), "Home", 1),
                ServerAddress::new(&fast.uri(), "Remote", 2),
            ],
            "srv-fixture-1",
        )
        .await
        .expect("both addresses answer");

    assert_eq!(best.url, slow_first.uri(), "the priority still wins");
}

#[tokio::test]
async fn address_selection_retries_an_address_that_refuses_the_first_connection() {
    // At launch, macOS refuses the app's first LAN connection at once, then lets the next ones through.
    // Here: nothing listens on the home port at first (immediate refusal), the server starts 300 ms later.
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let home = format!("http://127.0.0.1:{port}");
    let server = tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let listener = std::net::TcpListener::bind(("127.0.0.1", port)).unwrap();
        let server = MockServer::builder().listener(listener).start().await;
        Mock::given(method("GET"))
            .and(path("/System/Info/Public"))
            .respond_with(json(PUBLIC_INFO))
            .mount(&server)
            .await;
        server
    });
    let client = JellyfinClient::new(&home, &temp_dir("addr_retry"));

    let best = client
        .auto_select_address(vec![ServerAddress::new(&home, "Home", 1)], "srv-fixture-1")
        .await
        .expect("the home address answers on a later attempt");

    assert_eq!(best.url, home);
    drop(server.await.unwrap());
}

#[tokio::test]
async fn address_selection_refuses_a_server_with_another_id() {
    let other = server_with_public_info(
        r#"{"Id":"srv-someone-else","ServerName":"Other","Version":"10.9.7"}"#,
    )
    .await;
    let client = JellyfinClient::new(&other.uri(), &temp_dir("addr_mismatch"));

    let err = client
        .auto_select_address(
            vec![ServerAddress::new(&other.uri(), "Other", 1)],
            "srv-fixture-1",
        )
        .await
        .unwrap_err();
    assert!(matches!(err, JellyfinError::ServerMismatch(_)), "{err:?}");
}

#[tokio::test]
async fn servers_older_than_10_9_are_refused() {
    let old = server_with_public_info(
        r#"{"Id":"srv-fixture-1","ServerName":"Vieux","Version":"10.8.13"}"#,
    )
    .await;

    // At validation, the error says why.
    let err = validate_server(&old.uri()).await.unwrap_err();
    assert!(
        matches!(err, JellyfinError::UnsupportedServerVersion(_)),
        "{err:?}"
    );

    // At address choice, an unsupported server is never retained.
    let client = JellyfinClient::new(&old.uri(), &temp_dir("addr_old"));
    let result = client
        .auto_select_address(
            vec![ServerAddress::new(&old.uri(), "Vieux", 1)],
            "srv-fixture-1",
        )
        .await;
    assert!(result.is_err());
}

// ── Home ────────────────────────────────────────────────

async fn mount_home(server: &MockServer) {
    Mock::given(method("GET"))
        .and(path("/UserItems/Resume"))
        .respond_with(json(RESUME))
        .mount(server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Shows/NextUp"))
        .respond_with(json(NEXT_UP))
        .mount(server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items/Latest"))
        .respond_with(json(LATEST))
        .mount(server)
        .await;
}

#[tokio::test]
async fn home_returns_the_three_rows() {
    let server = MockServer::start().await;
    let client = logged_in_client(&server, "home_ok").await;
    mount_home(&server).await;

    let home = client.home().await.expect("home");
    assert_eq!(home.resume.len(), 1);
    assert_eq!(home.resume[0].id, "item-resume-1");
    assert_eq!(home.next_up.len(), 2);
    assert_eq!(home.latest.len(), 3);
}

#[tokio::test]
async fn home_with_expired_token_is_unauthorized() {
    let server = MockServer::start().await;
    let client = logged_in_client(&server, "home_401").await;
    Mock::given(method("GET"))
        .respond_with(ResponseTemplate::new(401))
        .mount(&server)
        .await;

    let err = client.home().await.unwrap_err();
    assert!(matches!(err, JellyfinError::Unauthorized), "{err:?}");
}

#[tokio::test]
async fn home_keeps_the_cache_when_the_server_goes_away() {
    let server = MockServer::start().await;
    let client = logged_in_client(&server, "home_cache").await;
    mount_home(&server).await;
    client.home().await.expect("first load");

    // The server disappears: the saved home stays readable offline.
    drop(server);
    let cached = client.cached_home().await;
    assert_eq!(cached.latest.len(), 3);
    assert_eq!(cached.resume[0].id, "item-resume-1");
}

// ── Detailed record and light lists ──────────────────────

#[tokio::test]
async fn item_details_asks_for_people_but_library_lists_do_not() {
    let server = MockServer::start().await;
    let client = logged_in_client(&server, "details").await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .respond_with(json(
            r#"{"Items":[{"Id":"m1","Name":"Film","People":[{"Name":"Ana","Id":"p1","Type":"Actor"}]}],"TotalRecordCount":1}"#,
        ))
        .mount(&server)
        .await;

    let detail = client.item_details("m1".into()).await.expect("fiche");
    assert_eq!(detail.people.len(), 1);

    client
        .library_items(
            Some("lib".into()),
            0,
            50,
            Some("SortName".into()),
            Some("Ascending".into()),
            None,
        )
        .await
        .expect("liste");

    let requests = server.received_requests().await.unwrap();
    let query_of = |needle: &str| {
        requests
            .iter()
            .filter_map(|r| r.url.query())
            .find(|q| q.contains(needle))
            .map(str::to_string)
    };
    assert!(query_of("ids=m1").unwrap().contains("People"));
    let list_query = query_of("parentId=lib").unwrap();
    assert!(!list_query.contains("People"), "{list_query}");
}

#[tokio::test]
async fn unknown_item_details_is_not_found() {
    let server = MockServer::start().await;
    let client = logged_in_client(&server, "details_404").await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .respond_with(json(r#"{"Items":[],"TotalRecordCount":0}"#))
        .mount(&server)
        .await;
    let err = client.item_details("nope".into()).await.unwrap_err();
    assert!(matches!(err, JellyfinError::NotFound(_)), "{err:?}");
}

// ── Recherche ──────────────────────────────────────────────

#[tokio::test]
async fn search_asks_the_server_across_all_libraries() {
    let server = MockServer::start().await;
    let client = logged_in_client(&server, "search").await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .respond_with(json(
            r#"{"Items":[{"Id":"m1","Name":"Alien","Type":"Movie"},{"Id":"b1","Name":"Alien (livre)","Type":"AudioBook"}]}"#,
        ))
        .mount(&server)
        .await;

    let found = client
        .search("  alien ".into(), 50)
        .await
        .expect("recherche");
    assert_eq!(found.len(), 2);

    let requests = server.received_requests().await.unwrap();
    let query = requests
        .iter()
        .filter_map(|r| r.url.query())
        .find(|q| q.contains("searchTerm"))
        .unwrap()
        .to_string();
    assert!(query.contains("searchTerm=alien"), "{query}");
    assert!(
        query.contains("recursive=true") && query.contains("AudioBook"),
        "{query}"
    );
    assert!(
        !query.contains("parentId"),
        "all the libraries, not just one"
    );

    // Empty term: no needless request.
    let before = server.received_requests().await.unwrap().len();
    assert!(client.search("   ".into(), 50).await.unwrap().is_empty());
    assert_eq!(server.received_requests().await.unwrap().len(), before);
}

// ── Segments (skip the intro) ──────────────────────────────

#[tokio::test]
async fn media_segments_are_sorted_and_invalid_ones_dropped() {
    let server = MockServer::start().await;
    let client = logged_in_client(&server, "segments").await;
    Mock::given(method("GET"))
        .and(path("/MediaSegments/ep1"))
        .respond_with(json(
            r#"{"Items":[{"Type":"Outro","StartTicks":20000000000,"EndTicks":21000000000},
                         {"Type":"Intro","StartTicks":600000000,"EndTicks":1500000000},
                         {"Type":"Intro","StartTicks":5,"EndTicks":5}],"TotalRecordCount":3}"#,
        ))
        .mount(&server)
        .await;

    let segments = client.media_segments("ep1".into()).await;
    assert_eq!(segments.len(), 2, "the empty segment is ignored");
    assert_eq!(segments[0].kind, "Intro");
    assert_eq!(segments[1].kind, "Outro");
}

#[tokio::test]
async fn media_segments_on_an_older_server_are_simply_empty() {
    let server = MockServer::start().await;
    let client = logged_in_client(&server, "segments_old").await;
    Mock::given(method("GET"))
        .and(path("/MediaSegments/ep1"))
        .respond_with(ResponseTemplate::new(404))
        .mount(&server)
        .await;
    assert!(client.media_segments("ep1".into()).await.is_empty());
}

#[tokio::test]
async fn latest_per_library_is_cached_for_the_next_launch() {
    use wiremock::matchers::query_param;
    let server = MockServer::start().await;
    let client = logged_in_client(&server, "latest_lib").await;
    Mock::given(method("GET"))
        .and(path("/Items/Latest"))
        .and(query_param("parentId", "lib-films"))
        .respond_with(json(r#"[{"Id":"m9","Name":"Nouveau","Type":"Movie"}]"#))
        .mount(&server)
        .await;
    let items = client
        .latest_in_library("lib-films".into(), 20)
        .await
        .unwrap();
    assert_eq!(items[0].id, "m9");
    assert_eq!(
        client
            .cached_latest_in_library("lib-films".into())
            .await
            .len(),
        1
    );
}

#[tokio::test]
async fn items_with_a_person_are_searched_across_libraries() {
    use wiremock::matchers::query_param;
    let server = MockServer::start().await;
    let client = logged_in_client(&server, "person").await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("personIds", "actor-1"))
        .and(query_param("recursive", "true"))
        .respond_with(json(
            r#"{"Items":[{"Id":"m1","Name":"Movie","Type":"Movie"},{"Id":"s1","Name":"Series","Type":"Series"}]}"#,
        ))
        .mount(&server)
        .await;
    let items = client.items_with_person("actor-1".into()).await.unwrap();
    assert_eq!(
        items.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
        ["m1", "s1"]
    );
}

#[tokio::test]
async fn media_info_describes_streams_and_direct_play_is_assessed() {
    use playfin_core::playback_support;
    let server = MockServer::start().await;
    let client = logged_in_client(&server, "mediainfo").await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .respond_with(json(
            r#"{"Items":[{"Id":"m1","MediaSources":[{"Container":"mkv","MediaStreams":[
                {"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,"VideoRangeType":"HDR10"},
                {"Type":"Audio","Codec":"eac3","Language":"fre","Channels":6,"IsDefault":true},
                {"Type":"Audio","Codec":"truehd","Language":"eng","Channels":8},
                {"Type":"Subtitle","Codec":"subrip","Language":"fre"},
                {"Type":"Subtitle","Codec":"pgssub","Language":"eng"}]}]}]}"#,
        ))
        .mount(&server)
        .await;
    let info = client.media_info("m1".into()).await.unwrap();
    assert_eq!(info.video_codec.as_deref(), Some("hevc"));
    assert_eq!(info.audio.len(), 2);
    assert_eq!(info.audio[0].language.as_deref(), Some("fre"));
    assert_eq!(info.subtitles.len(), 2);
    let support = playback_support(info.clone());
    assert!(support.direct_play && support.hardware_decoding);
    assert!(support.notes.is_empty(), "{:?}", support.notes);

    let mut odd = info;
    odd.video_codec = Some("rv40".into());
    odd.audio[0].codec = "cook".into();
    odd.audio[1].codec = "cook".into();
    let support = playback_support(odd);
    assert!(!support.direct_play);
    assert_eq!(support.notes.len(), 2);
}
