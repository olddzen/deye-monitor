"""Configuration from environment variables (optionally loaded from a .env file)."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple


def load_dotenv(path: str = ".env") -> None:
    p = Path(path)
    if not p.exists():
        return
    for line in p.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if value[:1] in ('"', "'"):
            value = value[1:].split(value[0], 1)[0]
        else:
            value = value.split(" #", 1)[0].strip()  # inline comment
        os.environ.setdefault(key.strip(), value)


def _int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    return int(raw) if raw else default


def _float(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    return float(raw) if raw else default


@dataclass(frozen=True)
class Config:
    mode: str  # "local" | "simulate"
    logger_ip: str
    logger_serial: int
    logger_port: int
    slave_id: int
    poll_interval: int
    grid_voltage_min: float
    debounce: int
    unreachable_alert_after: int
    soc_alerts: Tuple[int, ...]
    sample_every: int
    keep_days: int
    tg_token: str
    tg_chat_id: Optional[int]
    db_path: str
    tz: str

    @classmethod
    def from_env(cls) -> "Config":
        load_dotenv(os.environ.get("DEYE_ENV_FILE", ".env"))
        chat = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
        soc = os.environ.get("SOC_ALERTS", "30,15").strip()
        return cls(
            mode=os.environ.get("DEYE_MODE", "local").strip().lower(),
            logger_ip=os.environ.get("DEYE_LOGGER_IP", "").strip(),
            logger_serial=_int("DEYE_LOGGER_SERIAL", 0),
            logger_port=_int("DEYE_LOGGER_PORT", 8899),
            slave_id=_int("DEYE_SLAVE_ID", 1),
            poll_interval=_int("POLL_INTERVAL", 30),
            grid_voltage_min=_float("GRID_VOLTAGE_MIN", 180.0),
            debounce=_int("DEBOUNCE_READINGS", 2),
            unreachable_alert_after=_int("UNREACHABLE_ALERT_AFTER", 600),
            soc_alerts=tuple(sorted((int(x) for x in soc.split(",") if x.strip()), reverse=True)),
            sample_every=_int("SAMPLE_EVERY", 300),
            keep_days=_int("KEEP_SAMPLES_DAYS", 90),
            tg_token=os.environ.get("TELEGRAM_BOT_TOKEN", "").strip(),
            tg_chat_id=int(chat) if chat else None,
            db_path=os.environ.get("DB_PATH", "data/deye.sqlite3"),
            tz=os.environ.get("TZ_NAME", "Europe/Kyiv"),
        )

    def validate(self) -> None:
        if self.mode not in ("local", "simulate"):
            raise SystemExit(f"DEYE_MODE must be 'local' or 'simulate', got {self.mode!r}")
        if self.mode == "local" and (not self.logger_ip or not self.logger_serial):
            raise SystemExit("Set DEYE_LOGGER_IP and DEYE_LOGGER_SERIAL in .env (see README)")
