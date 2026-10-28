//! Pure logic of the downloader: splitting into segments, one connection taking over a segment from another,
//! file paths, check that a file is unchanged. No I/O here (testable anywhere).

/// Minimum size of a segment at the start (8 MiB).
pub const MIN_SEGMENT: u64 = 8 * 1024 * 1024;
/// Below this remaining size, a free connection does not take half of another's segment.
pub const MIN_STEAL: u64 = 2 * 1024 * 1024;

/// A piece of the file: from `start` (inclusive) to `end` (exclusive); `done` bytes are already written from `start`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Segment {
    pub start: u64,
    pub end: u64,
    pub done: u64,
}

impl Segment {
    pub fn cursor(&self) -> u64 {
        self.start + self.done
    }

    pub fn remaining(&self) -> u64 {
        self.end.saturating_sub(self.cursor())
    }

    pub fn is_complete(&self) -> bool {
        self.cursor() >= self.end
    }
}

/// Splits `total` bytes into at most `connections` segments of at least `MIN_SEGMENT` (except a small file).
pub fn initial_segments(total: u64, connections: u32, min_segment: u64) -> Vec<Segment> {
    if total == 0 {
        return vec![Segment {
            start: 0,
            end: 0,
            done: 0,
        }];
    }
    let by_size = (total / min_segment.max(1)).max(1);
    let count = (connections.max(1) as u64).min(by_size);
    let base = total / count;
    let mut segments = Vec::with_capacity(count as usize);
    let mut start = 0;
    for index in 0..count {
        let end = if index + 1 == count {
            total
        } else {
            start + base
        };
        segments.push(Segment {
            start,
            end,
            done: 0,
        });
        start = end;
    }
    segments
}

/// A free connection takes over half of what remains of the biggest segment still in progress.
/// Returns the index of the cut segment and the new segment, or `None` if nothing is big enough.
/// `busy` indicates the segments already taken by a connection (only those can be shared).
pub fn steal_half(segments: &[Segment], busy: &[bool], min_steal: u64) -> Option<(usize, Segment)> {
    let (index, victim) = segments
        .iter()
        .enumerate()
        .filter(|(i, s)| busy.get(*i).copied().unwrap_or(false) && !s.is_complete())
        .max_by_key(|(_, s)| s.remaining())?;
    let remaining = victim.remaining();
    if remaining < min_steal * 2 {
        return None;
    }
    let split = victim.cursor() + remaining / 2;
    Some((
        index,
        Segment {
            start: split,
            end: victim.end,
            done: 0,
        },
    ))
}

/// Bytes already written across all the segments.
pub fn downloaded_bytes(segments: &[Segment]) -> u64 {
    segments.iter().map(|s| s.done.min(s.end - s.start)).sum()
}

/// Has the server's file changed since the download started? (size, ETag, Last-Modified)
pub fn file_changed(
    old_size: u64,
    old_etag: Option<&str>,
    old_modified: Option<&str>,
    new_size: u64,
    new_etag: Option<&str>,
    new_modified: Option<&str>,
) -> bool {
    if old_size != new_size {
        return true;
    }
    if let (Some(a), Some(b)) = (old_etag, new_etag) {
        return a != b;
    }
    if let (Some(a), Some(b)) = (old_modified, new_modified) {
        return a != b;
    }
    false
}

/// File or folder name without characters forbidden on macOS, Windows or Linux.
pub fn sanitize(component: &str) -> String {
    let cleaned: String = component
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect();
    let trimmed = cleaned.trim().trim_matches('.').trim();
    if trimmed.is_empty() {
        "Untitled".into()
    } else {
        trimmed.chars().take(120).collect()
    }
}

/// What must be known about an item to file it away.
pub struct NamingInfo<'a> {
    pub server_name: &'a str,
    pub name: &'a str,
    pub item_type: Option<&'a str>,
    pub year: Option<i32>,
    pub series_name: Option<&'a str>,
    pub season_number: Option<i32>,
    pub episode_number: Option<i32>,
    pub extension: &'a str,
}

/// Relative path under the downloads folder:
/// `<Server>/Movies/<Title (Year)>.<ext>` or `<Server>/<Series>/Season N/<Series - S01E03 - Title>.<ext>`.
pub fn relative_path(info: &NamingInfo) -> Vec<String> {
    let server = sanitize(info.server_name);
    let ext = {
        let e: String = info
            .extension
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .take(8)
            .collect();
        if e.is_empty() {
            "mkv".to_string()
        } else {
            e.to_ascii_lowercase()
        }
    };
    match (info.item_type, info.series_name) {
        (Some("Episode"), Some(series)) => {
            let season = info.season_number.unwrap_or(0);
            let episode = info.episode_number.unwrap_or(0);
            vec![
                server,
                sanitize(series),
                format!("Season {season}"),
                format!(
                    "{} - S{season:02}E{episode:02} - {}.{ext}",
                    sanitize(series),
                    sanitize(info.name)
                ),
            ]
        }
        (Some("AudioBook") | Some("Audio"), _) => vec![
            server,
            "Audiobooks".into(),
            format!("{}.{ext}", sanitize(info.name)),
        ],
        _ => {
            let title = match info.year {
                Some(year) => format!("{} ({year})", sanitize(info.name)),
                None => sanitize(info.name),
            };
            vec![server, "Movies".into(), format!("{title}.{ext}")]
        }
    }
}

/// Extension announced by the `Content-Disposition` header (`attachment; filename="movie.mkv"`).
pub fn extension_from_disposition(header: &str) -> Option<String> {
    let lower = header.to_ascii_lowercase();
    let index = lower.find("filename")?;
    let value = header[index..]
        .split('=')
        .nth(1)?
        .trim()
        .trim_matches(|c| c == '"' || c == '\'' || c == ';');
    let ext = value.rsplit('.').next()?;
    let clean: String = ext.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    (!clean.is_empty() && clean.len() <= 8 && value.contains('.'))
        .then(|| clean.to_ascii_lowercase())
}

/// Delay before a new attempt: 1×, 2×, 4×… the base, capped at 30 s.
pub fn backoff_delay_ms(attempt: u32, base_ms: u64) -> u64 {
    let factor = 1u64 << attempt.min(10);
    (base_ms.saturating_mul(factor)).min(30_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIB: u64 = 1024 * 1024;

    #[test]
    fn small_files_get_one_segment_and_large_ones_are_split_evenly() {
        let one = initial_segments(5 * MIB, 4, MIN_SEGMENT);
        assert_eq!(
            one,
            vec![Segment {
                start: 0,
                end: 5 * MIB,
                done: 0
            }]
        );

        let four = initial_segments(100 * MIB, 4, MIN_SEGMENT);
        assert_eq!(four.len(), 4);
        assert_eq!(four[0].start, 0);
        assert_eq!(four.last().unwrap().end, 100 * MIB);
        for pair in four.windows(2) {
            assert_eq!(
                pair[0].end, pair[1].start,
                "contiguous segments, without gap or overlap"
            );
        }

        // 20 MiB: only 2 segments of 8 MiB minimum, even with 16 connections.
        assert_eq!(initial_segments(20 * MIB, 16, MIN_SEGMENT).len(), 2);
        assert_eq!(initial_segments(0, 4, MIN_SEGMENT).len(), 1);
    }

    #[test]
    fn a_free_connection_takes_half_of_the_largest_busy_segment() {
        let segments = vec![
            Segment {
                start: 0,
                end: 40 * MIB,
                done: 39 * MIB,
            },
            Segment {
                start: 40 * MIB,
                end: 80 * MIB,
                done: 10 * MIB,
            },
        ];
        let (index, new) = steal_half(&segments, &[true, true], MIN_STEAL).unwrap();
        assert_eq!(index, 1);
        assert_eq!(new.start, 50 * MIB + 15 * MIB);
        assert_eq!(new.end, 80 * MIB);

        // Nothing big enough, or segment not yet taken: we do not cut.
        let tiny = vec![Segment {
            start: 0,
            end: 3 * MIB,
            done: 0,
        }];
        assert!(steal_half(&tiny, &[true], MIN_STEAL).is_none());
        assert!(steal_half(&segments, &[false, false], MIN_STEAL).is_none());
    }

    #[test]
    fn progress_and_change_detection() {
        let segments = vec![
            Segment {
                start: 0,
                end: 10,
                done: 10,
            },
            Segment {
                start: 10,
                end: 20,
                done: 4,
            },
        ];
        assert_eq!(downloaded_bytes(&segments), 14);
        assert!(segments[0].is_complete());
        assert_eq!(segments[1].remaining(), 6);

        assert!(!file_changed(100, Some("a"), None, 100, Some("a"), None));
        assert!(
            file_changed(100, Some("a"), None, 100, Some("b"), None),
            "different ETag"
        );
        assert!(
            file_changed(100, None, None, 101, None, None),
            "different size"
        );
        assert!(file_changed(
            100,
            None,
            Some("tuesday"),
            100,
            None,
            Some("wednesday")
        ));
        assert!(
            !file_changed(100, None, None, 100, None, None),
            "nothing to compare: same size"
        );
    }

    #[test]
    fn paths_follow_the_layout_and_are_safe() {
        let movie = NamingInfo {
            server_name: "Living room",
            name: "Alien: the 8th passenger",
            item_type: Some("Movie"),
            year: Some(1979),
            series_name: None,
            season_number: None,
            episode_number: None,
            extension: "MKV",
        };
        assert_eq!(
            relative_path(&movie),
            [
                "Living room",
                "Movies",
                "Alien_ the 8th passenger (1979).mkv"
            ]
        );

        let episode = NamingInfo {
            server_name: "Living room",
            name: "Pilot",
            item_type: Some("Episode"),
            year: None,
            series_name: Some("Lost"),
            season_number: Some(1),
            episode_number: Some(3),
            extension: "mp4",
        };
        assert_eq!(
            relative_path(&episode),
            [
                "Living room",
                "Lost",
                "Season 1",
                "Lost - S01E03 - Pilot.mp4"
            ]
        );
        assert_eq!(sanitize("../../etc"), "_.._etc");
        assert_eq!(sanitize("   "), "Untitled");
    }

    #[test]
    fn extension_and_backoff() {
        assert_eq!(
            extension_from_disposition("attachment; filename=\"Film.MKV\""),
            Some("mkv".into())
        );
        assert_eq!(
            extension_from_disposition("attachment; filename=film.mp4;"),
            Some("mp4".into())
        );
        assert_eq!(extension_from_disposition("inline"), None);
        assert_eq!(backoff_delay_ms(0, 1000), 1000);
        assert_eq!(backoff_delay_ms(3, 1000), 8000);
        assert_eq!(backoff_delay_ms(20, 1000), 30_000);
    }
}
