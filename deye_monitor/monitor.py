"""Core logic: turn raw inverter readings into a few meaningful events."""
from __future__ import annotations

import json
import logging
import time
from typing import Callable, Optional, Set, Tuple

from .config import Config
from .inverter import Reading
from .stats import compute_stats, fmt_duration, fmt_time, start_of_day
from .storage import Storage

log = logging.getLogger(__name__)
Notify = Callable[[str], None]


class GridDetector:
    """Grid on/off from grid voltage, with debounce so a single odd reading doesn't flap."""

    def __init__(self, threshold: float, debounce: int, initial: Optional[bool] = None):
        self.threshold = threshold
        self.debounce = max(1, debounce)
        self.state = initial
        self._pending: Optional[bool] = None
        self._count = 0

    def update(self, voltage: float) -> Optional[bool]:
        """Returns the new state when it changes, otherwise None. First reading only sets the state."""
        on = voltage >= self.threshold
        if self.state is None:
            self.state = on
            return None
        if on == self.state:
            self._pending, self._count = None, 0
            return None
        if self._pending != on:
            self._pending, self._count = on, 0
        self._count += 1
        if self._count >= self.debounce:
            self.state, self._pending, self._count = on, None, 0
            return on
        return None


class Monitor:
    def __init__(self, cfg: Config, db: Storage, reader, notify: Notify, clock=time.time):
        self.cfg, self.db, self.reader, self.notify, self.clock = cfg, db, reader, notify, clock
        saved = db.get_state("grid_on")
        self.detector = GridDetector(cfg.grid_voltage_min, cfg.debounce,
                                     None if saved is None else saved == "1")
        self.last: Optional[Reading] = None
        self.last_ok: float = clock()
        self.unreachable_alerted = False
        self.problem_sig: Optional[Tuple[int, int, int]] = None
        self.soc_fired: Set[int] = set()
        self.last_sample = 0.0

    # ---------- state between one-shot runs (GitHub Actions) ----------
    def save_state(self) -> None:
        self.db.set_state("monitor", json.dumps({
            "last": self.last.as_dict() if self.last else None,
            "last_ok": self.last_ok,
            "unreachable_alerted": self.unreachable_alerted,
            "problem_sig": list(self.problem_sig) if self.problem_sig else None,
            "soc_fired": sorted(self.soc_fired),
            "last_sample": self.last_sample,
        }))

    def load_state(self) -> None:
        raw = self.db.get_state("monitor")
        if not raw:
            return
        st = json.loads(raw)
        if st.get("last"):
            self.last = Reading(**st["last"])
        self.last_ok = st.get("last_ok", self.last_ok)
        self.unreachable_alerted = st.get("unreachable_alerted", False)
        self.problem_sig = tuple(st["problem_sig"]) if st.get("problem_sig") else None
        self.soc_fired = set(st.get("soc_fired") or [])
        self.last_sample = st.get("last_sample", 0.0)

    # ---------- polling ----------
    def tick(self) -> None:
        try:
            reading = self.reader.read()
        except Exception as exc:  # network hiccups are normal for Wi-Fi sticks
            log.warning("read failed: %s", exc)
            self._on_unreachable()
            return
        self.handle(reading)

    def handle(self, r: Reading) -> None:
        now = r.ts
        fresh = self.last is None or r.ts > self.last.ts
        if self.unreachable_alerted:
            self._send(now, "link", "📶 Зв'язок з інвертором відновлено")
        self.unreachable_alerted = False
        self.last_ok = self.clock()
        self.last = r
        self._check_alerts(r)
        if not fresh:  # cloud mode: same upload as last poll
            return

        self._check_grid(r)
        self._check_battery(r)
        self._check_problems(r)

        if now - self.last_sample >= self.cfg.sample_every:
            self.db.add_sample(r)
            self.db.prune(now - self.cfg.keep_days * 86400)
            self.last_sample = now

    def _check_grid(self, r: Reading) -> None:
        was_unknown = self.detector.state is None
        changed = self.detector.update(r.grid_voltage)
        if was_unknown:
            self.db.set_state("grid_on", "1" if self.detector.state else "0")
            if not self.detector.state:
                self.db.open_outage(r.ts)  # started while already off: approximate start
            log.info("initial grid state: %s", "on" if self.detector.state else "off")
            return
        if changed is None:
            return
        self.db.set_state("grid_on", "1" if changed else "0")
        when = fmt_time(r.ts, self.cfg.tz)
        if changed:
            started = self.db.close_outage(r.ts)
            took = f"\nНе було: <b>{fmt_duration(r.ts - started)}</b>" if started else ""
            self.soc_fired.clear()
            self._send(r.ts, "grid_on", f"💡 <b>Світло дали</b> о {when}{took}\n🔋 Батарея: {r.soc}%")
        else:
            prev_end = self.db.last_outage_end()
            self.db.open_outage(r.ts)
            was = f"\nБуло: {fmt_duration(r.ts - prev_end)}" if prev_end else ""
            self._send(r.ts, "grid_off", f"🔌 <b>Світло вимкнули</b> о {when}{was}\n"
                                         f"🔋 Батарея: {r.soc}% · навантаження {r.load_power} Вт")

    def _check_battery(self, r: Reading) -> None:
        if self.detector.state:
            return
        for level in self.cfg.soc_alerts:  # sorted high → low
            if r.soc <= level and level not in self.soc_fired:
                self.soc_fired.update(x for x in self.cfg.soc_alerts if x >= level)
                left = ""
                if r.battery_power > 50:
                    # rough: 11.8 kWh pack; Deye default discharge cut-off ~ 10–20 %
                    hours = (r.soc - 10) / 100 * 11800 / r.battery_power
                    if hours > 0:
                        left = f"\nВистачить приблизно на {fmt_duration(hours * 3600)}"
                self._send(r.ts, "battery", f"🪫 Батарея {r.soc}% (поріг {level}%){left}")
                break

    def _check_problems(self, r: Reading) -> None:
        sig = (r.run_state, r.alarms, r.faults) if r.has_problem else None
        if sig == self.problem_sig:
            return
        if sig:
            self._send(r.ts, "fault",
                       f"⚠️ <b>Інвертор: {r.run_state_name}</b>\n"
                       f"Коди: warnings=0x{r.alarms:08X}, faults=0x{r.faults:016X}\n"
                       f"Деталі в застосунку Deye/Solarman")
        elif self.problem_sig:
            self._send(r.ts, "fault_clear", "✅ Помилка інвертора зникла, стан Normal")
        self.problem_sig = sig

    def _check_alerts(self, r: Reading) -> None:
        if not r.alerts:
            return
        seen = json.loads(self.db.get_state("seen_alerts") or "[]")
        for a in r.alerts:
            key = str(a.get("alertId") or (a.get("alertCode"), a.get("alertStartTime")))
            if key in seen:
                continue
            seen.append(key)
            from .cloud import FAULT_HINTS
            level = {0: "Notice", 1: "Warning", 2: "Failure"}.get(int(a.get("level") or 0), "?")
            name = str(a.get("alertName") or a.get("alertCode") or "?")
            parts = [f"⚠️ <b>Deye: {name}</b> ({level})"]
            hint = a.get("description") or FAULT_HINTS.get(name.split("_")[0][:3])
            if hint:
                parts.append(str(hint))
            start, end = a.get("alertStartTime"), a.get("alertEndTime")
            if str(a.get("status")) == "0" and start and end:
                parts.append(f"Тривала {fmt_duration(float(end) - float(start))}, вже минула "
                             f"(о {fmt_time(float(end), self.cfg.tz)})")
            if a.get("solution"):
                parts.append(f"Що робити: {a['solution']}")
            self._send(r.ts, "fault", "\n".join(parts))
        self.db.set_state("seen_alerts", json.dumps(seen[-300:]))

    def _on_unreachable(self) -> None:
        now = self.clock()
        if not self.unreachable_alerted and now - self.last_ok >= self.cfg.unreachable_alert_after:
            self.unreachable_alerted = True
            hint = getattr(self.reader, "offline_hint", "Wi-Fi/роутер?")
            self._send(now, "link", f"📵 Немає даних від інвертора вже "
                                    f"{fmt_duration(now - self.last_ok)}\n{hint}")

    def _send(self, ts: float, kind: str, text: str) -> None:
        self.db.add_event(ts, kind, text)
        try:
            self.notify(text)
        except Exception as exc:
            log.error("notify failed: %s", exc)

    # ---------- bot commands ----------
    def cmd_status(self) -> str:
        r = self.last
        if r is None:
            return "Ще немає даних від інвертора"
        now = self.clock()
        grid = self.detector.state
        if grid:
            since = self.db.last_outage_end()
            head = "💡 Світло є" + (f" вже {fmt_duration(now - since)}" if since else "")
        else:
            since = self.db.current_outage()
            head = "🔌 Світла немає" + (f" вже {fmt_duration(now - since)}" if since else "")
        bat = "заряджається" if r.battery_power < -20 else "розряджається" if r.battery_power > 20 else "у спокої"
        age = "" if now - r.ts < 120 else f"\n⏱ дані {fmt_duration(now - r.ts)} тому"
        return (f"<b>{head}</b>\n"
                f"🔋 {r.soc}% ({bat}, {abs(r.battery_power)} Вт)\n"
                f"🏠 Навантаження: {r.load_power} Вт\n"
                f"⚡ Мережа: {r.grid_voltage:.0f} В, {r.grid_freq:.1f} Гц\n"
                f"⚙️ Інвертор: {r.run_state_name}{age}")

    def cmd_stats(self) -> str:
        now = self.clock()
        lines = ["<b>📊 Статистика відключень</b>"]
        for title, start in (("Сьогодні", start_of_day(now, self.cfg.tz)),
                             ("7 днів", now - 7 * 86400), ("30 днів", now - 30 * 86400)):
            s = compute_stats(self.db.outages_between(start, now), start, now)
            if s.count == 0:
                lines.append(f"\n<b>{title}</b>: без відключень 🎉")
                continue
            lines.append(f"\n<b>{title}</b>: {s.count} відкл., без світла {fmt_duration(s.off_seconds)} "
                         f"({100 - s.availability:.0f}%)\nнайдовше: {fmt_duration(s.longest)}")
        return "\n".join(lines)

    def cmd_history(self) -> str:
        rows = self.db.recent_outages(10)
        if not rows:
            return "Відключень ще не зафіксовано"
        now = self.clock()
        out = ["<b>🕓 Останні відключення</b>"]
        for start, end in rows:
            span = f"{fmt_time(start, self.cfg.tz, True)} → " + (
                fmt_time(end, self.cfg.tz) if end else "зараз")
            out.append(f"{span} · {fmt_duration((end or now) - start)}")
        return "\n".join(out)

    def cmd_errors(self) -> str:
        rows = self.db.recent_events(("fault", "fault_clear", "link"), 10)
        if not rows:
            return "Серйозних помилок не було ✅"
        return "\n\n".join(f"<i>{fmt_time(ts, self.cfg.tz, True)}</i>\n{msg}" for ts, _, msg in rows)
