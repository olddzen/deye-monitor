"""Text + chart reports (weekly, monthly, on demand) and their schedule."""
from __future__ import annotations

import html
import logging
from datetime import datetime, timedelta
from typing import Callable, List, Optional, Tuple
from zoneinfo import ZoneInfo

from . import analytics as A
from .stats import fmt_duration, fmt_time
from .storage import Storage

log = logging.getLogger(__name__)

MONTHS = ["січня", "лютого", "березня", "квітня", "травня", "червня", "липня", "серпня",
          "вересня", "жовтня", "листопада", "грудня"]
MONTHS_NOM = ["Січень", "Лютий", "Березень", "Квітень", "Травень", "Червень", "Липень", "Серпень",
              "Вересень", "Жовтень", "Листопад", "Грудень"]
SHORT_HINTS = {"F13": "зміна режиму", "F25": "батарея", "F47": "частота мережі", "F56": "низька напруга батареї",
               "F58": "зв'язок з BMS", "F64": "перегрів"}


def _signed(x: float, unit: str = "") -> str:
    return f"{'+' if x > 0 else '−' if x < 0 else '±'}{abs(x):g}{unit}"


def _hours(ranges: List[Tuple[int, int]]) -> str:
    return ", ".join(f"{a:02d}–{b:02d}" for a, b in ranges)


def build_report(db: Storage, cfg, start: float, end: float, title: str,
                 with_chart: bool = True) -> Tuple[str, Optional[bytes]]:
    tz = cfg.tz
    span = end - start
    all_out = db.outages_between(start - 2 * span, end)
    pts = db.points_between(start - 600, end)
    st = A.outage_stats(all_out, start, end, tz)
    prev = A.outage_stats(all_out, start - span, start, tz)
    per = A.battery_per_outage(db.points_between(start - 60 * 86400, end),
                               db.outages_between(start - 60 * 86400, end), end)
    bat = A.battery_stats(pts, per, cfg.battery_kwh, cfg.battery_cutoff_soc)
    en = A.energy_stats(pts, cfg.tariff_uah, tz)
    gq = A.grid_quality(pts, cfg.grid_voltage_min)
    alerts = A.alert_counts(db.alerts_between(start, end), min_level=1)

    expected = span / 300  # Deye stores a point every ~5 min
    data_share = len(pts) / expected if expected else 0
    prev_share = len(db.points_between(start - span, start)) / expected if expected else 0
    lines = [f"📊 <b>{title}</b>"]
    if data_share < 0.8:
        lines.append(f"ℹ️ дані є лише за ~{min(data_share, 1) * span / 86400:.0f} з {span / 86400:.0f} днів")
    lines.append("")
    # --- outages
    if st.count:
        lines.append(f"🔌 <b>Відключення:</b> {st.count}, без світла {fmt_duration(st.off_seconds)} "
                     f"({st.off_share * 100:.0f}% часу)")
        lines.append(f"найдовше {fmt_duration(st.longest)} · в середньому {fmt_duration(st.average)}")
        unsure = len(A.clip(db.uncertain_outages_between(start, end), start, end))
        if unsure:
            lines.append(f"ℹ️ у {unsure} з {st.count} поруч була дірка в даних Deye: "
                         f"реальна тривалість могла бути більшою")
        if prev_share >= 0.6 and (prev.count or st.count):
            dh = round((st.off_seconds - prev.off_seconds) / 3600, 1)
            lines.append(f"проти попереднього періоду: {_signed(st.count - prev.count)} відкл., {_signed(dh, ' год')}")
        busy = A.busy_ranges(st.profile, threshold=max(0.1, min(0.3, 1.5 / max(span / 86400, 1))))
        if busy:
            lines.append(f"🕐 найчастіше без світла: {_hours(busy)}")
    else:
        lines.append("🔌 <b>Відключень не було</b> 🎉")
    lines.append("")

    # --- battery
    coverage = sum(1 for p in pts if p.get("soc") is not None) / max(len(pts), 1)
    lines.append(f"🔋 <b>Батарея:</b> віддала {bat.discharged_kwh:.1f} кВт·год ({bat.cycles_window:.2f} циклу)"
                 + (f", мінімум {bat.soc_min:.0f}%" if bat.soc_min is not None else ""))
    if bat.health:
        lines.append(f"ємність ≈ {bat.capacity_kwh:.1f} кВт·год (здоров'я {bat.health * 100:.0f}%, "
                     f"за {bat.samples} розрядами)")
    else:
        lines.append("ємність: ще не було розряду глибше 15%, щоб її оцінити")
    if bat.cycles_total is not None:
        lines.append(f"циклів за весь час ≈ {bat.cycles_total:.1f} з ~6000")
    if bat.runtime_hours:
        lines.append(f"⏳ з {bat.soc_now:.0f}% вистачить ≈ {fmt_duration(bat.runtime_hours * 3600)} "
                     f"при звичному споживанні під час відключень (~{bat.typical_load_w:.0f} Вт)")
    temps = []
    if bat.temp_max is not None:
        temps.append(f"батарея до {bat.temp_max:.0f} °C")
    if bat.inverter_temp_max is not None:
        temps.append(f"інвертор до {bat.inverter_temp_max:.0f} °C")
    if temps:
        lines.append("🌡 " + ", ".join(temps))
    if pts and coverage < 0.8:
        lines.append(f"⚠️ батарея передавала дані лише {coverage * 100:.0f}% часу (BMS «спить» або вимкнена?)")
    lines.append("")

    # --- energy
    lines.append(f"💸 <b>Енергія:</b> спожито {en.load_kwh:.1f} кВт·год, з мережі {en.import_kwh:.1f} кВт·год "
                 f"≈ {en.cost_uah:.0f} грн")
    extra = []
    if coverage >= 0.8:
        extra.append(f"втрати системи ≈ {en.losses_kwh:.1f} кВт·год ({en.losses_kwh * cfg.tariff_uah:.0f} грн)")
    if en.base_load_w is not None and en.base_load_w >= 5:
        extra.append(f"вночі квартира споживає ~{en.base_load_w:.0f} Вт")
    if extra:
        lines.append(" · ".join(extra))
    lines.append("")

    # --- grid quality
    if gq.v_min is not None:
        q = f"⚡ <b>Мережа:</b> {gq.v_min:.0f}–{gq.v_max:.0f} В (середнє {gq.v_avg:.0f})"
        if gq.low_share >= 0.001:
            q += f", нижче 207 В {gq.low_share * 100:.1f}% часу"
        if gq.high_share >= 0.001:
            q += f", вище 253 В {gq.high_share * 100:.1f}% часу"
        if gq.f_min is not None:
            q += f" · {gq.f_min:.2f}–{gq.f_max:.2f} Гц"
        lines.append(q)

    # --- alerts
    if alerts:
        parts = [f"{html.escape(code, quote=False)} ×{n}" + (f" ({SHORT_HINTS[code]})" if code in SHORT_HINTS else "")
                 for code, n in alerts.items()]
        lines.append("⚠️ <b>Аварії Deye:</b> " + ", ".join(parts))
    else:
        lines.append("✅ Аварій Deye не було")

    png = None
    if with_chart and pts:
        try:
            from .charts import overview_png
            png = overview_png(pts, all_out, st.profile, start, end, tz, title)
        except Exception as exc:  # a chart must never break the report
            log.warning("chart failed: %s", exc)
    return "\n".join(lines), png


def battery_report(db: Storage, cfg, now: float) -> str:
    per = A.battery_per_outage(db.points_between(now - 60 * 86400, now),
                               db.outages_between(now - 60 * 86400, now), now)
    pts = db.points_between(now - 30 * 86400, now)
    bat = A.battery_stats(pts, per, cfg.battery_kwh, cfg.battery_cutoff_soc)
    lines = ["🔋 <b>Батарея</b>"]
    if bat.soc_now is not None:
        lines.append(f"зараз {bat.soc_now:.0f}%")
    lines.append(f"за 30 днів віддала {bat.discharged_kwh:.1f} кВт·год ({bat.cycles_window:.2f} циклу)")
    if bat.cycles_total is not None:
        lines.append(f"за весь час ≈ {bat.cycles_total:.1f} циклів з ~6000")
    if bat.health:
        lines.append(f"оцінка ємності {bat.capacity_kwh:.1f} з {cfg.battery_kwh:g} кВт·год → {bat.health * 100:.0f}%")
    if bat.runtime_hours:
        lines.append(f"вистачить ≈ {fmt_duration(bat.runtime_hours * 3600)} при звичному навантаженні "
                     f"(~{bat.typical_load_w:.0f} Вт)")
    if per:
        lines.append("\n<b>Останні відключення</b> (заряд, віддано, сер. навантаження):")
        for o in per[-6:]:
            soc = (f"{o.soc_start:.0f}→{o.soc_min:.0f}%" if o.soc_start is not None and o.soc_min is not None
                   else "немає даних")
            load = f"{o.avg_load_w:.0f} Вт" if o.avg_load_w else "—"
            lines.append(f"{fmt_time(o.start, cfg.tz, True)} · {fmt_duration(o.end - o.start)} · {soc} · "
                         f"{o.discharged_kwh:.2f} кВт·год · {load}")
    return "\n".join(lines)


# ---------------- schedule ----------------
def due_reports(db: Storage, cfg, now: float) -> List[Tuple[str, float, float, str]]:
    """Reports that should go out now: (state_key_value, start, end, title). Weekly: Monday from 09:00
    for the previous Mon–Sun. Monthly: 1st from 09:00 for the previous calendar month."""
    zone = ZoneInfo(cfg.tz)
    local = datetime.fromtimestamp(now, zone)
    due = []
    this_monday = (local - timedelta(days=local.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)
    if local >= this_monday.replace(hour=9):
        week_start = this_monday - timedelta(days=7)
        key = f"week:{week_start:%Y-%m-%d}"
        if db.get_state("last_weekly") != key:
            last_day = this_monday - timedelta(days=1)
            same_month = week_start.month == last_day.month
            title = (f"Тиждень {week_start.day}–{last_day.day} {MONTHS[last_day.month - 1]}" if same_month else
                     f"Тиждень {week_start.day} {MONTHS[week_start.month - 1]} – {last_day.day} {MONTHS[last_day.month - 1]}")
            due.append((key, week_start.timestamp(), this_monday.timestamp(), title))
    month_start = local.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    if local >= month_start.replace(hour=9):
        prev_start = (month_start - timedelta(days=1)).replace(day=1)
        key = f"month:{prev_start:%Y-%m}"
        if db.get_state("last_monthly") != key:
            due.append((key, prev_start.timestamp(), month_start.timestamp(),
                        f"{MONTHS_NOM[prev_start.month - 1]} {prev_start.year}"))
    return due


def send_due_reports(db: Storage, cfg, now: float, send_text: Callable[[str], None],
                     send_photo: Callable[[bytes, str], None]) -> int:
    sent = 0
    for key, start, end, title in due_reports(db, cfg, now):
        state_key = "last_weekly" if key.startswith("week:") else "last_monthly"
        if len(db.points_between(start, end)) < 0.3 * (end - start) / 300:
            db.set_state(state_key, key)  # too little data for that period: skip silently
            continue
        text, png = build_report(db, cfg, start, end, title)
        deliver(text, png, send_text, send_photo)
        db.set_state(state_key, key)
        sent += 1
    return sent


def deliver(text: str, png: Optional[bytes], send_text, send_photo) -> None:
    """Telegram photo captions are limited to 1024 chars: send the chart first, then the text."""
    if png:
        try:
            send_photo(png, "")
        except Exception as exc:
            log.warning("photo failed: %s", exc)
    send_text(text)
