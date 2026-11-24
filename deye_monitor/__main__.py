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


def make_reader(cfg: Config):
    if cfg.mode == "simulate":
        return SimulatedReader()
    return SolarmanReader(cfg.logger_ip, cfg.logger_serial, cfg.logger_port, cfg.slave_id)


def probe(cfg: Config) -> None:
    """Read once and print — use it to check the register map against the Deye app."""
    r = make_reader(cfg).read()
    data = r.as_dict()
    data["run_state_name"] = r.run_state_name
    print(json.dumps(data, indent=2, ensure_ascii=False))


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
    parser.add_argument("command", nargs="?", default="run", choices=["run", "probe"])
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    cfg = Config.from_env()
    cfg.validate()
    probe(cfg) if args.command == "probe" else run(cfg)


if __name__ == "__main__":
    main()
