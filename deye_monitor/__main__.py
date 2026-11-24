"""Entry point: `python -m deye_monitor [run|probe]`."""
from __future__ import annotations

import argparse
import json
import logging
import os
import threading
import time
from typing import Optional

from .config import Config
from .inverter import SimulatedReader, SolarmanReader
from .monitor import Monitor
from .storage import Storage

log = logging.getLogger("deye_monitor")
OUTAGES_VERSION = "2"  # bump to force a full outage rebuild after the derivation logic changes


def cloud_client(cfg: Config, db: Optional[Storage] = None):
    from .cloud import DeyeCloudClient, seal, unseal
    secret = cfg.cloud_app_secret + cfg.cloud_password_sha256
    store = (lambda: unseal(secret, db.get_state("cloud_token") or ""),
             lambda v: db.set_state("cloud_token", seal(secret, v))) if db else None
    return DeyeCloudClient(cfg.cloud_url, cfg.cloud_app_id, cfg.cloud_app_secret,
                           cfg.cloud_email, cfg.cloud_password_sha256, token_store=store)


def make_reader(cfg: Config, db: Optional[Storage] = None):
    if cfg.mode == "simulate":
        return SimulatedReader()
    if cfg.mode == "cloud":
        from .cloud import CloudReader
        return CloudReader(cloud_client(cfg, db), cfg.cloud_station_id, cfg.cloud_device_sn,
                           cfg.cloud_grid_voltage_key, cfg.cloud_stale_after, cfg.alert_min_level, db=db)
    return SolarmanReader(cfg.logger_ip, cfg.logger_serial, cfg.logger_port, cfg.slave_id)


def probe(cfg: Config) -> None:
    """Read once and print — use it to check the register map against the Deye app."""
    r = make_reader(cfg).read()
    data = r.as_dict()
    data["run_state_name"] = r.run_state_name
    print(json.dumps(data, indent=2, ensure_ascii=False))


def cloud_check(cfg: Config) -> None:
    """Show what Deye Cloud returns for this account: stations, devices, data point names."""
    from .cloud import device_points, find_grid_voltage
    client = cloud_client(cfg)
    stations = client.stations()
    print("Stations:")
    for s in stations:
        print(f"  id={s.get('id')} name={s.get('name')!r} SOC={s.get('batterySOC')} "
              f"status={s.get('connectionStatus')} updated={s.get('lastUpdateTime')}")
    print("Devices:")
    devices = client.devices(int(cfg.cloud_station_id or stations[0]["id"])) if stations else []
    for d in devices:
        print(f"  sn={d.get('deviceSn')} type={d.get('deviceType')} online={d.get('connectStatus')}")
    if stations:
        latest = client.station_latest(int(cfg.cloud_station_id or stations[0]["id"]))
        print("Station latest:", json.dumps({k: v for k, v in latest.items()
                                             if k not in ("code", "msg", "requestId", "success")},
                                            ensure_ascii=False))
    sn = cfg.cloud_device_sn or next((d["deviceSn"] for d in devices
                                      if str(d.get("deviceType", "")).upper() == "INVERTER"), "")
    if sn:
        points = device_points(client.device_latest(sn))
        print(f"Inverter {sn} data points ({len(points)}):")
        for k, v in sorted(points.items()):
            print(f"  {k} = {v}")
        print("Detected grid voltage:", find_grid_voltage(points, cfg.cloud_grid_voltage_key))


def _telegram(cfg: Config):
    if not cfg.tg_token:
        log.warning("TELEGRAM_BOT_TOKEN not set: notifications go to the log only")
        return None
    from .telegram import Telegram
    return Telegram(cfg.tg_token, cfg.tg_chat_id)


def maintenance(cfg: Config, db: Storage, reader, tg, mon: Optional[Monitor] = None) -> None:
    """History sync (cloud), outage rebuild from 5-min points, scheduled reports. Never raises."""
    from .analytics import derive_outages
    from .reports import send_due_reports
    now = time.time()
    if cfg.mode == "cloud":
        try:
            prev = db.get_state("history_synced_until")
            reader.sync_history(db, backfill_days=cfg.backfill_days)
            # rebuild from where this sync started (covers backfill chunks), at least the last 3 days
            full = prev is None or db.get_state("outages_version") != OUTAGES_VERSION
            since = 0.0 if full else min(float(prev), now) - 3 * 86400
            open_start = db.current_outage()  # a long outage may have started before `since`
            frm = 0.0 if not since else min(since, open_start or since) - 86400
            pts = db.points_between(frm, now)
            db.replace_outages(derive_outages(pts, cfg.grid_voltage_min, detailed=True), since)
            db.set_state("outages_rebuilt", str(now))
            db.set_state("outages_version", OUTAGES_VERSION)
            if mon and mon.detector.state is False and db.current_outage() is None:
                # live detection saw the outage before it reached Deye's history: keep it open
                db.open_outage(float(db.get_state("live_off_at") or now))
        except Exception as exc:
            log.warning("history sync failed: %s", exc)
    synced = float(db.get_state("history_synced_until") or 0)
    backfill_done = cfg.mode != "cloud" or synced >= now - 3600
    if tg and backfill_done:
        try:
            send_due_reports(db, cfg, now, tg.send, tg.send_photo)
        except Exception as exc:
            log.warning("reports failed: %s", exc)
        send_morning(cfg, db, tg, mon, now)


def send_morning(cfg: Config, db: Storage, tg, mon: Optional[Monitor], now: float) -> None:
    from .dashboard import last_point_soc, morning_due, morning_text
    key = morning_due(db, cfg, now)
    if not key:
        return
    try:
        grid = mon.detector.state if mon else None
        tg.send(morning_text(db, cfg, now, last_point_soc(db, now), grid))
        db.set_state("last_morning", key)
    except Exception as exc:
        log.warning("morning summary failed: %s", type(exc).__name__)


def run(cfg: Config) -> None:
    db = Storage(cfg.db_path)
    tg = _telegram(cfg)
    notify = tg.send if tg else (lambda text: log.info("NOTIFY: %s", text))
    reader = make_reader(cfg, db)
    mon = Monitor(cfg, db, reader, notify)
    if tg:
        threading.Thread(target=tg.serve, args=(mon.handlers(),), daemon=True, name="telegram").start()

    log.info("monitoring (%s mode), poll every %ss", cfg.mode, cfg.poll_interval)
    last_maint = 0.0
    while True:
        started = time.monotonic()
        mon.tick()
        if time.time() - last_maint >= 600:
            maintenance(cfg, db, reader, tg, mon)
            last_maint = time.time()
        time.sleep(max(1.0, cfg.poll_interval - (time.monotonic() - started)))


def answer_command(cfg: Config, command: str) -> None:
    """Reply to one bot command (started by the Cloudflare worker) from the stored data; no polling,
    no state changes — the regular monitoring run owns the state."""
    from .reports import deliver
    db = Storage(cfg.db_path)
    tg = _telegram(cfg)
    if not tg:
        return
    mon = Monitor(cfg, db, None, tg.send)
    mon.load_state()
    handler = mon.handlers().get(command)
    if handler is None:
        log.warning("unknown command")
        return
    try:
        reply = handler()
    except Exception as exc:
        log.warning("command failed: %s", type(exc).__name__)
        reply = "Не вдалося підготувати відповідь, спробуй пізніше"
    text, png = reply if isinstance(reply, tuple) else (reply, None)
    deliver(text, png, tg.send, tg.send_photo)


CACHED_COMMANDS = ("week", "month", "battery", "history", "stats", "errors")


def publish_cache(cfg: Config, mon: Monitor) -> None:
    """Pre-render every report command and hand it to the Cloudflare worker, which then answers instantly."""
    import base64

    import requests
    items = {}
    handlers = mon.handlers()
    for cmd in CACHED_COMMANDS:
        try:
            reply = handlers[cmd]()
        except Exception as exc:
            log.warning("render %s failed: %s", cmd, type(exc).__name__)
            continue
        text, png = reply if isinstance(reply, tuple) else (reply, None)
        items[cmd] = {"text": text, "png": base64.b64encode(png).decode() if png else None}
    payload = {"generated_at": time.time(), "items": items}
    try:
        from .dashboard import build_data
        payload["data"] = build_data(mon.db, cfg, time.time())
    except Exception as exc:
        log.warning("dashboard data failed: %s", type(exc).__name__)
    try:
        resp = requests.post(f"{cfg.worker_url}/cache", json=payload,
                             headers={"X-Cache-Secret": cfg.cache_secret}, timeout=30)
        if resp.status_code != 200:
            log.warning("cache upload: HTTP %s", resp.status_code)
    except Exception as exc:
        log.warning("cache upload failed: %s", type(exc).__name__)


def once(cfg: Config) -> None:
    """One poll, history sync, due reports, pending bot commands; then exit. For cron / GitHub Actions."""
    db = Storage(cfg.db_path)
    tg = _telegram(cfg)
    notify = tg.send if tg else (lambda text: log.info("NOTIFY: %s", text))
    if cfg.live_alerts == "worker":  # the worker already told the user; keep the events for /errors only
        notify = lambda text: None  # noqa: E731
    reader = make_reader(cfg, db)
    mon = Monitor(cfg, db, reader, notify)
    mon.load_state()
    mon.tick()
    mon.save_state()
    maintenance(cfg, db, reader, tg, mon)
    if cfg.worker_url and cfg.cache_secret:
        publish_cache(cfg, mon)
    if tg:
        if db.get_state("tg_commands") != tg.commands_version() and tg.sync_commands():
            db.set_state("tg_commands", tg.commands_version())
        if os.environ.get("TELEGRAM_POLL", "1") != "0":  # off when the Cloudflare webhook receives updates
            try:
                offset = tg.poll_once(mon.handlers(), int(db.get_state("tg_offset") or 0))
                db.set_state("tg_offset", str(offset))
            except Exception as exc:
                log.warning("telegram poll failed: %s", exc)
    log.info("once: done")  # Actions logs are public: don't print power state


def main() -> None:
    parser = argparse.ArgumentParser(prog="deye_monitor")
    parser.add_argument("command", nargs="?", default="run", choices=["run", "once", "probe", "cloud-check"])
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("--command", dest="command_name", default="", help="once: only answer this bot command and exit")
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    cfg = Config.from_env()
    cfg.validate()
    if args.command == "once" and args.command_name:
        answer_command(cfg, args.command_name)
        return
    {"probe": probe, "once": once, "cloud-check": cloud_check}.get(args.command, run)(cfg)


if __name__ == "__main__":
    main()
