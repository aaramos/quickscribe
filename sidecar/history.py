"""SQLite history: rolling last 50 captures."""
from __future__ import annotations

import logging
import sqlite3
import threading
import time

log = logging.getLogger("quickscribe.history")

SCHEMA = """
CREATE TABLE IF NOT EXISTS captures (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts REAL NOT NULL,
    raw TEXT NOT NULL,
    polished TEXT NOT NULL,
    profile TEXT NOT NULL,
    ms_stt INTEGER NOT NULL,
    ms_polish INTEGER NOT NULL
);
"""


class History:
    def __init__(self, db_path, limit: int = 50):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.db_path = str(db_path)
        self.limit = limit
        self._lock = threading.Lock()
        with self._conn() as c:
            c.executescript(SCHEMA)

    def _conn(self) -> sqlite3.Connection:
        c = sqlite3.connect(self.db_path, timeout=5.0)
        c.execute("PRAGMA journal_mode=WAL")
        return c

    def add(self, raw: str, polished: str, profile: str, ms_stt: int, ms_polish: int) -> int:
        with self._lock, self._conn() as c:
            cur = c.execute(
                "INSERT INTO captures (ts, raw, polished, profile, ms_stt, ms_polish) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (time.time(), raw, polished, profile, ms_stt, ms_polish),
            )
            c.execute(
                "DELETE FROM captures WHERE id NOT IN "
                "(SELECT id FROM captures ORDER BY id DESC LIMIT ?)",
                (self.limit,),
            )
            return cur.lastrowid

    def recent(self, limit: int = 50) -> list[dict]:
        with self._lock, self._conn() as c:
            rows = c.execute(
                "SELECT ts, raw, polished, profile, ms_stt, ms_polish "
                "FROM captures ORDER BY id DESC LIMIT ?",
                (min(limit, self.limit),),
            ).fetchall()
        return [
            {
                "ts": r[0],
                "raw": r[1],
                "polished": r[2],
                "profile": r[3],
                "ms_stt": r[4],
                "ms_polish": r[5],
            }
            for r in rows
        ]