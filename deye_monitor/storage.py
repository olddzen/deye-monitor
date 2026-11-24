"""SQLite storage: outages, periodic samples, event log, small key/value state."""
from __future__ import annotations

import sqlite3
import threading
from pathlib import Path
from typing import List, Optional, Tuple

SCHEMA = """
CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS outages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    start_ts REAL NOT NULL,
    end_ts REAL
);
CREATE TABLE IF NOT EXISTS samples (
    ts REAL NOT NULL, grid_voltage REAL, grid_power INTEGER, load_power INTEGER,
    pv_power INTEGER, soc INTEGER, battery_power INTEGER, run_state INTEGER
);
CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
CREATE TABLE IF NOT EXISTS events (ts REAL NOT NULL, kind TEXT NOT NULL, message TEXT);
"""

Outage = Tuple[float, Optional[float]]


class Storage:
    def __init__(self, path: str):
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._lock = threading.Lock()
        with self._lock:
            self._db.executescript(SCHEMA)

    def _exec(self, sql: str, args: tuple = ()) -> sqlite3.Cursor:
        with self._lock:
            cur = self._db.execute(sql, args)
            self._db.commit()
            return cur

    # --- key/value ---
    def get_state(self, key: str) -> Optional[str]:
        row = self._exec("SELECT value FROM state WHERE key=?", (key,)).fetchone()
        return row[0] if row else None

    def set_state(self, key: str, value: str) -> None:
        self._exec("INSERT INTO state(key, value) VALUES(?, ?) "
                   "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))

    # --- outages ---
    def open_outage(self, ts: float) -> None:
        if self.current_outage() is None:
            self._exec("INSERT INTO outages(start_ts) VALUES(?)", (ts,))

    def close_outage(self, ts: float) -> Optional[float]:
        cur = self.current_outage()
        if cur is None:
            return None
        self._exec("UPDATE outages SET end_ts=? WHERE end_ts IS NULL", (ts,))
        return cur

    def current_outage(self) -> Optional[float]:
        row = self._exec("SELECT start_ts FROM outages WHERE end_ts IS NULL "
                         "ORDER BY start_ts DESC LIMIT 1").fetchone()
        return row[0] if row else None

    def last_outage_end(self) -> Optional[float]:
        row = self._exec("SELECT MAX(end_ts) FROM outages").fetchone()
        return row[0] if row else None

    def outages_between(self, start: float, end: float) -> List[Outage]:
        return self._exec(
            "SELECT start_ts, end_ts FROM outages WHERE start_ts < ? AND (end_ts IS NULL OR end_ts > ?) "
            "ORDER BY start_ts", (end, start)).fetchall()

    def recent_outages(self, limit: int = 10) -> List[Outage]:
        return self._exec("SELECT start_ts, end_ts FROM outages ORDER BY start_ts DESC LIMIT ?",
                          (limit,)).fetchall()

    # --- samples / events ---
    def add_sample(self, r) -> None:
        self._exec("INSERT INTO samples VALUES(?,?,?,?,?,?,?,?)",
                   (r.ts, r.grid_voltage, r.grid_power, r.load_power, r.pv_power, r.soc,
                    r.battery_power, r.run_state))

    def add_event(self, ts: float, kind: str, message: str) -> None:
        self._exec("INSERT INTO events VALUES(?,?,?)", (ts, kind, message))

    def recent_events(self, kinds: Tuple[str, ...], limit: int = 10) -> List[Tuple[float, str, str]]:
        marks = ",".join("?" * len(kinds))
        return self._exec(f"SELECT ts, kind, message FROM events WHERE kind IN ({marks}) "
                          "ORDER BY ts DESC LIMIT ?", (*kinds, limit)).fetchall()

    def prune(self, before_ts: float) -> None:
        self._exec("DELETE FROM samples WHERE ts < ?", (before_ts,))
