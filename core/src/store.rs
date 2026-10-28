//! SQLite database of a profile: libraries, items and pending playback reports.
//!
//! One database per profile: no data is shared between two profiles. The client keeps in it the
//! libraries and their items; the pending playback reports will be used in Phase 3.

use crate::JellyfinError;
use rusqlite::{Connection, params};
use std::path::Path;

/// Current schema version. Each future migration increments this number.
pub const SCHEMA_VERSION: i64 = 3;

/// Playback report kept until the server could receive it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingReport {
    pub id: i64,
    pub item_id: String,
    /// "start", "progress" or "stopped".
    pub kind: String,
    pub position_ticks: i64,
    pub created_at: i64,
}

pub struct ProfileStore {
    conn: Connection,
}

fn storage(err: rusqlite::Error) -> JellyfinError {
    JellyfinError::Storage(err.to_string())
}

impl ProfileStore {
    /// Opens (or creates) the profile database and applies the migrations.
    pub fn open(path: &Path) -> Result<Self, JellyfinError> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| JellyfinError::Storage(e.to_string()))?;
        }
        let conn = Connection::open(path).map_err(storage)?;
        Self::migrate(conn)
    }

    /// In-memory database, for the tests.
    pub fn open_in_memory() -> Result<Self, JellyfinError> {
        Self::migrate(Connection::open_in_memory().map_err(storage)?)
    }

    fn migrate(conn: Connection) -> Result<Self, JellyfinError> {
        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(storage)?;
        if version > SCHEMA_VERSION {
            return Err(JellyfinError::Storage(format!(
                "database created by a more recent version (schema {version})"
            )));
        }
        if version < 1 {
            conn.execute_batch(
                "BEGIN;
                 CREATE TABLE libraries (
                     id TEXT PRIMARY KEY,
                     name TEXT NOT NULL,
                     collection_type TEXT
                 );
                 CREATE TABLE items (
                     id TEXT PRIMARY KEY,
                     library_id TEXT NOT NULL,
                     name TEXT NOT NULL,
                     json TEXT NOT NULL,
                     updated_at INTEGER NOT NULL
                 );
                 CREATE INDEX items_by_library ON items(library_id, name);
                 CREATE TABLE playback_reports (
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
        if version < 2 {
            // v2: full JSON of the libraries and original order of the items.
            conn.execute_batch(
                "BEGIN;
                 ALTER TABLE libraries ADD COLUMN json TEXT;
                 ALTER TABLE items ADD COLUMN position INTEGER NOT NULL DEFAULT 0;
                 PRAGMA user_version = 2;
                 COMMIT;",
            )
            .map_err(storage)?;
        }
        if version < 3 {
            // v3: an item can belong to several libraries (key = library + id).
            conn.execute_batch(
                "BEGIN;
                 CREATE TABLE items_v3 (
                     id TEXT NOT NULL,
                     library_id TEXT NOT NULL,
                     name TEXT NOT NULL,
                     json TEXT NOT NULL,
                     updated_at INTEGER NOT NULL,
                     position INTEGER NOT NULL DEFAULT 0,
                     PRIMARY KEY (library_id, id)
                 );
                 INSERT INTO items_v3 SELECT id, library_id, name, json, updated_at, position FROM items;
                 DROP TABLE items;
                 ALTER TABLE items_v3 RENAME TO items;
                 CREATE INDEX items_by_library ON items(library_id, position, name);
                 PRAGMA user_version = 3;
                 COMMIT;",
            )
            .map_err(storage)?;
        }
        Ok(Self { conn })
    }

    pub fn schema_version(&self) -> Result<i64, JellyfinError> {
        self.conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(storage)
    }

    pub fn upsert_library(
        &self,
        id: &str,
        name: &str,
        collection_type: Option<&str>,
    ) -> Result<(), JellyfinError> {
        self.conn
            .execute(
                "INSERT INTO libraries (id, name, collection_type) VALUES (?1, ?2, ?3)
                 ON CONFLICT(id) DO UPDATE SET name = ?2, collection_type = ?3",
                params![id, name, collection_type],
            )
            .map_err(storage)?;
        Ok(())
    }

    pub fn libraries(&self) -> Result<Vec<(String, String)>, JellyfinError> {
        let mut stmt = self
            .conn
            .prepare("SELECT id, name FROM libraries ORDER BY name")
            .map_err(storage)?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(storage)?;
        rows.collect::<Result<_, _>>().map_err(storage)
    }

    /// Saves an item (JSON as returned by the server) in a library.
    pub fn upsert_item(
        &self,
        id: &str,
        library_id: &str,
        name: &str,
        json: &str,
        now: i64,
    ) -> Result<(), JellyfinError> {
        self.conn
            .execute(
                "INSERT INTO items (id, library_id, name, json, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(library_id, id) DO UPDATE SET name = ?3, json = ?4, updated_at = ?5",
                params![id, library_id, name, json, now],
            )
            .map_err(storage)?;
        Ok(())
    }

    /// JSON of the items of a library, sorted by name.
    pub fn items_in_library(&self, library_id: &str) -> Result<Vec<String>, JellyfinError> {
        let mut stmt = self
            .conn
            .prepare("SELECT json FROM items WHERE library_id = ?1 ORDER BY position, name")
            .map_err(storage)?;
        let rows = stmt
            .query_map([library_id], |row| row.get(0))
            .map_err(storage)?;
        rows.collect::<Result<_, _>>().map_err(storage)
    }

    /// Replaces all the libraries at once (JSON as is, order kept).
    pub fn replace_libraries(
        &mut self,
        libraries: &[(String, String, String)],
    ) -> Result<(), JellyfinError> {
        let tx = self.conn.transaction().map_err(storage)?;
        tx.execute("DELETE FROM libraries", []).map_err(storage)?;
        for (id, name, json) in libraries {
            tx.execute(
                "INSERT INTO libraries (id, name, json) VALUES (?1, ?2, ?3)",
                params![id, name, json],
            )
            .map_err(storage)?;
        }
        tx.commit().map_err(storage)
    }

    /// JSON of the libraries in the saved order.
    pub fn library_jsons(&self) -> Result<Vec<String>, JellyfinError> {
        let mut stmt = self
            .conn
            .prepare("SELECT json FROM libraries WHERE json IS NOT NULL ORDER BY rowid")
            .map_err(storage)?;
        let rows = stmt.query_map([], |row| row.get(0)).map_err(storage)?;
        rows.collect::<Result<_, _>>().map_err(storage)
    }

    /// Replaces all the items of a library (a single transaction, order kept).
    /// `items` : (id, nom, json).
    pub fn replace_library_items(
        &mut self,
        library_id: &str,
        items: &[(String, String, String)],
        now: i64,
    ) -> Result<(), JellyfinError> {
        let tx = self.conn.transaction().map_err(storage)?;
        tx.execute("DELETE FROM items WHERE library_id = ?1", [library_id])
            .map_err(storage)?;
        for (position, (id, name, json)) in items.iter().enumerate() {
            tx.execute(
                "INSERT INTO items (id, library_id, name, json, updated_at, position) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(library_id, id) DO UPDATE SET name = ?3, json = ?4, updated_at = ?5, position = ?6",
                params![id, library_id, name, json, now, position as i64],
            )
            .map_err(storage)?;
        }
        tx.commit().map_err(storage)
    }

    pub fn queue_report(
        &self,
        item_id: &str,
        kind: &str,
        position_ticks: i64,
        now: i64,
    ) -> Result<(), JellyfinError> {
        self.conn
            .execute(
                "INSERT INTO playback_reports (item_id, kind, position_ticks, created_at) VALUES (?1, ?2, ?3, ?4)",
                params![item_id, kind, position_ticks, now],
            )
            .map_err(storage)?;
        Ok(())
    }

    /// Pending reports, in the order in which they were created.
    pub fn pending_reports(&self) -> Result<Vec<PendingReport>, JellyfinError> {
        let mut stmt = self
            .conn
            .prepare("SELECT id, item_id, kind, position_ticks, created_at FROM playback_reports ORDER BY id")
            .map_err(storage)?;
        let rows = stmt
            .query_map([], |row| {
                Ok(PendingReport {
                    id: row.get(0)?,
                    item_id: row.get(1)?,
                    kind: row.get(2)?,
                    position_ticks: row.get(3)?,
                    created_at: row.get(4)?,
                })
            })
            .map_err(storage)?;
        rows.collect::<Result<_, _>>().map_err(storage)
    }

    pub fn remove_report(&self, id: i64) -> Result<(), JellyfinError> {
        self.conn
            .execute("DELETE FROM playback_reports WHERE id = ?1", [id])
            .map_err(storage)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_is_created_and_versioned() {
        let store = ProfileStore::open_in_memory().unwrap();
        assert_eq!(store.schema_version().unwrap(), SCHEMA_VERSION);
    }

    #[test]
    fn items_are_upserted_per_library_and_sorted() {
        let store = ProfileStore::open_in_memory().unwrap();
        store
            .upsert_library("lib-a", "Films", Some("movies"))
            .unwrap();
        store
            .upsert_item("i2", "lib-a", "Zorro", r#"{"Id":"i2"}"#, 1)
            .unwrap();
        store
            .upsert_item("i1", "lib-a", "Avatar", r#"{"Id":"i1"}"#, 1)
            .unwrap();
        store
            .upsert_item("i3", "lib-b", "Other", r#"{"Id":"i3"}"#, 1)
            .unwrap();
        // Update of the same item: no duplicate.
        store
            .upsert_item("i1", "lib-a", "Avatar", r#"{"Id":"i1","v":2}"#, 2)
            .unwrap();

        let items = store.items_in_library("lib-a").unwrap();
        assert_eq!(items, vec![r#"{"Id":"i1","v":2}"#, r#"{"Id":"i2"}"#]);
        assert_eq!(
            store.libraries().unwrap(),
            vec![("lib-a".into(), "Films".into())]
        );
    }

    #[test]
    fn replaced_library_keeps_server_order_and_drops_old_items() {
        let mut store = ProfileStore::open_in_memory().unwrap();
        let item = |id: &str, name: &str| {
            (
                id.to_string(),
                name.to_string(),
                format!(r#"{{"Id":"{id}"}}"#),
            )
        };
        store
            .replace_library_items(
                "lib",
                &[item("z", "Zorro"), item("a", "Avatar"), item("old", "Old")],
                1,
            )
            .unwrap();
        store
            .replace_library_items("lib", &[item("z", "Zorro"), item("a", "Avatar")], 2)
            .unwrap();
        assert_eq!(
            store.items_in_library("lib").unwrap(),
            vec![r#"{"Id":"z"}"#, r#"{"Id":"a"}"#],
            "server order, old item removed"
        );
        store
            .replace_libraries(&[("l1".into(), "Films".into(), r#"{"Id":"l1"}"#.into())])
            .unwrap();
        assert_eq!(store.library_jsons().unwrap(), vec![r#"{"Id":"l1"}"#]);
    }

    #[test]
    fn an_item_can_belong_to_two_libraries() {
        let mut store = ProfileStore::open_in_memory().unwrap();
        let item = (
            String::from("x"),
            String::from("Film"),
            String::from(r#"{"Id":"x"}"#),
        );
        store
            .replace_library_items("a", std::slice::from_ref(&item), 1)
            .unwrap();
        store.replace_library_items("b", &[item], 1).unwrap();
        assert_eq!(store.items_in_library("a").unwrap().len(), 1);
        assert_eq!(store.items_in_library("b").unwrap().len(), 1);
    }

    #[test]
    fn a_v1_database_is_migrated_to_the_latest_schema() {
        let dir = std::env::temp_dir().join(format!("store_v1_{}", uuid::Uuid::new_v4()));
        let path = dir.join("store.sqlite");
        std::fs::create_dir_all(&dir).unwrap();
        Connection::open(&path)
            .unwrap()
            .execute_batch(
                "CREATE TABLE libraries (id TEXT PRIMARY KEY, name TEXT NOT NULL, collection_type TEXT);
                 CREATE TABLE items (id TEXT PRIMARY KEY, library_id TEXT NOT NULL, name TEXT NOT NULL, json TEXT NOT NULL, updated_at INTEGER NOT NULL);
                 CREATE TABLE playback_reports (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id TEXT NOT NULL, kind TEXT NOT NULL, position_ticks INTEGER NOT NULL, created_at INTEGER NOT NULL);
                 INSERT INTO items VALUES ('i1', 'lib', 'Avatar', '{}', 1);
                 PRAGMA user_version = 1;",
            )
            .unwrap();
        let store = ProfileStore::open(&path).unwrap();
        assert_eq!(store.schema_version().unwrap(), SCHEMA_VERSION);
        assert_eq!(store.items_in_library("lib").unwrap().len(), 1, "data kept");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn playback_reports_keep_their_order_until_removed() {
        let store = ProfileStore::open_in_memory().unwrap();
        store.queue_report("i1", "start", 0, 10).unwrap();
        store.queue_report("i1", "progress", 600, 20).unwrap();
        store.queue_report("i1", "stopped", 900, 30).unwrap();

        let pending = store.pending_reports().unwrap();
        assert_eq!(
            pending.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(),
            ["start", "progress", "stopped"]
        );
        store.remove_report(pending[0].id).unwrap();
        assert_eq!(store.pending_reports().unwrap().len(), 2);
    }

    #[test]
    fn each_profile_has_its_own_database_file() {
        let dir = std::env::temp_dir().join(format!("store_{}", uuid::Uuid::new_v4()));
        let a = ProfileStore::open(&dir.join("profile-a").join("store.sqlite")).unwrap();
        let b = ProfileStore::open(&dir.join("profile-b").join("store.sqlite")).unwrap();
        a.queue_report("i1", "start", 0, 1).unwrap();
        assert_eq!(a.pending_reports().unwrap().len(), 1);
        assert!(
            b.pending_reports().unwrap().is_empty(),
            "nothing is shared between profiles"
        );

        // Reopening: the data and the version persist.
        drop(a);
        let a_again = ProfileStore::open(&dir.join("profile-a").join("store.sqlite")).unwrap();
        assert_eq!(a_again.pending_reports().unwrap().len(), 1);
        assert_eq!(a_again.schema_version().unwrap(), SCHEMA_VERSION);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn newer_schema_is_refused_instead_of_corrupted() {
        let dir = std::env::temp_dir().join(format!("store_new_{}", uuid::Uuid::new_v4()));
        let path = dir.join("store.sqlite");
        std::fs::create_dir_all(&dir).unwrap();
        Connection::open(&path)
            .unwrap()
            .execute_batch("PRAGMA user_version = 99;")
            .unwrap();
        assert!(matches!(
            ProfileStore::open(&path),
            Err(JellyfinError::Storage(_))
        ));
        let _ = std::fs::remove_dir_all(dir);
    }
}
