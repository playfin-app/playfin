//! Tests of the downloader against a fake server (wiremock) that handles byte ranges.

use super::*;
use crate::SessionInfo;
use std::sync::atomic::AtomicUsize;
use wiremock::matchers::{method, path_regex};
use wiremock::{Mock, MockServer, Request, Respond, ResponseTemplate};

const MIB: usize = 1024 * 1024;

/// Fake file served with or without byte ranges; can fail for some ranges.
#[derive(Clone)]
struct FileResponder {
    data: Arc<Vec<u8>>,
    etag: String,
    ranges: bool,
    /// Answers 500 to ranges that do not start at 0 (except the 1-byte probe).
    fail_non_zero_ranges: bool,
    status_override: Option<u16>,
    requests: Arc<Mutex<Vec<String>>>,
    served: Arc<AtomicUsize>,
}

impl FileResponder {
    fn new(data: Vec<u8>, etag: &str) -> Self {
        Self {
            data: Arc::new(data),
            etag: etag.into(),
            ranges: true,
            fail_non_zero_ranges: false,
            status_override: None,
            requests: Arc::new(Mutex::new(Vec::new())),
            served: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn ranges_seen(&self) -> Vec<String> {
        self.requests.lock().unwrap().clone()
    }
}

impl Respond for FileResponder {
    fn respond(&self, request: &Request) -> ResponseTemplate {
        if let Some(code) = self.status_override {
            return ResponseTemplate::new(code);
        }
        let range = request
            .headers
            .get("range")
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        self.requests
            .lock()
            .unwrap()
            .push(range.clone().unwrap_or_else(|| "full".into()));
        let total = self.data.len();
        let base = ResponseTemplate::new(200)
            .insert_header("ETag", self.etag.as_str())
            .insert_header("Content-Disposition", "attachment; filename=\"film.mkv\"");
        match (self.ranges, range) {
            (true, Some(range)) => {
                let spec = range.trim_start_matches("bytes=");
                let (a, b) = spec.split_once('-').unwrap();
                let start: usize = a.parse().unwrap();
                let end: usize = b.parse::<usize>().unwrap().min(total - 1);
                if self.fail_non_zero_ranges && start > 0 {
                    return ResponseTemplate::new(500);
                }
                self.served.fetch_add(end + 1 - start, Ordering::SeqCst);
                ResponseTemplate::new(206)
                    .insert_header("ETag", self.etag.as_str())
                    .insert_header("Accept-Ranges", "bytes")
                    .insert_header(
                        "Content-Range",
                        format!("bytes {start}-{end}/{total}").as_str(),
                    )
                    .insert_header("Content-Disposition", "attachment; filename=\"film.mkv\"")
                    .set_body_bytes(self.data[start..=end].to_vec())
            }
            _ => {
                self.served.fetch_add(total, Ordering::SeqCst);
                base.set_body_bytes(self.data.as_ref().clone())
            }
        }
    }
}

fn data(size: usize) -> Vec<u8> {
    (0..size).map(|i| (i * 31 % 251) as u8).collect()
}

fn temp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("jn_dl_{name}_{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn client(uri: &str, dir: &Path) -> Arc<JellyfinClient> {
    Arc::new(JellyfinClient::restore(
        SessionInfo {
            server_url: uri.into(),
            server_id: "srv".into(),
            user_id: "user".into(),
            access_token: "tok".into(),
        },
        dir.join("cache").to_str().unwrap(),
    ))
}

fn settings(root: &Path, connections: u32) -> DownloadSettings {
    DownloadSettings {
        root: root.to_string_lossy().into(),
        server_name: "Lounge".into(),
        connections,
        max_concurrent: 2,
        bandwidth_limit_kbps: 0,
        retry_attempts: 3,
        retry_base_delay_ms: 5,
        subtitle_mode: "none".into(),
        preferred_languages: vec![],
    }
}

fn movie(id: &str) -> Movie {
    serde_json::from_str(&format!(
        r#"{{"Id":"{id}","Name":"Movie {id}","ProductionYear":2001,"Type":"Movie"}}"#
    ))
    .unwrap()
}

struct BigDisk;
impl DiskSpace for BigDisk {
    fn available_bytes(&self, _: &Path) -> Option<u64> {
        Some(u64::MAX / 2)
    }
}

struct FullDisk;
impl DiskSpace for FullDisk {
    fn available_bytes(&self, _: &Path) -> Option<u64> {
        Some(10 * 1024 * 1024)
    }
}

async fn mount(server: &MockServer, responder: FileResponder) {
    Mock::given(method("GET"))
        .and(path_regex(r"^/Items/[^/]+/Download$"))
        .respond_with(responder)
        .mount(server)
        .await;
    // Images and subtitles: we simply answer 404 (side files are optional).
}

async fn wait_for(manager: &DownloadManager, id: &str, state: DownloadState) -> DownloadInfo {
    for _ in 0..600 {
        if let Some(info) = manager.snapshot().into_iter().find(|i| i.item_id == id)
            && info.state == state
        {
            return info;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("state {state:?} never reached: {:?}", manager.snapshot());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn downloads_with_several_connections_and_puts_the_file_in_place() {
    let server = MockServer::start().await;
    let content = data(20 * MIB + 123);
    let responder = FileResponder::new(content.clone(), "\"v1\"");
    mount(&server, responder.clone()).await;
    let dir = temp("multi");
    let manager = DownloadManager::with_disk(
        client(&server.uri(), &dir),
        dir.to_str().unwrap(),
        settings(&dir.join("dl"), 4),
        Box::new(BigDisk),
    )
    .unwrap();

    assert_eq!(manager.clone().enqueue(vec![movie("m1")]).await.unwrap(), 1);
    let info = wait_for(&manager, "m1", DownloadState::Completed).await;
    let path = info.local_path.unwrap();
    assert!(
        path.ends_with("Lounge/Movies/Movie m1 (2001).mkv"),
        "{path}"
    );
    assert_eq!(
        std::fs::read(&path).unwrap(),
        content,
        "byte-for-byte identical content"
    );
    assert!(
        !Path::new(&format!("{path}.part")).exists(),
        "no more .part file"
    );
    // Several ranges requested (+ the probe), and nothing downloaded twice.
    let ranges = responder.ranges_seen();
    assert!(ranges.len() >= 3, "{ranges:?}");
    assert_eq!(manager.local_file("m1".into()), Some(path));
    assert_eq!(manager.downloaded_items().len(), 1);
    // Adding a second time: nothing is added.
    assert_eq!(manager.clone().enqueue(vec![movie("m1")]).await.unwrap(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn without_range_support_it_falls_back_to_one_connection() {
    let server = MockServer::start().await;
    let content = data(3 * MIB);
    let mut responder = FileResponder::new(content.clone(), "\"v1\"");
    responder.ranges = false;
    mount(&server, responder.clone()).await;
    let dir = temp("norange");
    let manager = DownloadManager::with_disk(
        client(&server.uri(), &dir),
        dir.to_str().unwrap(),
        settings(&dir.join("dl"), 8),
        Box::new(BigDisk),
    )
    .unwrap();
    manager.clone().enqueue(vec![movie("m1")]).await.unwrap();
    let info = wait_for(&manager, "m1", DownloadState::Completed).await;
    assert!(
        !info.ranges_supported,
        "the screen shows: a single connection"
    );
    assert_eq!(std::fs::read(info.local_path.unwrap()).unwrap(), content);
}

/// Resume after a stop: a first manager only gets the first segment, a second (as after an app
/// restart) only requests what is missing.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn resumes_after_restart_without_downloading_twice() {
    let content = data(20 * MIB);
    let dir = temp("resume");
    {
        let server = MockServer::start().await;
        let mut failing = FileResponder::new(content.clone(), "\"v1\"");
        failing.fail_non_zero_ranges = true;
        mount(&server, failing).await;
        let mut s = settings(&dir.join("dl"), 2);
        s.retry_attempts = 0;
        let manager = DownloadManager::with_disk(
            client(&server.uri(), &dir),
            dir.to_str().unwrap(),
            s,
            Box::new(BigDisk),
        )
        .unwrap();
        manager.clone().enqueue(vec![movie("m1")]).await.unwrap();
        let info = wait_for(&manager, "m1", DownloadState::Failed).await;
        assert!(
            info.downloaded_bytes >= 10 * MIB as u64 - 1,
            "first segment kept: {info:?}"
        );
    }
    let server = MockServer::start().await;
    let healthy = FileResponder::new(content.clone(), "\"v1\"");
    mount(&server, healthy.clone()).await;
    let manager = DownloadManager::with_disk(
        client(&server.uri(), &dir),
        dir.to_str().unwrap(),
        settings(&dir.join("dl"), 2),
        Box::new(BigDisk),
    )
    .unwrap();
    manager.clone().retry("m1".into()).await;
    let info = wait_for(&manager, "m1", DownloadState::Completed).await;
    assert_eq!(std::fs::read(info.local_path.unwrap()).unwrap(), content);
    let ranges = healthy.ranges_seen();
    assert!(
        ranges
            .iter()
            .filter(|r| *r != "bytes=0-0")
            .all(|r| !r.starts_with("bytes=0-")),
        "the start is not downloaded again: {ranges:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_file_changed_on_the_server_restarts_from_zero() {
    let old = data(20 * MIB);
    let dir = temp("etag");
    {
        let server = MockServer::start().await;
        let mut failing = FileResponder::new(old.clone(), "\"v1\"");
        failing.fail_non_zero_ranges = true;
        mount(&server, failing).await;
        let mut s = settings(&dir.join("dl"), 2);
        s.retry_attempts = 0;
        let manager = DownloadManager::with_disk(
            client(&server.uri(), &dir),
            dir.to_str().unwrap(),
            s,
            Box::new(BigDisk),
        )
        .unwrap();
        manager.clone().enqueue(vec![movie("m1")]).await.unwrap();
        wait_for(&manager, "m1", DownloadState::Failed).await;
    }
    let new: Vec<u8> = data(20 * MIB)
        .into_iter()
        .map(|b| b.wrapping_add(1))
        .collect();
    let server = MockServer::start().await;
    let changed = FileResponder::new(new.clone(), "\"v2\"");
    mount(&server, changed.clone()).await;
    let manager = DownloadManager::with_disk(
        client(&server.uri(), &dir),
        dir.to_str().unwrap(),
        settings(&dir.join("dl"), 2),
        Box::new(BigDisk),
    )
    .unwrap();
    manager.clone().retry("m1".into()).await;
    let info = wait_for(&manager, "m1", DownloadState::Completed).await;
    assert_eq!(
        std::fs::read(info.local_path.unwrap()).unwrap(),
        new,
        "new file, not a mix of the two"
    );
    assert!(
        changed
            .ranges_seen()
            .iter()
            .any(|r| r.starts_with("bytes=0-") && r != "bytes=0-0")
    );
}

/// The address changes on the fly (we leave home): the segments restart on the new address.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn switches_address_mid_download_without_losing_progress() {
    let content = data(20 * MIB);
    let dir = temp("switch");
    let home = MockServer::start().await;
    let mut home_responder = FileResponder::new(content.clone(), "\"v1\"");
    home_responder.fail_non_zero_ranges = true; // home only serves the start, then "disappears"
    mount(&home, home_responder).await;
    let remote = MockServer::start().await;
    let remote_responder = FileResponder::new(content.clone(), "\"v1\"");
    mount(&remote, remote_responder.clone()).await;

    let client = client(&home.uri(), &dir);
    let mut s = settings(&dir.join("dl"), 2);
    s.retry_attempts = 6;
    s.retry_base_delay_ms = 40;
    let manager =
        DownloadManager::with_disk(client.clone(), dir.to_str().unwrap(), s, Box::new(BigDisk))
            .unwrap();
    manager.clone().enqueue(vec![movie("m1")]).await.unwrap();
    // As soon as the start is written, the app switches to the remote address (as after a network change).
    for _ in 0..200 {
        if manager.snapshot()[0].downloaded_bytes > 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    client.set_server_url(&remote.uri());
    let info = wait_for(&manager, "m1", DownloadState::Completed).await;
    assert_eq!(std::fs::read(info.local_path.unwrap()).unwrap(), content);
    assert!(
        remote_responder
            .ranges_seen()
            .iter()
            .all(|r| !r.starts_with("bytes=0-") || r == "bytes=0-0"),
        "the part already downloaded at home is not requested again: {:?}",
        remote_responder.ranges_seen()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_full_disk_fails_clearly_before_downloading() {
    let server = MockServer::start().await;
    let responder = FileResponder::new(data(20 * MIB), "\"v1\"");
    mount(&server, responder.clone()).await;
    let dir = temp("disk");
    let manager = DownloadManager::with_disk(
        client(&server.uri(), &dir),
        dir.to_str().unwrap(),
        settings(&dir.join("dl"), 2),
        Box::new(FullDisk),
    )
    .unwrap();
    manager.clone().enqueue(vec![movie("m1")]).await.unwrap();
    let info = wait_for(&manager, "m1", DownloadState::Failed).await;
    assert!(info.error.unwrap().contains("disk space"), "message clair");
    assert_eq!(
        responder.ranges_seen(),
        ["bytes=0-0"],
        "only the probe was made"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn forbidden_downloads_explain_why() {
    let server = MockServer::start().await;
    let mut responder = FileResponder::new(data(1024), "\"v1\"");
    responder.status_override = Some(403);
    mount(&server, responder).await;
    let dir = temp("forbidden");
    let manager = DownloadManager::with_disk(
        client(&server.uri(), &dir),
        dir.to_str().unwrap(),
        settings(&dir.join("dl"), 2),
        Box::new(BigDisk),
    )
    .unwrap();
    manager.clone().enqueue(vec![movie("m1")]).await.unwrap();
    let info = wait_for(&manager, "m1", DownloadState::Failed).await;
    assert!(info.error.unwrap().contains("administrator"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn retries_are_limited_then_the_download_fails() {
    let server = MockServer::start().await;
    let mut responder = FileResponder::new(data(1024), "\"v1\"");
    responder.status_override = Some(503);
    mount(&server, responder).await;
    let dir = temp("retries");
    let mut s = settings(&dir.join("dl"), 1);
    s.retry_attempts = 2;
    let manager = DownloadManager::with_disk(
        client(&server.uri(), &dir),
        dir.to_str().unwrap(),
        s,
        Box::new(BigDisk),
    )
    .unwrap();
    manager.clone().enqueue(vec![movie("m1")]).await.unwrap();
    wait_for(&manager, "m1", DownloadState::Failed).await;
    // 1 attempt + 2 new attempts.
    assert_eq!(server.received_requests().await.unwrap().len(), 3);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_bandwidth_limit_is_respected() {
    let server = MockServer::start().await;
    let content = data(600 * 1024);
    mount(&server, FileResponder::new(content.clone(), "\"v1\"")).await;
    let dir = temp("bandwidth");
    let mut s = settings(&dir.join("dl"), 2);
    s.bandwidth_limit_kbps = 200; // 600 KiB at 200 KiB/s: at least ~2 s (1 s of burst allowed)
    let manager = DownloadManager::with_disk(
        client(&server.uri(), &dir),
        dir.to_str().unwrap(),
        s,
        Box::new(BigDisk),
    )
    .unwrap();
    let started = Instant::now();
    manager.clone().enqueue(vec![movie("m1")]).await.unwrap();
    let info = wait_for(&manager, "m1", DownloadState::Completed).await;
    assert!(
        started.elapsed() >= Duration::from_millis(1800),
        "too fast: {:?}",
        started.elapsed()
    );
    assert_eq!(std::fs::read(info.local_path.unwrap()).unwrap(), content);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn queue_limits_concurrency_and_supports_pause_reorder_and_remove() {
    let server = MockServer::start().await;
    mount(&server, FileResponder::new(data(2 * MIB), "\"v1\"")).await;
    let dir = temp("queue");
    let mut s = settings(&dir.join("dl"), 1);
    s.max_concurrent = 1;
    s.bandwidth_limit_kbps = 1024; // slow enough to observe the queue (2 s per item)
    let manager = DownloadManager::with_disk(
        client(&server.uri(), &dir),
        dir.to_str().unwrap(),
        s,
        Box::new(BigDisk),
    )
    .unwrap();
    manager
        .clone()
        .enqueue(vec![movie("a"), movie("b"), movie("c")])
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    let states: Vec<_> = manager.snapshot().iter().map(|i| i.state).collect();
    assert_eq!(
        states
            .iter()
            .filter(|s| **s == DownloadState::Downloading)
            .count(),
        1,
        "{states:?}"
    );

    // "c" moves to the head of the queue; "b" is paused then removed.
    manager.clone().move_to("c".into(), 0).await;
    manager.clone().pause("b".into()).await;
    assert_eq!(
        manager
            .snapshot()
            .iter()
            .find(|i| i.item_id == "b")
            .unwrap()
            .state,
        DownloadState::Paused
    );
    manager.clone().remove("b".into()).await;
    assert!(manager.snapshot().iter().all(|i| i.item_id != "b"));

    wait_for(&manager, "a", DownloadState::Completed).await;
    wait_for(&manager, "c", DownloadState::Completed).await;
    assert_eq!(
        manager.snapshot().first().unwrap().item_id,
        "c",
        "chosen order kept"
    );
    manager.clone().remove("a".into()).await;
    assert!(
        manager.local_file("a".into()).is_none(),
        "file deleted along with the download"
    );
}

#[test]
fn offline_report_conflict_rule() {
    assert!(
        offline_report_wins(1000, None),
        "nothing on the server: we send"
    );
    assert!(
        offline_report_wins(1000, Some(900)),
        "our playback is more recent"
    );
    assert!(
        !offline_report_wins(1000, Some(1100)),
        "played elsewhere more recently: we keep the server"
    );
}

#[test]
fn iso_dates_round_trip() {
    let t = crate::parse_iso8601_utc("2026-10-08T12:34:56.1234567Z").unwrap();
    assert_eq!(crate::format_iso8601_utc(t), "2026-10-08T12:34:56.0000000Z");
    assert_eq!(crate::parse_iso8601_utc("1970-01-01T00:00:00Z"), Some(0));
    assert_eq!(
        crate::parse_iso8601_utc("2000-02-29T00:00:00+01:00"),
        Some(951_778_800)
    );
    assert_eq!(crate::parse_iso8601_utc("not a date"), None);
}

/// Offline reports: sent in order when the server is back, unless the item was watched elsewhere since.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn offline_reports_are_flushed_with_the_conflict_rule() {
    use wiremock::matchers::{path, query_param};
    let server = MockServer::start().await;
    // "recent" was played on the server in 2030 (after our reports); "old" in 2001.
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("ids", "recent"))
        .respond_with(ResponseTemplate::new(200).set_body_raw(
            r#"{"Items":[{"Id":"recent","RunTimeTicks":1000,"UserData":{"LastPlayedDate":"2030-01-01T00:00:00Z"}}]}"#,
            "application/json",
        ))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("ids", "old"))
        .respond_with(ResponseTemplate::new(200).set_body_raw(
            r#"{"Items":[{"Id":"old","RunTimeTicks":1000,"UserData":{"LastPlayedDate":"2001-01-01T00:00:00Z"}}]}"#,
            "application/json",
        ))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path_regex(r"^/UserItems/[^/]+/UserData$"))
        .respond_with(ResponseTemplate::new(200))
        .mount(&server)
        .await;

    let dir = temp("reports");
    let manager = DownloadManager::with_disk(
        client(&server.uri(), &dir),
        dir.to_str().unwrap(),
        settings(&dir.join("dl"), 1),
        Box::new(BigDisk),
    )
    .unwrap();
    manager.queue_report("old".into(), "progress".into(), 100);
    manager.queue_report("old".into(), "stopped".into(), 950); // the last one counts: 95% → watched
    manager.queue_report("recent".into(), "stopped".into(), 500);
    assert_eq!(manager.pending_report_count(), 3);

    assert_eq!(
        manager.clone().flush_reports().await.unwrap(),
        1,
        "only \"old\" is sent"
    );
    assert_eq!(
        manager.pending_report_count(),
        0,
        "the queue is emptied, even for the item kept on the server side"
    );
    let posts: Vec<_> = server
        .received_requests()
        .await
        .unwrap()
        .into_iter()
        .filter(|r| r.method.as_str() == "POST")
        .collect();
    assert_eq!(posts.len(), 1);
    assert!(posts[0].url.path().contains("/UserItems/old/UserData"));
    let body: serde_json::Value = serde_json::from_slice(&posts[0].body).unwrap();
    assert_eq!(body["Played"], true);
}

/// Budget: several connections must never be slower than a single one.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn several_connections_are_not_slower_than_one() {
    let server = MockServer::start().await;
    let content = data(48 * MIB);
    mount(&server, FileResponder::new(content.clone(), "\"v1\"")).await;
    let mut timings = Vec::new();
    for connections in [1, 4] {
        let dir = temp("throughput");
        let manager = DownloadManager::with_disk(
            client(&server.uri(), &dir),
            dir.to_str().unwrap(),
            settings(&dir.join("dl"), connections),
            Box::new(BigDisk),
        )
        .unwrap();
        let started = Instant::now();
        manager.clone().enqueue(vec![movie("t")]).await.unwrap();
        wait_for(&manager, "t", DownloadState::Completed).await;
        timings.push(started.elapsed());
        let _ = std::fs::remove_dir_all(dir);
    }
    // 50% margin: the test machine is shared, we only check there is no clear slowdown.
    assert!(
        timings[1] <= timings[0] * 3 / 2 + Duration::from_millis(200),
        "{timings:?}"
    );
}

/// What a download contains besides the file: poster, background and external subtitles (preferred language).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn assets_are_saved_next_to_the_file() {
    use wiremock::matchers::path;
    let server = MockServer::start().await;
    mount(&server, FileResponder::new(data(4096), "\"v1\"")).await;
    Mock::given(method("GET"))
        .and(path_regex(r"^/Items/m1/Images/(Primary|Backdrop)$"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(vec![0xFF, 0xD8, 0xFF]))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items/m1"))
        .respond_with(ResponseTemplate::new(200).set_body_raw(
            r#"{"MediaSources":[{"Id":"src","MediaStreams":[
                {"Type":"Subtitle","Index":3,"Codec":"subrip","Language":"fre","IsExternal":true},
                {"Type":"Subtitle","Index":4,"Codec":"subrip","Language":"ger","IsExternal":true}]}]}"#,
            "application/json",
        ))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path_regex(r"^/Videos/m1/src/Subtitles/\d+/Stream\.srt$"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_string("1\n00:00:01,000 --> 00:00:02,000\nBonjour\n"),
        )
        .mount(&server)
        .await;

    let dir = temp("assets");
    let mut s = settings(&dir.join("dl"), 1);
    s.subtitle_mode = "preferred".into();
    s.preferred_languages = vec!["fr".into()];
    let manager = DownloadManager::with_disk(
        client(&server.uri(), &dir),
        dir.to_str().unwrap(),
        s,
        Box::new(BigDisk),
    )
    .unwrap();
    manager.clone().enqueue(vec![movie("m1")]).await.unwrap();
    wait_for(&manager, "m1", DownloadState::Completed).await;

    assert!(manager.local_asset("m1".into(), "poster".into()).is_some());
    assert!(
        manager
            .local_asset("m1".into(), "backdrop".into())
            .is_some()
    );
    let subtitles = manager.local_subtitles("m1".into());
    assert_eq!(
        subtitles.len(),
        1,
        "only the preferred language (fr), not German"
    );
    assert!(
        subtitles[0].url.ends_with(".fre.0.srt"),
        "{}",
        subtitles[0].url
    );
    // The item metadata is kept to browse offline.
    assert_eq!(manager.downloaded_items()[0].name, "Movie m1");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_season_or_a_whole_series_is_queued_episode_by_episode() {
    use wiremock::matchers::path;
    let server = MockServer::start().await;
    mount(&server, FileResponder::new(data(1024), "\"v1\"")).await;
    Mock::given(method("GET"))
        .and(path("/Shows/serie/Episodes"))
        .respond_with(ResponseTemplate::new(200).set_body_raw(
            r#"{"Items":[
                {"Id":"e1","Name":"One","Type":"Episode","SeriesName":"S","SeriesId":"serie","SeasonId":"s1","IndexNumber":1,"ParentIndexNumber":1},
                {"Id":"e2","Name":"Deux","Type":"Episode","SeriesName":"S","SeriesId":"serie","SeasonId":"s1","IndexNumber":2,"ParentIndexNumber":1},
                {"Id":"e3","Name":"Trois","Type":"Episode","SeriesName":"S","SeriesId":"serie","SeasonId":"s2","IndexNumber":1,"ParentIndexNumber":2}]}"#,
            "application/json",
        ))
        .mount(&server)
        .await;
    let dir = temp("series");
    let manager = DownloadManager::with_disk(
        client(&server.uri(), &dir),
        dir.to_str().unwrap(),
        settings(&dir.join("dl"), 1),
        Box::new(BigDisk),
    )
    .unwrap();
    assert_eq!(
        manager
            .clone()
            .enqueue_series("serie".into(), Some("s2".into()))
            .await
            .unwrap(),
        1,
        "one season"
    );
    assert_eq!(
        manager
            .clone()
            .enqueue_series("serie".into(), None)
            .await
            .unwrap(),
        2,
        "the rest of the series"
    );
    let info = wait_for(&manager, "e1", DownloadState::Completed).await;
    assert!(
        info.local_path
            .unwrap()
            .ends_with("Lounge/S/Season 1/S - S01E01 - One.mkv")
    );
    assert_eq!(info.title, "S · S1:E1 · One");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_download_permission_is_read_from_the_user_policy() {
    use wiremock::matchers::path;
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/Users/Me"))
        .respond_with(ResponseTemplate::new(200).set_body_raw(
            r#"{"Id":"user","Name":"Ana","Policy":{"EnableContentDownloading":false}}"#,
            "application/json",
        ))
        .mount(&server)
        .await;
    let dir = temp("policy");
    assert!(!client(&server.uri(), &dir).can_download().await.unwrap());
}

/// Changing the number of connections during a download applies right away, without losing the progress.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn changing_connections_applies_to_the_download_in_progress() {
    let server = MockServer::start().await;
    let content = data(32 * MIB);
    let responder = FileResponder::new(content.clone(), "\"v1\"");
    mount(&server, responder.clone()).await;
    let dir = temp("reconfigure");
    let mut s = settings(&dir.join("dl"), 1);
    s.bandwidth_limit_kbps = 16 * 1024; // slow: there is time to change the setting
    let manager = DownloadManager::with_disk(
        client(&server.uri(), &dir),
        dir.to_str().unwrap(),
        s.clone(),
        Box::new(BigDisk),
    )
    .unwrap();
    manager.clone().enqueue(vec![movie("m1")]).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let before = responder.ranges_seen().len();
    let mut faster = s;
    faster.connections = 4;
    faster.bandwidth_limit_kbps = 0;
    manager.clone().update_settings(faster).await;
    let info = wait_for(&manager, "m1", DownloadState::Completed).await;
    assert_eq!(std::fs::read(info.local_path.unwrap()).unwrap(), content);
    let after: Vec<String> = responder
        .ranges_seen()
        .into_iter()
        .skip(before)
        .filter(|r| r != "bytes=0-0")
        .collect();
    assert!(
        after.len() >= 2,
        "several connections after the change: {after:?}"
    );
    assert!(
        after.iter().all(|r| !r.starts_with("bytes=0-")),
        "the start already written is not requested again: {after:?}"
    );
}
