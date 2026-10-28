//! Downloads database of a profile (`downloads.sqlite`, in Application Support: emptying the cache never touches
//! it). It keeps the queue, the progress of each segment, the files obtained and the playback reports
//! made offline.

use super::plan::Segment;
use crate::JellyfinError;
use rusqlite::{Connection, OptionalExtension, params};
use std::path::Path;

const SCHEMA_VERSION: i64 = 1;

fn storage(err: rusqlite::Error) -> JellyfinError {
    JellyfinError::Storage(err.to_string())
}

#[derive(Debug, Clone, PartialEq)]
pub struct DownloadRow {
    pub item_id: String,
    pub title: String,
    pub item_json: String,
    pub state: String,
    pub position: i64,
    pub total_bytes: u64,
    pub etag: Option<String>,
    pub last_modified: Option<String>,
    pub ranges: bool,
    pub part_path: Option<String>,
    pub final_path: Option<String>,
    pub error: Option<String>,
    pub created_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReportRow {
    pub id: i64,
    pub item_id: String,
    pub kind: String,
    pub position_ticks: i64,
    pub created_at: i64,
}

pub struct DownloadStore {
    conn: Connection,
}

impl DownloadStore {
    pub fn open(path: &Path) -> Result<Self, JellyfinError> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| JellyfinError::Storage(e.to_string()))?;
        }
        Self::migrate(Connection::open(path).map_err(storage)?)
    }

    #[cfg(test)]
    pub fn open_in_memory() -> Result<Self, JellyfinError> {
        Self::migrate(Connection::open_in_memory().map_err(storage)?)
    }

    fn migrate(conn: Connection) -> Result<Self, JellyfinError> {
        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(storage)?;
        if version > SCHEMA_VERSION {
            return Err(JellyfinError::Storage(format!(
                "downloads database created by a more recent version (schema {version})"
            )));
        }
        if version < 1 {
            conn.execute_batch(
                "BEGIN;
                 CREATE TABLE downloads (
                     item_id TEXT PRIMARY KEY,
                     title TEXT NOT NULL,
                     item_json TEXT NOT NULL,
                     state TEXT NOT NULL,
                     position INTEGER NOT NULL,
                     total_bytes INTEGER NOT NULL DEFAULT 0,
                     etag TEXT,
                     last_modified TEXT,
                     ranges INTEGER NOT NULL DEFAULT 1,
                     part_path TEXT,
                     final_path TEXT,
                     error TEXT,
                     created_at INTEGER NOT NULL
                 );
                 CREATE TABLE segments (
                     item_id TEXT NOT NULL,
                     idx INTEGER NOT NULL,
                     start INTEGER NOT NULL,
                     end INTEGER NOT NULL,
                     done INTEGER NOT NULL,
                     PRIMARY KEY (item_id, idx)
                 );
                 CREATE TABLE assets (
                     item_id TEXT NOT NULL,
                     kind TEXT NOT NULL,
                     path TEXT NOT NULL,
                     PRIMARY KEY (item_id, kind)
                 );
                 CREATE TABLE reports (
                     id INTEGER PRIMARY KEY AUTOINCREMENT,
                     item_id TEXT NOT NULL,
                     kind TEXT NOT NULL,
                     position_ticks INTEGER NOT NULL,
                     created_at INTEGER NOT NULL
                 );
                 PRAGMA user_version = 1;
                 COMMIT;",
            )
            .map_err(storage)?;
        }
        // Frequent writes (progress every 2 s): the WAL journal makes them cheap.
        let _ = conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;");
        Ok(Self { conn })
    }

    fn row(r: &rusqlite::Row) -> rusqlite::Result<DownloadRow> {
        Ok(DownloadRow {
            item_id: r.get(0)?,
            title: r.get(1)?,
            item_json: r.get(2)?,
            state: r.get(3)?,
            position: r.get(4)?,
            total_bytes: r.get::<_, i64>(5)? as u64,
            etag: r.get(6)?,
            last_modified: r.get(7)?,
            ranges: r.get::<_, i64>(8)? != 0,
            part_path: r.get(9)?,
            final_path: r.get(10)?,
            error: r.get(11)?,
            created_at: r.get(12)?,
        })
    }

    const COLUMNS: &'static str = "item_id, title, item_json, state, position, total_bytes, etag, last_modified, ranges, part_path, final_path, error, created_at";

    pub fn all(&self) -> Result<Vec<DownloadRow>, JellyfinError> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "SELECT {} FROM downloads ORDER BY position, created_at",
                Self::COLUMNS
            ))
            .map_err(storage)?;
        let rows = stmt.query_map([], Self::row).map_err(storage)?;
        rows.collect::<Result<_, _>>().map_err(storage)
    }

    pub fn get(&self, item_id: &str) -> Result<Option<DownloadRow>, JellyfinError> {
        self.conn
            .query_row(
                &format!("SELECT {} FROM downloads WHERE item_id = ?1", Self::COLUMNS),
                [item_id],
                Self::row,
            )
            .optional()
            .map_err(storage)
    }

    /// Adds an item at the end of the queue. No effect if it is already there (we do not download twice).
    pub fn insert(
        &self,
        item_id: &str,
        title: &str,
        item_json: &str,
        now: i64,
    ) -> Result<bool, JellyfinError> {
        let next: i64 = self
            .conn
            .query_row(
                "SELECT COALESCE(MAX(position), -1) + 1 FROM downloads",
                [],
                |r| r.get(0),
            )
            .map_err(storage)?;
        let changed = self
            .conn
            .execute(
                "INSERT OR IGNORE INTO downloads (item_id, title, item_json, state, position, created_at)
                 VALUES (?1, ?2, ?3, 'queued', ?4, ?5)",
                params![item_id, title, item_json, next, now],
            )
            .map_err(storage)?;
        Ok(changed > 0)
    }

    pub fn set_state(
        &self,
        item_id: &str,
        state: &str,
        error: Option<&str>,
    ) -> Result<(), JellyfinError> {
        self.conn
            .execute(
                "UPDATE downloads SET state = ?2, error = ?3 WHERE item_id = ?1",
                params![item_id, state, error],
            )
            .map_err(storage)?;
        Ok(())
    }

    /// Moves an item from "waiting" to "in progress", only if it is still waiting (a pause
    /// arriving in the meantime wins). True if the item was taken.
    pub fn claim(&self, item_id: &str) -> Result<bool, JellyfinError> {
        let changed = self
            .conn
            .execute(
                "UPDATE downloads SET state = 'downloading', error = NULL WHERE item_id = ?1 AND state = 'queued'",
                [item_id],
            )
            .map_err(storage)?;
        Ok(changed > 0)
    }

    /// Pauses a waiting or in-progress item (no effect on a finished or failed item).
    pub fn pause(&self, item_id: &str) -> Result<bool, JellyfinError> {
        let changed = self
            .conn
            .execute(
                "UPDATE downloads SET state = 'paused' WHERE item_id = ?1 AND state IN ('queued', 'downloading')",
                [item_id],
            )
            .map_err(storage)?;
        Ok(changed > 0)
    }

    pub fn set_remote_info(
        &self,
        item_id: &str,
        total: u64,
        etag: Option<&str>,
        last_modified: Option<&str>,
        ranges: bool,
        part_path: &str,
    ) -> Result<(), JellyfinError> {
        self.conn
            .execute(
                "UPDATE downloads SET total_bytes = ?2, etag = ?3, last_modified = ?4, ranges = ?5, part_path = ?6
                 WHERE item_id = ?1",
                params![item_id, total as i64, etag, last_modified, ranges as i64, part_path],
            )
            .map_err(storage)?;
        Ok(())
    }

    pub fn set_final_path(&self, item_id: &str, path: &str) -> Result<(), JellyfinError> {
        self.conn
            .execute(
                "UPDATE downloads SET final_path = ?2, state = 'completed', error = NULL WHERE item_id = ?1",
                params![item_id, path],
            )
            .map_err(storage)?;
        Ok(())
    }

    pub fn segments(&self, item_id: &str) -> Result<Vec<Segment>, JellyfinError> {
        let mut stmt = self
            .conn
            .prepare("SELECT start, end, done FROM segments WHERE item_id = ?1 ORDER BY start")
            .map_err(storage)?;
        let rows = stmt
            .query_map([item_id], |r| {
                Ok(Segment {
                    start: r.get::<_, i64>(0)? as u64,
                    end: r.get::<_, i64>(1)? as u64,
                    done: r.get::<_, i64>(2)? as u64,
                })
            })
            .map_err(storage)?;
        rows.collect::<Result<_, _>>().map_err(storage)
    }

    /// Replaces the segment progress (a transaction: never a half-written state).
    pub fn save_segments(
        &mut self,
        item_id: &str,
        segments: &[Segment],
    ) -> Result<(), JellyfinError> {
        let tx = self.conn.transaction().map_err(storage)?;
        tx.execute("DELETE FROM segments WHERE item_id = ?1", [item_id])
            .map_err(storage)?;
        for (idx, s) in segments.iter().enumerate() {
            tx.execute(
                "INSERT INTO segments (item_id, idx, start, end, done) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    item_id,
                    idx as i64,
                    s.start as i64,
                    s.end as i64,
                    s.done as i64
                ],
            )
            .map_err(storage)?;
        }
        tx.commit().map_err(storage)
    }

    pub fn set_asset(&self, item_id: &str, kind: &str, path: &str) -> Result<(), JellyfinError> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO assets (item_id, kind, path) VALUES (?1, ?2, ?3)",
                params![item_id, kind, path],
            )
            .map_err(storage)?;
        Ok(())
    }

    pub fn assets(&self, item_id: &str) -> Result<Vec<(String, String)>, JellyfinError> {
        let mut stmt = self
            .conn
            .prepare("SELECT kind, path FROM assets WHERE item_id = ?1 ORDER BY kind")
            .map_err(storage)?;
        let rows = stmt
            .query_map([item_id], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(storage)?;
        rows.collect::<Result<_, _>>().map_err(storage)
    }

    /// Deletes a download and everything attached to it (segments, side files).
    pub fn delete(&mut self, item_id: &str) -> Result<(), JellyfinError> {
        let tx = self.conn.transaction().map_err(storage)?;
        for table in ["downloads", "segments", "assets"] {
            tx.execute(
                &format!("DELETE FROM {table} WHERE item_id = ?1"),
                [item_id],
            )
            .map_err(storage)?;
        }
        tx.commit().map_err(storage)
    }

    /// Moves an item to `new_index` in the queue and renumbers the positions.
    pub fn move_to(&mut self, item_id: &str, new_index: usize) -> Result<(), JellyfinError> {
        let mut ids: Vec<String> = self.all()?.into_iter().map(|r| r.item_id).collect();
        let Some(current) = ids.iter().position(|id| id == item_id) else {
            return Ok(());
        };
        let id = ids.remove(current);
        ids.insert(new_index.min(ids.len()), id);
        let tx = self.conn.transaction().map_err(storage)?;
        for (position, id) in ids.iter().enumerate() {
            tx.execute(
                "UPDATE downloads SET position = ?2 WHERE item_id = ?1",
                params![id, position as i64],
            )
            .map_err(storage)?;
        }
        tx.commit().map_err(storage)
    }

    pub fn queue_report(
        &self,
        item_id: &str,
        kind: &str,
        ticks: i64,
        now: i64,
    ) -> Result<(), JellyfinError> {
        self.conn
            .execute(
                "INSERT INTO reports (item_id, kind, position_ticks, created_at) VALUES (?1, ?2, ?3, ?4)",
                params![item_id, kind, ticks, now],
            )
            .map_err(storage)?;
        Ok(())
    }

    pub fn reports(&self) -> Result<Vec<ReportRow>, JellyfinError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, item_id, kind, position_ticks, created_at FROM reports ORDER BY id",
            )
            .map_err(storage)?;
        let rows = stmt
            .query_map([], |r| {
                Ok(ReportRow {
                    id: r.get(0)?,
                    item_id: r.get(1)?,
                    kind: r.get(2)?,
                    position_ticks: r.get(3)?,
                    created_at: r.get(4)?,
                })
            })
            .map_err(storage)?;
        rows.collect::<Result<_, _>>().map_err(storage)
    }

    pub fn remove_reports_for(&self, item_id: &str, up_to_id: i64) -> Result<(), JellyfinError> {
        self.conn
            .execute(
                "DELETE FROM reports WHERE item_id = ?1 AND id <= ?2",
                params![item_id, up_to_id],
            )
            .map_err(storage)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queue_order_insert_once_and_reorder() {
        let mut store = DownloadStore::open_in_memory().unwrap();
        assert!(store.insert("a", "A", "{}", 1).unwrap());
        assert!(store.insert("b", "B", "{}", 2).unwrap());
        assert!(store.insert("c", "C", "{}", 3).unwrap());
        assert!(
            !store.insert("a", "A", "{}", 4).unwrap(),
            "not the same item twice"
        );
        store.move_to("c", 0).unwrap();
        let ids: Vec<_> = store
            .all()
            .unwrap()
            .into_iter()
            .map(|r| r.item_id)
            .collect();
        assert_eq!(ids, ["c", "a", "b"]);
    }

    #[test]
    fn segments_and_assets_survive_and_are_deleted_together() {
        let dir = std::env::temp_dir().join(format!("jn_dl_store_{}", uuid::Uuid::new_v4()));
        let path = dir.join("downloads.sqlite");
        {
            let mut store = DownloadStore::open(&path).unwrap();
            store.insert("a", "A", "{}", 1).unwrap();
            store
                .save_segments(
                    "a",
                    &[
                        Segment {
                            start: 0,
                            end: 10,
                            done: 4,
                        },
                        Segment {
                            start: 10,
                            end: 20,
                            done: 0,
                        },
                    ],
                )
                .unwrap();
            store.set_asset("a", "poster", "/x/poster.jpg").unwrap();
            store
                .set_remote_info("a", 20, Some("e1"), None, true, "/x/a.part")
                .unwrap();
        }
        // Reopening (as after a restart): the progress is there.
        let mut store = DownloadStore::open(&path).unwrap();
        assert_eq!(store.segments("a").unwrap()[0].done, 4);
        let row = store.get("a").unwrap().unwrap();
        assert_eq!((row.total_bytes, row.etag.as_deref()), (20, Some("e1")));
        assert_eq!(store.assets("a").unwrap().len(), 1);
        store.delete("a").unwrap();
        assert!(store.get("a").unwrap().is_none());
        assert!(store.segments("a").unwrap().is_empty());
        assert!(store.assets("a").unwrap().is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn offline_reports_are_kept_in_order() {
        let store = DownloadStore::open_in_memory().unwrap();
        store.queue_report("a", "progress", 10, 1).unwrap();
        store.queue_report("a", "stopped", 20, 2).unwrap();
        store.queue_report("b", "stopped", 5, 3).unwrap();
        let all = store.reports().unwrap();
        assert_eq!(
            all.iter().map(|r| r.position_ticks).collect::<Vec<_>>(),
            [10, 20, 5]
        );
        store.remove_reports_for("a", all[1].id).unwrap();
        assert_eq!(store.reports().unwrap().len(), 1);
    }
}
