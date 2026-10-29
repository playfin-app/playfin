//! Downloads: queue, multi-connection segmented downloader
//! (aria2 style), resume after pause / stop / crash, address change on the fly, speed limit,
//! side files (subtitles, images, metadata) and playback reports made offline.
//!
//! The pure logic (splitting, paths, token bucket) is in `plan` and `bucket`; this file does the inputs /
//! outputs (HTTP, file, SQLite database).

pub mod bucket;
pub mod plan;
mod store;

use crate::{JellyfinClient, JellyfinError, Movie, unix_now};
use bucket::TokenBucket;
use plan::{MIN_SEGMENT, MIN_STEAL, NamingInfo, Segment};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use store::DownloadStore;

/// Disk space margin kept free (1 GB).
const DISK_MARGIN: u64 = 1024 * 1024 * 1024;
/// Frequency at which progress is saved (at least every 2 s).
const PERSIST_EVERY: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DownloadState {
    Queued,
    Downloading,
    Paused,
    Completed,
    Failed,
}

impl DownloadState {
    fn parse(value: &str) -> Self {
        match value {
            "downloading" => Self::Downloading,
            "paused" => Self::Paused,
            "completed" => Self::Completed,
            "failed" => Self::Failed,
            _ => Self::Queued,
        }
    }
}

/// Downloader settings (Settings > Downloads).
#[derive(Debug, Clone, uniffi::Record)]
pub struct DownloadSettings {
    /// Root folder (e.g. ~/Movies/Playfin).
    pub root: String,
    /// Server name, first folder level.
    pub server_name: String,
    /// Connections per file (1 to 16).
    pub connections: u32,
    /// Simultaneous downloads (1 to 5).
    pub max_concurrent: u32,
    /// Global speed limit in KiB/s (0 = none).
    pub bandwidth_limit_kbps: u32,
    /// Attempts per segment before failing.
    pub retry_attempts: u32,
    /// Base delay between two attempts (1 s in the app; shorter in the tests).
    pub retry_base_delay_ms: u64,
    /// External subtitles: "all", "preferred" or "none".
    pub subtitle_mode: String,
    pub preferred_languages: Vec<String>,
}

impl DownloadSettings {
    fn sanitized(mut self) -> Self {
        self.connections = self.connections.clamp(1, 16);
        self.max_concurrent = self.max_concurrent.clamp(1, 5);
        self.retry_attempts = self.retry_attempts.min(20);
        self
    }
}

/// State of a download, for the Downloads screen (read at most 4 times per second).
#[derive(Debug, Clone, uniffi::Record)]
pub struct DownloadInfo {
    pub item_id: String,
    pub title: String,
    pub state: DownloadState,
    pub position: i64,
    pub total_bytes: u64,
    pub downloaded_bytes: u64,
    pub bytes_per_second: u64,
    pub eta_seconds: Option<u64>,
    /// Connections currently in use.
    pub connections: u32,
    /// False if the server does not allow byte ranges (a single connection, no resume).
    pub ranges_supported: bool,
    pub error: Option<String>,
    pub local_path: Option<String>,
    pub created_at: i64,
}

/// Free disk space (replaceable in the tests).
pub trait DiskSpace: Send + Sync {
    fn available_bytes(&self, path: &Path) -> Option<u64>;
}

struct SystemDiskSpace;

impl DiskSpace for SystemDiskSpace {
    fn available_bytes(&self, path: &Path) -> Option<u64> {
        let mut existing = path.to_path_buf();
        while !existing.exists() {
            existing = existing.parent()?.to_path_buf();
        }
        let c_path = std::ffi::CString::new(existing.to_string_lossy().as_bytes()).ok()?;
        // SAFETY: `statvfs` fills the given structure; the path is a valid C string that lives until the end of the call.
        unsafe {
            let mut stats: libc::statvfs = std::mem::zeroed();
            if libc::statvfs(c_path.as_ptr(), &mut stats) == 0 {
                Some(stats.f_bavail as u64 * stats.f_frsize as u64)
            } else {
                None
            }
        }
    }
}

/// Download in progress: stop flag and counters read by `snapshot`.
struct Active {
    /// Stop requested by the user (pause, deletion).
    stop: AtomicBool,
    /// A connection failed for good: the others stop too.
    abort: AtomicBool,
    done_bytes: AtomicU64,
    total_bytes: AtomicU64,
    connections: AtomicU32,
    samples: Mutex<VecDeque<(Instant, u64)>>,
}

impl Active {
    fn halted(&self) -> bool {
        self.stop.load(Ordering::SeqCst) || self.abort.load(Ordering::SeqCst)
    }

    fn new() -> Self {
        Self {
            stop: AtomicBool::new(false),
            abort: AtomicBool::new(false),
            done_bytes: AtomicU64::new(0),
            total_bytes: AtomicU64::new(0),
            connections: AtomicU32::new(0),
            samples: Mutex::new(VecDeque::new()),
        }
    }

    /// Average speed over the last 3 seconds.
    fn speed(&self) -> u64 {
        let now = Instant::now();
        let bytes = self.done_bytes.load(Ordering::Relaxed);
        let mut samples = self.samples.lock().unwrap_or_else(|e| e.into_inner());
        samples.push_back((now, bytes));
        while samples.len() > 2 && now.duration_since(samples[0].0) > Duration::from_secs(3) {
            samples.pop_front();
        }
        let (first_time, first_bytes) = samples[0];
        let elapsed = now.duration_since(first_time).as_secs_f64();
        if elapsed < 0.2 {
            return 0;
        }
        (bytes.saturating_sub(first_bytes) as f64 / elapsed) as u64
    }
}

struct Inner {
    store: Mutex<DownloadStore>,
    settings: Mutex<DownloadSettings>,
    active: Mutex<HashMap<String, Arc<Active>>>,
    bucket: Mutex<TokenBucket>,
    disk: Box<dyn DiskSpace>,
    http: reqwest::Client,
    epoch: Instant,
}

impl Inner {
    fn now_ms(&self) -> u64 {
        self.epoch.elapsed().as_millis() as u64
    }

    fn store(&self) -> std::sync::MutexGuard<'_, DownloadStore> {
        self.store.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn settings(&self) -> DownloadSettings {
        self.settings
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }
}

/// Manager of the downloads of a profile (one server + one user).
#[derive(uniffi::Object)]
pub struct DownloadManager {
    client: Arc<JellyfinClient>,
    inner: Arc<Inner>,
}

impl DownloadManager {
    fn build(
        client: Arc<JellyfinClient>,
        db_dir: &str,
        settings: DownloadSettings,
        disk: Box<dyn DiskSpace>,
    ) -> Result<Self, JellyfinError> {
        let store = DownloadStore::open(&PathBuf::from(db_dir).join("downloads.sqlite"))?;
        let settings = settings.sanitized();
        // Client dedicated to downloads: no total timeout (a movie takes minutes), but a connect
        // and read timeout to detect a drop.
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .read_timeout(Duration::from_secs(30))
            .build()
            .map_err(|e| JellyfinError::Network(e.to_string()))?;
        let rate = settings.bandwidth_limit_kbps as u64 * 1024;
        Ok(Self {
            client,
            inner: Arc::new(Inner {
                store: Mutex::new(store),
                settings: Mutex::new(settings),
                active: Mutex::new(HashMap::new()),
                bucket: Mutex::new(TokenBucket::new(rate, 0)),
                disk,
                http,
                epoch: Instant::now(),
            }),
        })
    }

    #[cfg(test)]
    pub(crate) fn with_disk(
        client: Arc<JellyfinClient>,
        db_dir: &str,
        settings: DownloadSettings,
        disk: Box<dyn DiskSpace>,
    ) -> Result<Arc<Self>, JellyfinError> {
        Ok(Arc::new(Self::build(client, db_dir, settings, disk)?))
    }

    /// `written`: bytes already written per item (see `DownloadStore::downloaded_bytes_by_item`).
    fn info(&self, row: &store::DownloadRow, written: &HashMap<String, u64>) -> DownloadInfo {
        let active = self
            .inner
            .active
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&row.item_id)
            .cloned();
        let state = DownloadState::parse(&row.state);
        let (downloaded, total, speed, connections) = match &active {
            Some(a) => (
                a.done_bytes.load(Ordering::Relaxed),
                a.total_bytes.load(Ordering::Relaxed).max(row.total_bytes),
                a.speed(),
                a.connections.load(Ordering::Relaxed),
            ),
            None => {
                let done = if state == DownloadState::Completed {
                    row.total_bytes
                } else {
                    written.get(&row.item_id).copied().unwrap_or(0)
                };
                (done, row.total_bytes, 0, 0)
            }
        };
        let eta = (speed > 0 && total > downloaded).then(|| (total - downloaded) / speed);
        DownloadInfo {
            item_id: row.item_id.clone(),
            title: row.title.clone(),
            state,
            position: row.position,
            total_bytes: total,
            downloaded_bytes: downloaded.min(total.max(downloaded)),
            bytes_per_second: speed,
            eta_seconds: eta,
            connections,
            ranges_supported: row.ranges,
            error: row.error.clone(),
            local_path: row.final_path.clone(),
            created_at: row.created_at,
        }
    }

    /// Starts the waiting downloads, in queue order, up to the simultaneous limit.
    fn kick(self: &Arc<Self>) {
        let max = self.inner.settings().max_concurrent as usize;
        let rows = match self.inner.store().all() {
            Ok(rows) => rows,
            Err(_) => return,
        };
        let mut active = self.inner.active.lock().unwrap_or_else(|e| e.into_inner());
        for row in rows {
            if active.len() >= max {
                break;
            }
            if DownloadState::parse(&row.state) != DownloadState::Queued
                || active.contains_key(&row.item_id)
            {
                continue;
            }
            if !matches!(self.inner.store().claim(&row.item_id), Ok(true)) {
                continue;
            }
            let handle = Arc::new(Active::new());
            active.insert(row.item_id.clone(), handle.clone());
            let manager = self.clone();
            let id = row.item_id.clone();
            tokio::spawn(async move {
                let result = manager.run(&id, handle.clone()).await;
                let stopped = handle.stop.load(Ordering::SeqCst);
                manager
                    .inner
                    .active
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .remove(&id);
                match result {
                    Ok(()) => {}
                    // Stop requested (pause, cancellation): the state was already written by the command.
                    Err(_) if stopped => {}
                    Err(error) => {
                        let message = describe(&error);
                        let _ = manager
                            .inner
                            .store()
                            .set_state(&id, "failed", Some(&message));
                    }
                }
                manager.kick();
            });
        }
    }

    fn base_url(&self) -> String {
        self.client.server_url()
    }

    async fn request(
        &self,
        url: &str,
        range: Option<(u64, u64)>,
    ) -> Result<reqwest::Response, JellyfinError> {
        let mut request = self
            .inner
            .http
            .get(url)
            .header("Authorization", self.client.auth_header());
        if let Some((start, end)) = range {
            request = request.header("Range", format!("bytes={start}-{end}"));
        }
        let response = request.send().await?;
        match response.status().as_u16() {
            401 => Err(JellyfinError::Unauthorized),
            403 => Err(JellyfinError::Forbidden(
                "downloading is not allowed for this user".into(),
            )),
            404 => Err(JellyfinError::NotFound(
                "file not found on the server".into(),
            )),
            code if code >= 500 => Err(JellyfinError::ServerError {
                code,
                message: response.status().to_string(),
            }),
            _ => Ok(response),
        }
    }

    /// Attempts with increasing wait. Definitive errors (rights, not found) are not retried.
    async fn with_retries<T, F, Fut>(
        &self,
        handle: &Active,
        mut attempt_fn: F,
    ) -> Result<T, JellyfinError>
    where
        F: FnMut() -> Fut,
        Fut: std::future::Future<Output = Result<T, JellyfinError>>,
    {
        let settings = self.inner.settings();
        let mut attempt = 0;
        loop {
            if handle.halted() {
                return Err(JellyfinError::Network("stopped".into()));
            }
            match attempt_fn().await {
                Ok(value) => return Ok(value),
                Err(error) if !is_retryable(&error) => return Err(error),
                Err(error) => {
                    if attempt >= settings.retry_attempts {
                        return Err(error);
                    }
                    let delay = plan::backoff_delay_ms(attempt, settings.retry_base_delay_ms);
                    attempt += 1;
                    tokio::time::sleep(Duration::from_millis(delay)).await;
                }
            }
        }
    }

    async fn run(
        self: &Arc<Self>,
        item_id: &str,
        handle: Arc<Active>,
    ) -> Result<(), JellyfinError> {
        let row = self
            .inner
            .store()
            .get(item_id)?
            .ok_or_else(|| JellyfinError::NotFound(item_id.into()))?;
        let item: Movie = serde_json::from_str(&row.item_json)
            .map_err(|e| JellyfinError::Decode(e.to_string()))?;
        let settings = self.inner.settings();

        // 1. Size, byte ranges, ETag: a 1-byte request.
        let probe = self
            .with_retries(&handle, || async {
                let url = format!("{}/Items/{item_id}/Download", self.base_url());
                let response = self.request(&url, Some((0, 0))).await?;
                Ok(Probe::from(&response))
            })
            .await?;
        let total = probe
            .total
            .ok_or_else(|| JellyfinError::Decode("unknown file size".into()))?;
        handle.total_bytes.store(total, Ordering::Relaxed);

        // 2. Resume: we keep the progress only if the server's file has not changed.
        let final_path = self.destination(
            &item,
            &settings,
            probe.extension.as_deref().or(item.container.as_deref()),
        );
        let part_path = PathBuf::from(format!("{}.part", final_path.display()));
        let mut segments = self.inner.store().segments(item_id)?;
        let changed = row.total_bytes > 0
            && plan::file_changed(
                row.total_bytes,
                row.etag.as_deref(),
                row.last_modified.as_deref(),
                total,
                probe.etag.as_deref(),
                probe.last_modified.as_deref(),
            );
        if changed || !part_path.exists() || !probe.ranges {
            segments.clear();
            let _ = std::fs::remove_file(&part_path);
        }
        if segments.is_empty() {
            segments = if probe.ranges {
                plan::initial_segments(total, settings.connections, MIN_SEGMENT)
            } else {
                vec![Segment {
                    start: 0,
                    end: total,
                    done: 0,
                }]
            };
        }
        let already = plan::downloaded_bytes(&segments);
        handle.done_bytes.store(already, Ordering::Relaxed);

        // 3. Disk space: the remaining size plus 1 GB of margin.
        let needed = total.saturating_sub(already) + DISK_MARGIN;
        if let Some(free) = self.inner.disk.available_bytes(&final_path)
            && free < needed
        {
            return Err(JellyfinError::Storage(format!(
                "insufficient disk space: {} needed, {} free",
                human_bytes(needed),
                human_bytes(free)
            )));
        }

        // 4. `.part` file pre-allocated to the final size; each connection writes at its own place.
        if let Some(dir) = part_path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| JellyfinError::Storage(e.to_string()))?;
        }
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .read(true)
            .open(&part_path)
            .map_err(|e| JellyfinError::Storage(e.to_string()))?;
        file.set_len(total)
            .map_err(|e| JellyfinError::Storage(e.to_string()))?;
        let file = Arc::new(file);
        {
            let mut store = self.inner.store();
            store.set_remote_info(
                item_id,
                total,
                probe.etag.as_deref(),
                probe.last_modified.as_deref(),
                probe.ranges,
                &part_path.to_string_lossy(),
            )?;
            store.save_segments(item_id, &segments)?;
        }

        // 5. Parallel connections; progress is saved every 2 s.
        let busy = vec![false; segments.len()];
        let table = Arc::new(Mutex::new(SegmentTable { segments, busy }));
        let workers_done = Arc::new(AtomicBool::new(false));
        let persister = {
            let manager = self.clone();
            let table = table.clone();
            let done = workers_done.clone();
            let id = item_id.to_string();
            tokio::spawn(async move {
                while !done.load(Ordering::SeqCst) {
                    tokio::time::sleep(PERSIST_EVERY).await;
                    let snapshot = table
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .segments
                        .clone();
                    let _ = manager.inner.store().save_segments(&id, &snapshot);
                }
            })
        };
        let worker_count = if probe.ranges {
            settings.connections.max(1)
        } else {
            1
        };
        let mut workers = Vec::new();
        for _ in 0..worker_count {
            let manager = self.clone();
            let table = table.clone();
            let file = file.clone();
            let handle = handle.clone();
            let id = item_id.to_string();
            let ranges = probe.ranges;
            workers.push(tokio::spawn(async move {
                manager.worker(&id, table, file, handle, ranges).await
            }));
        }
        let mut first_error = None;
        for worker in workers {
            match worker.await {
                Ok(Ok(())) => {}
                Ok(Err(error)) => {
                    // Definitive error (rights, file not found): no point continuing with the other connections.
                    // Otherwise the others finish their part: the maximum is kept for resuming.
                    if !is_retryable(&error) {
                        handle.abort.store(true, Ordering::SeqCst);
                    }
                    first_error.get_or_insert(error);
                }
                Err(join) => {
                    first_error.get_or_insert(JellyfinError::Network(join.to_string()));
                }
            }
        }
        workers_done.store(true, Ordering::SeqCst);
        persister.abort();
        let segments = table
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .segments
            .clone();
        self.inner.store().save_segments(item_id, &segments)?;
        if let Some(error) = first_error {
            return Err(error);
        }
        if handle.stop.load(Ordering::SeqCst) {
            return Err(JellyfinError::Network("stopped".into()));
        }

        // 6. Verification and rename: the final file only exists once complete.
        if !segments.iter().all(Segment::is_complete) {
            return Err(JellyfinError::Network("incomplete download".into()));
        }
        file.sync_all()
            .map_err(|e| JellyfinError::Storage(e.to_string()))?;
        let size = std::fs::metadata(&part_path).map(|m| m.len()).unwrap_or(0);
        if size != total {
            return Err(JellyfinError::Storage(format!(
                "unexpected size ({size} instead of {total})"
            )));
        }
        std::fs::rename(&part_path, &final_path)
            .map_err(|e| JellyfinError::Storage(e.to_string()))?;

        // 7. Side files: a failure does not prevent watching the movie.
        self.fetch_assets(&item, &final_path, &settings).await;
        self.inner
            .store()
            .set_final_path(item_id, &final_path.to_string_lossy())?;
        Ok(())
    }

    async fn worker(
        &self,
        item_id: &str,
        table: Arc<Mutex<SegmentTable>>,
        file: Arc<std::fs::File>,
        handle: Arc<Active>,
        ranges: bool,
    ) -> Result<(), JellyfinError> {
        loop {
            if handle.halted() {
                return Ok(());
            }
            // A free segment, otherwise half of the biggest segment of another connection.
            let index = {
                let mut t = table.lock().unwrap_or_else(|e| e.into_inner());
                if let Some(i) =
                    (0..t.segments.len()).find(|&i| !t.busy[i] && !t.segments[i].is_complete())
                {
                    t.busy[i] = true;
                    Some(i)
                } else if ranges {
                    match plan::steal_half(&t.segments, &t.busy, MIN_STEAL) {
                        Some((victim, new)) => {
                            t.segments[victim].end = new.start;
                            t.segments.push(new);
                            t.busy.push(true);
                            Some(t.segments.len() - 1)
                        }
                        None => None,
                    }
                } else {
                    None
                }
            };
            let Some(index) = index else { return Ok(()) };
            handle.connections.fetch_add(1, Ordering::Relaxed);
            let result = self
                .fetch_segment(item_id, index, &table, &file, &handle, ranges)
                .await;
            handle.connections.fetch_sub(1, Ordering::Relaxed);
            table.lock().unwrap_or_else(|e| e.into_inner()).busy[index] = false;
            result?;
        }
    }

    async fn fetch_segment(
        &self,
        item_id: &str,
        index: usize,
        table: &Mutex<SegmentTable>,
        file: &std::fs::File,
        handle: &Active,
        ranges: bool,
    ) -> Result<(), JellyfinError> {
        let settings = self.inner.settings();
        let mut attempt = 0;
        loop {
            if handle.halted() {
                return Ok(());
            }
            let (cursor, end) = {
                let t = table.lock().unwrap_or_else(|e| e.into_inner());
                (t.segments[index].cursor(), t.segments[index].end)
            };
            if cursor >= end {
                return Ok(());
            }
            // The address is read again on every attempt: if the app went from "Home" to "Remote", we start again
            // on the new address without losing what is already written.
            let url = format!("{}/Items/{item_id}/Download", self.base_url());
            let outcome = self
                .stream_into(
                    &url,
                    index,
                    table,
                    file,
                    handle,
                    ranges.then_some((cursor, end - 1)),
                )
                .await;
            match outcome {
                Ok(progressed) => {
                    let complete = table.lock().unwrap_or_else(|e| e.into_inner()).segments[index]
                        .is_complete();
                    if complete || handle.halted() {
                        return Ok(());
                    }
                    // Stream ended too early: we start again where we are (without looping forever).
                    if progressed {
                        attempt = 0;
                    } else if attempt >= settings.retry_attempts {
                        return Err(JellyfinError::Network(
                            "stream interrupted by the server".into(),
                        ));
                    }
                }
                Err((error, progressed)) => {
                    if !is_retryable(&error) {
                        return Err(error);
                    }
                    if progressed {
                        attempt = 0;
                    }
                    if attempt >= settings.retry_attempts {
                        return Err(error);
                    }
                }
            }
            let delay = plan::backoff_delay_ms(attempt, settings.retry_base_delay_ms);
            attempt += 1;
            tokio::time::sleep(Duration::from_millis(delay)).await;
        }
    }

    /// Reads a stream and writes it at its place in the file. Returns whether bytes were written.
    async fn stream_into(
        &self,
        url: &str,
        index: usize,
        table: &Mutex<SegmentTable>,
        file: &std::fs::File,
        handle: &Active,
        range: Option<(u64, u64)>,
    ) -> Result<bool, (JellyfinError, bool)> {
        let mut progressed = false;
        let mut response = self.request(url, range).await.map_err(|e| (e, false))?;
        if range.is_some() && response.status().as_u16() != 206 {
            return Err((
                JellyfinError::Network("the server ignored the requested range".into()),
                false,
            ));
        }
        loop {
            if handle.halted() {
                return Ok(progressed);
            }
            let chunk = match response.chunk().await {
                Ok(Some(chunk)) => chunk,
                Ok(None) => return Ok(progressed),
                Err(error) => return Err((error.into(), progressed)),
            };
            // The end of the segment may have moved back (another connection took the second half).
            let (position, end) = {
                let t = table.lock().unwrap_or_else(|e| e.into_inner());
                (t.segments[index].cursor(), t.segments[index].end)
            };
            if position >= end {
                return Ok(progressed);
            }
            let take = (chunk.len() as u64).min(end - position) as usize;
            write_at(file, &chunk[..take], position)
                .map_err(|e| (JellyfinError::Storage(e.to_string()), progressed))?;
            table.lock().unwrap_or_else(|e| e.into_inner()).segments[index].done += take as u64;
            handle.done_bytes.fetch_add(take as u64, Ordering::Relaxed);
            progressed = true;
            let wait = {
                let now = self.inner.now_ms();
                self.inner
                    .bucket
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .take(take as u64, now)
            };
            if !wait.is_zero() {
                tokio::time::sleep(wait).await;
            }
            if take < chunk.len() {
                return Ok(progressed);
            }
        }
    }

    fn destination(
        &self,
        item: &Movie,
        settings: &DownloadSettings,
        extension: Option<&str>,
    ) -> PathBuf {
        let info = NamingInfo {
            server_name: &settings.server_name,
            name: &item.name,
            item_type: item.item_type.as_deref(),
            year: item.production_year,
            series_name: item.series_name.as_deref(),
            season_number: item.parent_index_number,
            episode_number: item.index_number,
            extension: extension.unwrap_or("mkv"),
        };
        let mut path = PathBuf::from(&settings.root);
        for component in plan::relative_path(&info) {
            path.push(component);
        }
        path
    }

    async fn fetch_assets(&self, item: &Movie, media: &Path, settings: &DownloadSettings) {
        let meta_dir = media
            .parent()
            .map(|p| p.join(".playfin"))
            .unwrap_or_else(|| PathBuf::from(&settings.root).join(".playfin"));
        let _ = std::fs::create_dir_all(&meta_dir);

        // Poster and background: those of the series for an episode, as on screen.
        let image_owner = match (&item.series_id, item.item_type.as_deref()) {
            (Some(series), Some("Episode")) if !series.is_empty() => series.clone(),
            _ => item.id.clone(),
        };
        for (kind, image_kind, height) in [
            ("poster", crate::ImageKind::Primary, 900),
            ("backdrop", crate::ImageKind::Backdrop, 1080),
        ] {
            let url = self
                .client
                .image_url(&image_owner, image_kind, height, None);
            let path = meta_dir.join(format!("{}-{kind}.jpg", item.id));
            if self.save_url(&url, &path).await.is_ok() {
                let _ = self
                    .inner
                    .store()
                    .set_asset(&item.id, kind, &path.to_string_lossy());
            }
        }

        // External subtitles (embedded subtitles are already in the file).
        if settings.subtitle_mode == "none" {
            return;
        }
        let Ok(subtitles) = self.client.external_subtitles(&item.id).await else {
            return;
        };
        let stem = media.with_extension("");
        for (index, subtitle) in subtitles.iter().enumerate() {
            let language = subtitle.language.clone().unwrap_or_else(|| "und".into());
            if settings.subtitle_mode == "preferred"
                && !settings.preferred_languages.is_empty()
                && !settings.preferred_languages.iter().any(|l| {
                    language
                        .to_ascii_lowercase()
                        .starts_with(&l.to_ascii_lowercase())
                })
            {
                continue;
            }
            let ext = subtitle
                .url
                .rsplit('.')
                .next()
                .filter(|e| e.len() <= 4 && e.chars().all(|c| c.is_ascii_alphanumeric()))
                .unwrap_or("srt");
            let path = PathBuf::from(format!("{}.{language}.{index}.{ext}", stem.display()));
            if self.save_url(&subtitle.url, &path).await.is_ok() {
                let _ = self.inner.store().set_asset(
                    &item.id,
                    &format!("subtitle:{language}:{index}"),
                    &path.to_string_lossy(),
                );
            }
        }
    }

    async fn save_url(&self, url: &str, path: &Path) -> Result<(), JellyfinError> {
        let response = self.request(url, None).await?;
        let bytes = response.bytes().await?;
        std::fs::write(path, &bytes).map_err(|e| JellyfinError::Storage(e.to_string()))
    }

    fn stop_active(&self, item_id: &str) {
        if let Some(active) = self
            .inner
            .active
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(item_id)
        {
            active.stop.store(true, Ordering::SeqCst);
        }
    }

    async fn wait_until_stopped(&self, item_id: &str) {
        for _ in 0..200 {
            if !self
                .inner
                .active
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .contains_key(item_id)
            {
                return;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }

    fn remove_files(&self, row: &store::DownloadRow) {
        for path in [&row.part_path, &row.final_path].into_iter().flatten() {
            let _ = std::fs::remove_file(path);
        }
        let assets = self.inner.store().assets(&row.item_id);
        if let Ok(assets) = assets {
            for (_, path) in assets {
                let _ = std::fs::remove_file(path);
            }
        }
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl DownloadManager {
    /// `db_dir`: the profile's folder in Application Support (the database is never in the Caches).
    #[uniffi::constructor]
    pub fn new(
        client: Arc<JellyfinClient>,
        db_dir: String,
        settings: DownloadSettings,
    ) -> Result<Arc<Self>, JellyfinError> {
        Ok(Arc::new(Self::build(
            client,
            &db_dir,
            settings,
            Box::new(SystemDiskSpace),
        )?))
    }

    /// At launch: what was in progress resumes (after an app stop or a crash).
    pub async fn resume_all(self: Arc<Self>) {
        // The database lock is released before the loop (an `if let` would keep it: lock taken twice).
        let rows = self.inner.store().all();
        if let Ok(rows) = rows {
            for row in rows.iter().filter(|r| r.state == "downloading") {
                let _ = self.inner.store().set_state(&row.item_id, "queued", None);
            }
        }
        self.kick();
    }

    /// Adds items (movie, episode, audiobook) to the queue. Returns the number actually added.
    pub async fn enqueue(self: Arc<Self>, items: Vec<Movie>) -> Result<u32, JellyfinError> {
        let mut added = 0;
        for item in items {
            let json =
                serde_json::to_string(&item).map_err(|e| JellyfinError::Decode(e.to_string()))?;
            let title = display_title(&item);
            if self
                .inner
                .store()
                .insert(&item.id, &title, &json, unix_now())?
            {
                added += 1;
            }
        }
        self.kick();
        Ok(added)
    }

    /// All the episodes of a series (or of a single season) into the queue.
    pub async fn enqueue_series(
        self: Arc<Self>,
        series_id: String,
        season_id: Option<String>,
    ) -> Result<u32, JellyfinError> {
        let mut episodes = self.client.series_episodes(series_id).await?;
        if let Some(season) = season_id {
            episodes.retain(|e| e.season_id.as_deref() == Some(season.as_str()));
        }
        self.enqueue(episodes).await
    }

    pub fn snapshot(&self) -> Vec<DownloadInfo> {
        // Read 4 times per second by the app: without the item records, and all the segments in one query.
        let (rows, written) = {
            let store = self.inner.store();
            (
                store.all_without_items().unwrap_or_default(),
                store.downloaded_bytes_by_item().unwrap_or_default(),
            )
        };
        rows.iter().map(|row| self.info(row, &written)).collect()
    }

    pub async fn pause(self: Arc<Self>, item_id: String) {
        if !matches!(self.inner.store().pause(&item_id), Ok(true)) {
            return; // already finished, failed or paused
        }
        self.stop_active(&item_id);
        self.wait_until_stopped(&item_id).await;
        self.kick();
    }

    pub async fn resume(self: Arc<Self>, item_id: String) {
        let _ = self.inner.store().set_state(&item_id, "queued", None);
        self.kick();
    }

    /// New attempt after a failure (the progress already made is kept).
    pub async fn retry(self: Arc<Self>, item_id: String) {
        self.resume(item_id).await;
    }

    /// Cancels (or deletes): stops, erases the files and removes the item from the queue.
    pub async fn remove(self: Arc<Self>, item_id: String) {
        self.stop_active(&item_id);
        self.wait_until_stopped(&item_id).await;
        let row = self.inner.store().get(&item_id);
        if let Ok(Some(row)) = row {
            self.remove_files(&row);
        }
        let _ = self.inner.store().delete(&item_id);
        self.kick();
    }

    pub async fn move_to(self: Arc<Self>, item_id: String, index: u32) {
        let _ = self.inner.store().move_to(&item_id, index as usize);
        self.kick();
    }

    pub async fn update_settings(self: Arc<Self>, settings: DownloadSettings) {
        let settings = settings.sanitized();
        let rate = settings.bandwidth_limit_kbps as u64 * 1024;
        self.inner
            .bucket
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .set_rate(rate);
        let connections_changed = {
            let mut current = self
                .inner
                .settings
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            let changed = current.connections != settings.connections;
            *current = settings;
            changed
        };
        // New number of connections: downloads in progress restart right away with this number
        // (the progress is kept), instead of applying only to the next ones.
        if connections_changed {
            let active: Vec<String> = self
                .inner
                .active
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .keys()
                .cloned()
                .collect();
            for id in active {
                self.stop_active(&id);
                self.wait_until_stopped(&id).await;
                let _ = self.inner.store().set_state(&id, "queued", None);
            }
        }
        self.kick();
    }

    /// Local file of a downloaded item (playback from disk, even if the server answers).
    pub fn local_file(&self, item_id: String) -> Option<String> {
        let row = self.inner.store().get(&item_id).ok()??;
        let path = row.final_path.filter(|_| row.state == "completed")?;
        Path::new(&path).exists().then_some(path)
    }

    /// Saved image ("poster" or "backdrop") of a downloaded item.
    pub fn local_asset(&self, item_id: String, kind: String) -> Option<String> {
        self.inner
            .store()
            .assets(&item_id)
            .ok()?
            .into_iter()
            .find(|(k, _)| *k == kind)
            .map(|(_, path)| path)
            .filter(|path| Path::new(path).exists())
    }

    /// Subtitles saved next to a downloaded file: (language, path).
    pub fn local_subtitles(&self, item_id: String) -> Vec<crate::ExternalSubtitle> {
        self.inner
            .store()
            .assets(&item_id)
            .unwrap_or_default()
            .into_iter()
            .filter_map(|(kind, path)| {
                let language = kind
                    .strip_prefix("subtitle:")?
                    .split(':')
                    .next()?
                    .to_string();
                Path::new(&path).exists().then(|| crate::ExternalSubtitle {
                    url: path,
                    title: language.clone(),
                    language: Some(language),
                })
            })
            .collect()
    }

    /// Downloaded and complete items, to browse without a server.
    pub fn downloaded_items(&self) -> Vec<Movie> {
        self.inner
            .store()
            .all()
            .unwrap_or_default()
            .into_iter()
            .filter(|row| row.state == "completed")
            .filter_map(|row| serde_json::from_str(&row.item_json).ok())
            .collect()
    }

    /// Space occupied by the downloaded files (bytes).
    pub fn used_bytes(&self) -> u64 {
        self.inner
            .store()
            .all_without_items()
            .unwrap_or_default()
            .iter()
            .filter(|row| row.state == "completed")
            .map(|row| row.total_bytes)
            .sum()
    }

    // MARK: playback reports made offline

    /// Keeps a report (start, progress, stop) made when the server was not answering.
    pub fn queue_report(&self, item_id: String, kind: String, position_ticks: i64) {
        let _ = self
            .inner
            .store()
            .queue_report(&item_id, &kind, position_ticks, unix_now());
    }

    pub fn pending_report_count(&self) -> u32 {
        self.inner
            .store()
            .reports()
            .map(|r| r.len() as u32)
            .unwrap_or(0)
    }

    /// Sends the pending reports, in order, as soon as the server answers. Conflict rule: if the
    /// server shows that the item was watched elsewhere more recently than our report, we keep the server.
    /// Returns the number of items updated on the server.
    pub async fn flush_reports(self: Arc<Self>) -> Result<u32, JellyfinError> {
        let reports = self.inner.store().reports()?;
        let mut latest: Vec<store::ReportRow> = Vec::new();
        for report in reports {
            match latest.iter_mut().find(|r| r.item_id == report.item_id) {
                Some(existing) => *existing = report,
                None => latest.push(report),
            }
        }
        let mut sent = 0;
        for report in latest {
            let server = self.client.user_data_state(&report.item_id).await?;
            if offline_report_wins(report.created_at, server.last_played_unix) {
                let played = server.run_time_ticks.is_some_and(|total| {
                    total > 0 && report.position_ticks as f64 >= total as f64 * 0.9
                });
                self.client
                    .save_user_data(
                        &report.item_id,
                        report.position_ticks,
                        played,
                        report.created_at,
                    )
                    .await?;
                sent += 1;
            }
            self.inner
                .store()
                .remove_reports_for(&report.item_id, report.id)?;
        }
        Ok(sent)
    }
}

/// Conflict rule for offline reports: our report wins unless the server has a more recent playback.
pub fn offline_report_wins(report_created_at: i64, server_last_played: Option<i64>) -> bool {
    server_last_played.is_none_or(|server| server <= report_created_at)
}

struct SegmentTable {
    segments: Vec<Segment>,
    busy: Vec<bool>,
}

struct Probe {
    total: Option<u64>,
    ranges: bool,
    etag: Option<String>,
    last_modified: Option<String>,
    extension: Option<String>,
}

impl Probe {
    fn from(response: &reqwest::Response) -> Self {
        let header = |name: &str| {
            response
                .headers()
                .get(name)
                .and_then(|v| v.to_str().ok())
                .map(str::to_string)
        };
        let ranges = response.status().as_u16() == 206;
        let total = if ranges {
            header("content-range")
                .and_then(|v| v.rsplit('/').next().and_then(|t| t.trim().parse().ok()))
        } else {
            response.content_length()
        };
        Self {
            total,
            ranges,
            etag: header("etag"),
            last_modified: header("last-modified"),
            extension: header("content-disposition")
                .and_then(|v| plan::extension_from_disposition(&v)),
        }
    }
}

fn is_retryable(error: &JellyfinError) -> bool {
    matches!(
        error,
        JellyfinError::Network(_)
            | JellyfinError::ServerUnreachable(_)
            | JellyfinError::ServerError { .. }
    )
}

fn describe(error: &JellyfinError) -> String {
    match error {
        JellyfinError::Forbidden(_) => {
            "Download refused: the server administrator does not allow it for this account.".into()
        }
        JellyfinError::Storage(message) => format!("Storage problem: {message}"),
        JellyfinError::NotFound(_) => "The file no longer exists on the server.".into(),
        JellyfinError::Unauthorized => "Session expired: sign in again then retry.".into(),
        other => format!("Download failed: {other}"),
    }
}

fn display_title(item: &Movie) -> String {
    match (
        &item.series_name,
        item.parent_index_number,
        item.index_number,
    ) {
        (Some(series), Some(season), Some(episode)) => {
            format!("{series} · S{season}:E{episode} · {}", item.name)
        }
        (Some(series), _, _) => format!("{series} · {}", item.name),
        _ => item.name.clone(),
    }
}

fn human_bytes(bytes: u64) -> String {
    let gib = bytes as f64 / (1024.0 * 1024.0 * 1024.0);
    if gib >= 1.0 {
        format!("{gib:.1} Go")
    } else {
        format!("{:.0} Mo", bytes as f64 / (1024.0 * 1024.0))
    }
}

#[cfg(unix)]
fn write_at(file: &std::fs::File, data: &[u8], offset: u64) -> std::io::Result<()> {
    use std::os::unix::fs::FileExt;
    file.write_all_at(data, offset)
}

#[cfg(windows)]
fn write_at(file: &std::fs::File, mut data: &[u8], mut offset: u64) -> std::io::Result<()> {
    use std::os::windows::fs::FileExt;
    while !data.is_empty() {
        let written = file.seek_write(data, offset)?;
        data = &data[written..];
        offset += written as u64;
    }
    Ok(())
}

#[cfg(test)]
mod tests;
