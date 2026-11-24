"""Data for the Telegram Mini App dashboard and the morning summary."""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import List, Optional
from zoneinfo import ZoneInfo

from . import analytics as A
from .stats import fmt_duration
from .storage import Storage

DAY = 86400


def _r(x: Optional[float], nd: int = 1) -> Optional[float]:
    return None if x is None else round(x, nd)


def heatmap(outages, start: float, end: float, tz: str) -> List[List[float]]:
    """7×24 share of time without power, rows Monday..Sunday, columns local hours."""
    zone = ZoneInfo(tz)
    off = [[0.0] * 24 for _ in range(7)]
    days = [0] * 7
    d = datetime.fromtimestamp(start, zone).replace(hour=0, minute=0, second=0, microsecond=0)
    while d.timestamp() < end:
        days[d.weekday()] += 1
        d += timedelta(days=1)
    for s, e in A.clip(outages, start, end):
        t = s
        while t < e:
            dt = datetime.fromtimestamp(t, zone)
            nxt = (dt.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1)).timestamp()
            seg = min(nxt, e) - t
            off[dt.weekday()][dt.hour] += seg
            t += seg
    return [[round(min(1.0, off[w][h] / 3600 / days[w]), 3) if days[w] else 0.0 for h in range(24)]
            for w in range(7)]


def daily(db: Storage, outages, now: float, tz: str, tariff: float, n_days: int = 30) -> List[dict]:
    zone = ZoneInfo(tz)
    today = datetime.fromtimestamp(now, zone).replace(hour=0, minute=0, second=0, microsecond=0)
    rows = []
    for i in range(n_days - 1, -1, -1):
        d0 = today - timedelta(days=i)
        s, e = d0.timestamp(), min((d0 + timedelta(days=1)).timestamp(), now)
        pts = db.points_between(s, e)
        off = sum(b - a for a, b in A.clip(outages, s, e))
        en = A.energy_stats(pts, tariff, tz) if pts else None
        rows.append({"date": d0.strftime("%Y-%m-%d"), "off_min": round(off / 60),
                     "load_kwh": _r(en.load_kwh, 2) if en else None,
                     "import_kwh": _r(en.import_kwh, 2) if en else None,
                     "has_data": len(pts) > 30})
    return rows


def build_data(db: Storage, cfg, now: float) -> dict:
    """Everything the dashboard draws, compact enough for one KV value (< 200 KB)."""
    tz = cfg.tz
    outs60 = db.outages_between(now - 60 * DAY, now)
    unsure = {round(s) for s, _ in db.uncertain_outages_between(now - 60 * DAY, now)}
    week = A.outage_stats(outs60, now - 7 * DAY, now, tz)
    prev = A.outage_stats(outs60, now - 14 * DAY, now - 7 * DAY, tz)
    pts7 = db.points_between(now - 7 * DAY, now)
    pts30 = db.points_between(now - 30 * DAY, now)
    per = A.battery_per_outage(db.points_between(now - 60 * DAY, now), outs60, now)
    bat = A.battery_stats(pts30, per, cfg.battery_kwh, cfg.battery_cutoff_soc)
    en = A.energy_stats(pts30, cfg.tariff_uah, tz)
    gq = A.grid_quality(pts30, cfg.grid_voltage_min)
    coverage = sum(1 for p in pts30 if p.get("soc") is not None) / max(len(pts30), 1)
    prev_cov = len(db.points_between(now - 14 * DAY, now - 7 * DAY)) / (7 * DAY / 300)

    # 7-day series, 10-minute buckets: [ts, soc, load, grid_v]
    series, bucket = [], None
    for p in pts7:
        b = int(p["ts"] // 600 * 600)
        if bucket is None or b != bucket[0]:
            bucket = [b, p.get("soc"), p.get("load_power"), p.get("grid_voltage")]
            series.append(bucket)
    series = [[b, _r(s, 0), _r(l, 0), _r(v, 0)] for b, s, l, v in series]

    return {
        "generated_at": now,
        "tz": tz,
        "outages": [[round(s), round(e) if e else None, round(s) in unsure]
                    for s, e in outs60],
        "series7": series,
        "heatmap28": heatmap(outs60, now - 28 * DAY, now, tz),
        "daily30": daily(db, outs60, now, tz, cfg.tariff_uah),
        "week": {"count": week.count, "off_h": _r(week.off_seconds / 3600), "longest_h": _r(week.longest / 3600),
                 "avg_h": _r(week.average / 3600), "share": _r(week.off_share * 100),
                 "prev_count": prev.count if prev_cov >= 0.6 else None,
                 "prev_off_h": _r(prev.off_seconds / 3600) if prev_cov >= 0.6 else None,
                 "busy": A.busy_ranges(week.profile, threshold=0.2)},
        "battery": {"nominal_kwh": cfg.battery_kwh, "capacity_kwh": _r(bat.capacity_kwh),
                    "health": _r(bat.health * 100, 0) if bat.health else None, "samples": bat.samples,
                    "cycles_total": _r(bat.cycles_total, 2), "discharged_30d": _r(bat.discharged_kwh),
                    "temp_max": _r(bat.temp_max, 0), "inverter_temp_max": _r(bat.inverter_temp_max, 0),
                    "coverage": _r(coverage * 100, 0), "typical_load_w": _r(bat.typical_load_w, 0),
                    "cutoff_soc": cfg.battery_cutoff_soc},
        "energy30": {"load_kwh": _r(en.load_kwh), "import_kwh": _r(en.import_kwh),
                     "cost_uah": _r(en.cost_uah, 0), "tariff": cfg.tariff_uah,
                     "base_load_w": _r(en.base_load_w, 0)},
        "grid30": {"v_min": _r(gq.v_min, 0), "v_max": _r(gq.v_max, 0), "v_avg": _r(gq.v_avg, 0),
                   "low_pct": _r(gq.low_share * 100), "high_pct": _r(gq.high_share * 100),
                   "f_min": _r(gq.f_min, 2), "f_max": _r(gq.f_max, 2)},
        "alerts30": A.alert_counts(db.alerts_between(now - 30 * DAY, now), min_level=1),
    }


# ---------------- morning summary ----------------
def morning_text(db: Storage, cfg, now: float, current_soc: Optional[float], grid_on: Optional[bool]) -> str:
    tz = cfg.tz
    zone = ZoneInfo(tz)
    local = datetime.fromtimestamp(now, zone)
    night_start = (local - timedelta(days=1)).replace(hour=22, minute=0, second=0, microsecond=0).timestamp()
    outs = db.outages_between(now - 15 * DAY, now)
    night = A.clip(outs, night_start, now)
    lines = ["☀️ <b>Доброго ранку!</b>"]
    if night:
        total = sum(e - s for s, e in night)
        lines.append(f"🌙 Вночі світла не було {fmt_duration(total)} ({len(night)} раз)")
    else:
        lines.append("🌙 Вночі світло було весь час")
    if grid_on is False:
        cur = db.current_outage()
        lines.append("🔌 Зараз світла немає" + (f" вже {fmt_duration(now - cur)}" if cur else ""))
    elif grid_on:
        lines.append("💡 Зараз світло є")
    if current_soc:
        lines.append(f"🔋 Батарея {current_soc:.0f}%")
    y0 = (local - timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    y = A.clip(outs, y0, y0 + DAY)
    if y:
        lines.append(f"📅 Учора: {len(y)} відкл., без світла {fmt_duration(sum(e - s for s, e in y))}")
    prof = A.hourly_profile(outs, now - 14 * DAY, now, tz)
    busy = A.busy_ranges(prof, threshold=0.2)
    if busy:
        lines.append("🕐 За останні 2 тижні світло найчастіше зникало: "
                     + ", ".join(f"{a:02d}–{b:02d}" for a, b in busy))
    return "\n".join(lines)


def morning_due(db: Storage, cfg, now: float) -> Optional[str]:
    """State key for today's morning summary if it should be sent now (between MORNING_HOUR and noon)."""
    if cfg.morning_hour < 0:
        return None
    local = datetime.fromtimestamp(now, ZoneInfo(cfg.tz))
    key = f"morning:{local:%Y-%m-%d}"
    if cfg.morning_hour <= local.hour < 12 and db.get_state("last_morning") != key:
        return key
    return None


def last_point_soc(db: Storage, now: float) -> Optional[float]:
    for p in reversed(db.points_between(now - 3 * 3600, now)):
        if p.get("soc") is not None:
            return p["soc"]
    return None

