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
CREATE TABLE IF NOT EXISTS points (
    ts INTEGER PRIMARY KEY, grid_voltage REAL, grid_freq REAL, grid_power REAL, load_power REAL,
    soc REAL, battery_power REAL, battery_temp REAL, dc_temp REAL, ac_temp REAL,
    charge_total REAL, discharge_total REAL
);
CREATE TABLE IF NOT EXISTS alerts (
    alert_id TEXT PRIMARY KEY, name TEXT, level INTEGER, start_ts REAL, end_ts REAL
);
"""

POINT_COLUMNS = ("grid_voltage", "grid_freq", "grid_power", "load_power", "soc", "battery_power",
                 "battery_temp", "dc_temp", "ac_temp", "charge_total", "discharge_total")

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
        self._exec("DELETE FROM points WHERE ts < ?", (int(before_ts),))

    # --- 5-minute points (from Deye history or live readings) ---
    def upsert_points(self, rows: List[dict]) -> int:
        """rows: {"ts": int, <column>: value, ...}; existing values are kept where the new one is None."""
        if not rows:
            return 0
        cols = ", ".join(POINT_COLUMNS)
        marks = ", ".join("?" * (len(POINT_COLUMNS) + 1))
        updates = ", ".join(f"{c}=COALESCE(excluded.{c}, {c})" for c in POINT_COLUMNS)
        with self._lock:
            self._db.executemany(
                f"INSERT INTO points(ts, {cols}) VALUES({marks}) ON CONFLICT(ts) DO UPDATE SET {updates}",
                [(int(r["ts"]), *(r.get(c) for c in POINT_COLUMNS)) for r in rows])
            self._db.commit()
        return len(rows)

    def points_between(self, start: float, end: float) -> List[dict]:
        cur = self._exec(f"SELECT ts, {', '.join(POINT_COLUMNS)} FROM points WHERE ts >= ? AND ts <= ? "
                         "ORDER BY ts", (int(start), int(end)))
        names = ("ts",) + POINT_COLUMNS
        return [dict(zip(names, row)) for row in cur.fetchall()]

    def replace_outages(self, outages: List[Outage], since: float) -> None:
        """Replace stored outages that start at/after `since` with `outages` (derived from points)."""
        with self._lock:
            self._db.execute("DELETE FROM outages WHERE start_ts >= ? OR end_ts IS NULL", (since,))
            self._db.executemany("INSERT INTO outages(start_ts, end_ts) VALUES(?, ?)",
                                 [o for o in outages if o[0] >= since or o[1] is None])
            self._db.commit()

    # --- Deye alerts ---
    def upsert_alert(self, alert_id: str, name: str, level: int, start: float, end: Optional[float]) -> bool:
        """Returns True if the alert was not stored before."""
        new = self._exec("SELECT 1 FROM alerts WHERE alert_id=?", (alert_id,)).fetchone() is None
        self._exec("INSERT INTO alerts VALUES(?,?,?,?,?) ON CONFLICT(alert_id) DO UPDATE SET "
                   "end_ts=excluded.end_ts", (alert_id, name, level, start, end))
        return new

    def alerts_between(self, start: float, end: float) -> List[Tuple[str, int, float, Optional[float]]]:
        return self._exec("SELECT name, level, start_ts, end_ts FROM alerts WHERE start_ts >= ? AND start_ts < ? "
                          "ORDER BY start_ts", (start, end)).fetchall()
