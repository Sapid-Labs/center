"""The database: every schema's records in one table, plus app tokens and pairings.

A record is `{id, data, created_at, updated_at, deleted, seq}`. `seq` comes from one
counter shared by every schema and goes up on every write, deletes included, so an app
asks "what changed since seq N?" and never misses or repeats a change, whatever the
clocks say. A delete keeps the row with `deleted = 1` (a tombstone) so the delete syncs
too. `data` is the schema's own JSON, checked by its pydantic model before it gets here.
"""
from __future__ import annotations

import json
import os
import sqlite3
import threading
import time
from pathlib import Path

DATA_DIR = Path(os.environ.get("CENTER_DATA", Path.home() / ".local/share/center"))
_lock = threading.RLock()
_conn: sqlite3.Connection | None = None
_path: Path | None = None


def db() -> sqlite3.Connection:
    """The one connection, opened (and the tables made) on first use."""
    global _conn, _path
    path = DATA_DIR / "center.sqlite3"
    if _conn is None or _path != path:
        path.parent.mkdir(parents=True, exist_ok=True)
        _conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        _conn.row_factory = sqlite3.Row
        _conn.execute("PRAGMA journal_mode=WAL")
        _conn.executescript("""
            CREATE TABLE IF NOT EXISTS records (
                schema     TEXT NOT NULL,
                id         TEXT NOT NULL,
                data       TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                deleted    INTEGER NOT NULL DEFAULT 0,
                seq        INTEGER NOT NULL,
                PRIMARY KEY (schema, id));
            CREATE INDEX IF NOT EXISTS records_seq ON records (schema, seq);
            CREATE TABLE IF NOT EXISTS counter (n INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS tokens (
                id           TEXT PRIMARY KEY,
                name         TEXT NOT NULL,
                hash         TEXT NOT NULL UNIQUE,
                scopes       TEXT NOT NULL,
                created_at   REAL NOT NULL,
                last_used_at REAL,
                revoked      INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS pairings (
                id         TEXT PRIMARY KEY,
                code       TEXT NOT NULL,
                app        TEXT NOT NULL,
                scopes     TEXT NOT NULL,
                created_at REAL NOT NULL,
                status     TEXT NOT NULL,   -- waiting, approved, denied, collected
                token      TEXT);           -- held only between approval and collection
        """)
        if _conn.execute("SELECT count(*) FROM counter").fetchone()[0] == 0:
            _conn.execute("INSERT INTO counter VALUES (0)")
        _path = path
    return _conn


def next_seq(c: sqlite3.Connection) -> int:
    c.execute("UPDATE counter SET n = n + 1")
    return c.execute("SELECT n FROM counter").fetchone()[0]


def row(r: sqlite3.Row) -> dict:
    return {"id": r["id"], "data": json.loads(r["data"]), "created_at": r["created_at"],
            "updated_at": r["updated_at"], "deleted": bool(r["deleted"]), "seq": r["seq"]}


def get(schema: str, rid: str) -> dict | None:
    r = db().execute("SELECT * FROM records WHERE schema = ? AND id = ?", (schema, rid)).fetchone()
    return row(r) if r else None


def changes(schema: str, since: int = 0, limit: int = 500) -> list[dict]:
    """Every record written after `since`, tombstones included, oldest change first."""
    return [row(r) for r in db().execute(
        "SELECT * FROM records WHERE schema = ? AND seq > ? ORDER BY seq LIMIT ?",
        (schema, since, limit))]


def live(schema: str) -> list[dict]:
    return [row(r) for r in db().execute(
        "SELECT * FROM records WHERE schema = ? AND deleted = 0 ORDER BY seq", (schema,))]


def put(schema: str, rid: str, data: dict, updated_at: float | None = None,
        deleted: bool = False) -> tuple[dict, bool]:
    """Write a record, last write wins: a write older than what is stored is ignored.

    Returns the record as it now stands and whether this write changed it.
    """
    now = time.time()
    at = updated_at if updated_at is not None else now
    with _lock:
        c = db()
        c.execute("BEGIN IMMEDIATE")
        try:
            old = c.execute("SELECT * FROM records WHERE schema = ? AND id = ?", (schema, rid)).fetchone()
            if old is not None and old["updated_at"] > at:
                c.execute("COMMIT")
                return row(old), False
            seq = next_seq(c)
            c.execute("INSERT OR REPLACE INTO records VALUES (?, ?, ?, ?, ?, ?, ?)",
                      (schema, rid, json.dumps(data), old["created_at"] if old else now, at,
                       int(deleted), seq))
            c.execute("COMMIT")
        except BaseException:
            c.execute("ROLLBACK")
            raise
    return get(schema, rid), True


def cursor(schema: str) -> int:
    r = db().execute("SELECT max(seq) FROM records WHERE schema = ?", (schema,)).fetchone()
    return r[0] or 0
