"""Entry point: `python -m deye_monitor [run|probe]`."""
from __future__ import annotations

import argparse
import json
import logging
import threading
import time

from .config import Config
from .inverter import SimulatedReader, SolarmanReader
from .monitor import Monitor
from .storage import Storage

log = logging.getLogger("deye_monitor")


def cloud_client(cfg: Config):
    from .cloud import DeyeCloudClient
    return DeyeCloudClient(cfg.cloud_url, cfg.cloud_app_id, cfg.cloud_app_secret,
                           cfg.cloud_email, cfg.cloud_password_sha256)


def make_reader(cfg: Config):
    if cfg.mode == "simulate":
        return SimulatedReader()
    if cfg.mode == "cloud":
        from .cloud import CloudReader
        return CloudReader(cloud_client(cfg), cfg.cloud_station_id, cfg.cloud_device_sn,
                           cfg.cloud_grid_voltage_key, cfg.cloud_stale_after, cfg.alert_min_level)
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


def run(cfg: Config) -> None:
    db = Storage(cfg.db_path)
    tg = None
    if cfg.tg_token:
        from .telegram import Telegram
        tg = Telegram(cfg.tg_token, cfg.tg_chat_id)
        notify = tg.send
    else:
        log.warning("TELEGRAM_BOT_TOKEN not set: notifications go to the log only")
        notify = lambda text: log.info("NOTIFY: %s", text)  # noqa: E731

    mon = Monitor(cfg, db, make_reader(cfg), notify)
    if tg:
        handlers = {"status": mon.cmd_status, "stats": mon.cmd_stats,
                    "history": mon.cmd_history, "errors": mon.cmd_errors}
        threading.Thread(target=tg.serve, args=(handlers,), daemon=True, name="telegram").start()

    log.info("monitoring (%s mode), poll every %ss", cfg.mode, cfg.poll_interval)
    while True:
        started = time.monotonic()
        mon.tick()
        time.sleep(max(1.0, cfg.poll_interval - (time.monotonic() - started)))


def main() -> None:
    parser = argparse.ArgumentParser(prog="deye_monitor")
    parser.add_argument("command", nargs="?", default="run", choices=["run", "probe", "cloud-check"])
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    cfg = Config.from_env()
    cfg.validate()
    {"probe": probe, "cloud-check": cloud_check}.get(args.command, run)(cfg)


if __name__ == "__main__":
    main()
