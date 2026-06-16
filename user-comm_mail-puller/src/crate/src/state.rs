//! Sqlite state DB: last-seen (uidvalidity, uid) per (source_id, mailbox).
//! Shared across tokio tasks via Arc<Mutex<Connection>>.

use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use std::{path::Path, sync::{Arc, Mutex}};

#[derive(Clone)]
pub struct State {
    conn: Arc<Mutex<Connection>>,
}

impl State {
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self> {
        let conn = Connection::open(&path)
            .with_context(|| format!("open sqlite {:?}", path.as_ref()))?;
        conn.execute_batch(r#"
            CREATE TABLE IF NOT EXISTS cursor (
                source_id     TEXT NOT NULL,
                mailbox       TEXT NOT NULL,
                uidvalidity   INTEGER NOT NULL DEFAULT 0,
                last_uid      INTEGER NOT NULL DEFAULT 0,
                updated_at    INTEGER NOT NULL DEFAULT (strftime('%s','now')),
                PRIMARY KEY (source_id, mailbox)
            );
            CREATE TABLE IF NOT EXISTS delivered (
                source_id     TEXT NOT NULL,
                mailbox       TEXT NOT NULL,
                uid           INTEGER NOT NULL,
                message_id    TEXT,
                delivered_at  INTEGER NOT NULL DEFAULT (strftime('%s','now')),
                PRIMARY KEY (source_id, mailbox, uid)
            );
        "#)?;
        Ok(Self { conn: Arc::new(Mutex::new(conn)) })
    }

    pub fn get_cursor(&self, source_id: &str, mailbox: &str) -> Result<(u32, u32)> {
        let conn = self.conn.lock().unwrap();
        let row = conn.query_row(
            "SELECT uidvalidity, last_uid FROM cursor WHERE source_id = ? AND mailbox = ?",
            params![source_id, mailbox],
            |r| Ok((r.get::<_, i64>(0)? as u32, r.get::<_, i64>(1)? as u32)),
        );
        Ok(row.unwrap_or((0, 0)))
    }

    pub fn set_cursor(&self, source_id: &str, mailbox: &str, uidvalidity: u32, last_uid: u32) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO cursor (source_id, mailbox, uidvalidity, last_uid, updated_at)
             VALUES (?, ?, ?, ?, strftime('%s','now'))
             ON CONFLICT(source_id, mailbox) DO UPDATE SET
                 uidvalidity = excluded.uidvalidity,
                 last_uid    = excluded.last_uid,
                 updated_at  = excluded.updated_at",
            params![source_id, mailbox, uidvalidity as i64, last_uid as i64],
        )?;
        Ok(())
    }

    pub fn record_delivered(&self, source_id: &str, mailbox: &str, uid: u32, msg_id: Option<&str>) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT OR IGNORE INTO delivered (source_id, mailbox, uid, message_id)
             VALUES (?, ?, ?, ?)",
            params![source_id, mailbox, uid as i64, msg_id],
        )?;
        Ok(())
    }
}
