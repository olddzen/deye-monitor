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
    cloud_url: str = "https://eu1-developer.deyecloud.com"
    cloud_app_id: str = ""
    cloud_app_secret: str = ""
    cloud_email: str = ""
    cloud_password_sha256: str = ""
    cloud_station_id: Optional[int] = None
    cloud_device_sn: str = ""
    cloud_grid_voltage_key: str = ""
    cloud_stale_after: int = 1200
    alert_min_level: int = 2
    tariff_uah: float = 4.32
    battery_kwh: float = 11.8
    battery_cutoff_soc: float = 10.0
    backfill_days: int = 45
    worker_url: str = ""
    cache_secret: str = ""
    live_alerts: str = "python"  # "worker": the Cloudflare worker sends live alerts, Python stays quiet

    @classmethod
    def from_env(cls) -> "Config":
        load_dotenv(os.environ.get("DEYE_ENV_FILE", ".env"))
        chat = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
        soc = os.environ.get("SOC_ALERTS", "30,15").strip()
        mode = os.environ.get("DEYE_MODE", "local").strip().lower()
        password_hash = os.environ.get("DEYE_CLOUD_PASSWORD_SHA256", "").strip().lower()
        if not password_hash and os.environ.get("DEYE_CLOUD_PASSWORD"):
            import hashlib
            password_hash = hashlib.sha256(os.environ["DEYE_CLOUD_PASSWORD"].encode("utf-8")).hexdigest()
        station = os.environ.get("DEYE_CLOUD_STATION_ID", "").strip()
        return cls(
            mode=mode,
            logger_ip=os.environ.get("DEYE_LOGGER_IP", "").strip(),
            logger_serial=_int("DEYE_LOGGER_SERIAL", 0),
            logger_port=_int("DEYE_LOGGER_PORT", 8899),
            slave_id=_int("DEYE_SLAVE_ID", 1),
            poll_interval=_int("POLL_INTERVAL", 120 if mode == "cloud" else 30),
            grid_voltage_min=_float("GRID_VOLTAGE_MIN", 180.0),
            debounce=_int("DEBOUNCE_READINGS", 1 if mode == "cloud" else 2),
            unreachable_alert_after=_int("UNREACHABLE_ALERT_AFTER", 300 if mode == "cloud" else 600),
            soc_alerts=tuple(sorted((int(x) for x in soc.split(",") if x.strip()), reverse=True)),
            sample_every=_int("SAMPLE_EVERY", 300),
            keep_days=_int("KEEP_SAMPLES_DAYS", 400),
            tg_token=os.environ.get("TELEGRAM_BOT_TOKEN", "").strip(),
            tg_chat_id=int(chat) if chat else None,
            db_path=os.environ.get("DB_PATH", "data/deye.sqlite3"),
            tz=os.environ.get("TZ_NAME", "Europe/Kyiv"),
            cloud_url=os.environ.get("DEYE_CLOUD_URL", "https://eu1-developer.deyecloud.com").strip(),
            cloud_app_id=os.environ.get("DEYE_CLOUD_APP_ID", "").strip(),
            cloud_app_secret=os.environ.get("DEYE_CLOUD_APP_SECRET", "").strip(),
            cloud_email=os.environ.get("DEYE_CLOUD_EMAIL", "").strip(),
            cloud_password_sha256=password_hash,
            cloud_station_id=int(station) if station else None,
            cloud_device_sn=os.environ.get("DEYE_CLOUD_DEVICE_SN", "").strip(),
            cloud_grid_voltage_key=os.environ.get("DEYE_CLOUD_GRID_VOLTAGE_KEY", "").strip(),
            cloud_stale_after=_int("DEYE_CLOUD_STALE_AFTER", 1200),
            alert_min_level=_int("ALERT_MIN_LEVEL", 2),
            tariff_uah=_float("TARIFF_UAH", 4.32),
            battery_kwh=_float("BATTERY_KWH", 11.8),
            battery_cutoff_soc=_float("BATTERY_CUTOFF_SOC", 10.0),
            backfill_days=_int("BACKFILL_DAYS", 30),
            worker_url=os.environ.get("WORKER_URL", "").strip().rstrip("/"),
            cache_secret=os.environ.get("CACHE_SECRET", "").strip(),
            live_alerts=os.environ.get("LIVE_ALERTS", "python").strip().lower(),
        )

    def validate(self) -> None:
        if self.mode not in ("local", "cloud", "simulate"):
            raise SystemExit(f"DEYE_MODE must be 'local', 'cloud' or 'simulate', got {self.mode!r}")
        if self.mode == "cloud" and not all((self.cloud_app_id, self.cloud_app_secret,
                                             self.cloud_email, self.cloud_password_sha256)):
            raise SystemExit("Cloud mode needs DEYE_CLOUD_APP_ID, DEYE_CLOUD_APP_SECRET, "
                             "DEYE_CLOUD_EMAIL and DEYE_CLOUD_PASSWORD (see README)")
        if self.mode == "local" and (not self.logger_ip or not self.logger_serial):
            raise SystemExit("Set DEYE_LOGGER_IP and DEYE_LOGGER_SERIAL in .env (see README)")
