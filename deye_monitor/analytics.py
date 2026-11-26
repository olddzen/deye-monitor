"""Statistics over 5-minute points, outages and Deye alerts. Pure functions, no I/O."""
from __future__ import annotations

import statistics
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Dict, Iterable, List, Optional, Sequence, Tuple
from zoneinfo import ZoneInfo

Outage = Tuple[float, Optional[float]]
MAX_GAP = 1200  # s; a longer hole in the data is "no data", not a measurement


def derive_outages(points: Sequence[dict], threshold: float, max_gap: int = MAX_GAP,
                   detailed: bool = False) -> list:
    """Outages from grid-voltage points. Edges are placed halfway between the last-on and first-off
    points (±2.5 min at Deye's 5-min resolution); a trailing outage stays open (end None).
    When an edge borders a hole in the data (> max_gap) the real outage may be longer: only the
    confirmed part is counted, and detailed=True adds an `uncertain` flag: (start, end, uncertain)."""
    out: list = []
    prev_ts: Optional[float] = None
    prev_on: Optional[bool] = None
    start: Optional[float] = None
    unsure = False
    for p in points:
        v = p.get("grid_voltage")
        if v is None:
            continue
        ts, on = float(p["ts"]), v >= threshold
        gap = ts - prev_ts if prev_ts is not None else None
        if prev_on is True and not on:
            start, unsure = (prev_ts + gap / 2, False) if gap <= max_gap else (ts, True)
        elif prev_on is False and on and start is not None:
            if gap <= max_gap:
                end = prev_ts + gap / 2
            else:
                end, unsure = prev_ts + 300, True
            out.append((start, end, unsure) if detailed else (start, end))
            start = None
        elif prev_on is None and not on:
            start, unsure = ts, True
        prev_ts, prev_on = ts, on
    if start is not None:
        out.append((start, None, unsure) if detailed else (start, None))
    return out


def integrate_kwh(points: Sequence[dict], key: str, sign: int = 0, max_gap: int = MAX_GAP) -> float:
    """Energy in kWh from a power series in W. sign=+1 keeps positive values only, -1 negative only."""
    total = 0.0
    for a, b in zip(points, points[1:]):
        va, vb = a.get(key), b.get(key)
        dt = b["ts"] - a["ts"]
        if va is None or vb is None or dt <= 0 or dt > max_gap:
            continue
        if sign > 0:
            va, vb = max(va, 0), max(vb, 0)
        elif sign < 0:
            va, vb = -min(va, 0), -min(vb, 0)
        total += (va + vb) / 2 * dt
    return total / 3600 / 1000


def clip(outages: Iterable[Outage], start: float, end: float) -> List[Tuple[float, float]]:
    res = []
    for s, e in outages:
        s2, e2 = max(s, start), min(e if e is not None else end, end)
        if e2 > s2:
            res.append((s2, e2))
    return res


def hourly_profile(outages: Iterable[Outage], start: float, end: float, tz: str) -> List[float]:
    """Share (0..1) of each local clock hour 0–23 that was without power over the window."""
    zone = ZoneInfo(tz)
    off = [0.0] * 24
    for s, e in clip(outages, start, end):
        t = s
        while t < e:
            dt = datetime.fromtimestamp(t, zone)
            nxt = (dt.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1)).timestamp()
            seg_end = min(nxt, e)
            off[dt.hour] += seg_end - t
            t = seg_end
    days = max((end - start) / 86400, 1e-9)
    return [min(1.0, x / 3600 / days) for x in off]


def busy_ranges(profile: Sequence[float], threshold: float = 0.25) -> List[Tuple[int, int]]:
    """Consecutive hours where the off-share is above threshold, e.g. [(6, 10), (18, 22)]."""
    ranges, start = [], None
    for h in range(25):
        hot = h < 24 and profile[h] >= threshold
        if hot and start is None:
            start = h
        elif not hot and start is not None:
            ranges.append((start, h))
            start = None
    return ranges


@dataclass
class OutageStats:
    count: int = 0
    off_seconds: float = 0.0
    longest: float = 0.0
    average: float = 0.0
    window: float = 0.0
    profile: List[float] = field(default_factory=lambda: [0.0] * 24)

    @property
    def off_share(self) -> float:
        return self.off_seconds / self.window if self.window else 0.0


def outage_stats(outages: Sequence[Outage], start: float, end: float, tz: str) -> OutageStats:
    parts = clip(outages, start, end)
    full = [((e if e is not None else end) - s) for s, e in outages if (e or end) > start and s < end]
    total = sum(e - s for s, e in parts)
    return OutageStats(count=len(parts), off_seconds=total, longest=max(full, default=0.0),
                       average=total / len(parts) if parts else 0.0, window=end - start,
                       profile=hourly_profile(outages, start, end, tz))


@dataclass
class OutageBattery:
    start: float
    end: float
    soc_start: Optional[float]
    soc_min: Optional[float]
    discharged_kwh: float
    avg_load_w: Optional[float]

    @property
    def capacity_kwh(self) -> Optional[float]:
        if self.soc_start is None or self.soc_min is None:
            return None
        drop = self.soc_start - self.soc_min
        return self.discharged_kwh / (drop / 100) if drop >= 15 else None


def battery_per_outage(points: Sequence[dict], outages: Sequence[Outage], now: float) -> List[OutageBattery]:
    res = []
    for s, e in outages:
        e = e if e is not None else now
        inside = [p for p in points if s - 360 <= p["ts"] <= e + 60]
        if len(inside) < 2:
            continue
        before = [p["soc"] for p in inside if p["ts"] <= s + 60 and p.get("soc") is not None]
        socs = [p["soc"] for p in inside if p.get("soc") is not None]
        loads = [p["load_power"] for p in inside if p["ts"] >= s and p.get("load_power") is not None]
        res.append(OutageBattery(
            start=s, end=e,
            soc_start=before[-1] if before else (socs[0] if socs else None),
            soc_min=min(socs) if socs else None,
            discharged_kwh=integrate_kwh([p for p in inside if p["ts"] >= s - 60], "battery_power", +1),
            avg_load_w=statistics.mean(loads) if loads else None))
    return res


@dataclass
class BatteryStats:
    nominal_kwh: float
    capacity_kwh: Optional[float]      # median estimate from deep-enough discharges
    samples: int
    discharged_kwh: float               # in window
    cycles_window: float
    cycles_total: Optional[float]       # lifetime, from the inverter's total discharge counter
    soc_now: Optional[float]
    soc_min: Optional[float]
    runtime_hours: Optional[float]      # from soc_now down to the cut-off at typical outage load
    temp_max: Optional[float]
    inverter_temp_max: Optional[float]
    typical_load_w: Optional[float] = None

    @property
    def health(self) -> Optional[float]:
        return self.capacity_kwh / self.nominal_kwh if self.capacity_kwh else None


def battery_stats(points: Sequence[dict], per_outage: Sequence[OutageBattery], nominal_kwh: float,
                  cutoff_soc: float = 10.0) -> BatteryStats:
    caps = [o.capacity_kwh for o in per_outage if o.capacity_kwh]
    discharged = integrate_kwh(points, "battery_power", +1)
    totals = [p["discharge_total"] for p in points if p.get("discharge_total") is not None]
    socs = [p["soc"] for p in points if p.get("soc") is not None]
    loads = [o.avg_load_w for o in per_outage if o.avg_load_w]
    if not loads:
        loads = [p["load_power"] for p in points if p.get("load_power") is not None]
    typical_w = statistics.median(loads) if loads else None
    capacity = statistics.median(caps) if caps else None
    soc_now = socs[-1] if socs else None
    runtime = None
    if soc_now is not None and typical_w and typical_w > 20:
        runtime = max(0.0, soc_now - cutoff_soc) / 100 * (capacity or nominal_kwh) * 1000 / typical_w
    temps = [p["battery_temp"] for p in points if p.get("battery_temp") is not None]
    inv = [max(p.get("dc_temp") or 0, p.get("ac_temp") or 0) for p in points
           if p.get("dc_temp") is not None or p.get("ac_temp") is not None]
    return BatteryStats(
        nominal_kwh=nominal_kwh, capacity_kwh=capacity, samples=len(caps), discharged_kwh=discharged,
        cycles_window=discharged / nominal_kwh, cycles_total=totals[-1] / nominal_kwh if totals else None,
        soc_now=soc_now, soc_min=min(socs) if socs else None, runtime_hours=runtime,
        temp_max=max(temps) if temps else None, inverter_temp_max=max(inv) if inv else None,
        typical_load_w=typical_w)


@dataclass
class EnergyStats:
    load_kwh: float
    import_kwh: float
    losses_kwh: float
    cost_uah: float
    base_load_w: Optional[float]


def energy_stats(points: Sequence[dict], tariff: float, tz: str) -> EnergyStats:
    load = integrate_kwh(points, "load_power")
    imp = integrate_kwh(points, "grid_power", +1)
    net_battery = integrate_kwh(points, "battery_power")  # + discharged, − charged
    zone = ZoneInfo(tz)
    night = sorted(p["load_power"] for p in points if p.get("load_power") is not None
                   and 1 <= datetime.fromtimestamp(p["ts"], zone).hour < 5)
    base = statistics.median(night) if night else None
    return EnergyStats(load_kwh=load, import_kwh=imp, losses_kwh=max(0.0, imp + net_battery - load),
                       cost_uah=imp * tariff, base_load_w=base)


@dataclass
class GridQuality:
    v_min: Optional[float]
    v_max: Optional[float]
    v_avg: Optional[float]
    low_share: float    # share of on-grid time below 207 V (−10 %)
    high_share: float   # above 253 V (+10 %)
    f_min: Optional[float]
    f_max: Optional[float]


def grid_quality(points: Sequence[dict], threshold: float) -> GridQuality:
    on = [p for p in points if p.get("grid_voltage") is not None and p["grid_voltage"] >= threshold]
    v = [p["grid_voltage"] for p in on]
    f = [p["grid_freq"] for p in on if p.get("grid_freq")]
    n = len(v) or 1
    return GridQuality(v_min=min(v) if v else None, v_max=max(v) if v else None,
                       v_avg=statistics.mean(v) if v else None,
                       low_share=sum(x < 207 for x in v) / n, high_share=sum(x > 253 for x in v) / n,
                       f_min=min(f) if f else None, f_max=max(f) if f else None)


def alert_counts(alerts: Iterable[Tuple[str, int, float, Optional[float]]], min_level: int = 1) -> Dict[str, int]:
    """{'F47': 3, ...} for alerts at or above min_level."""
    c: Counter = Counter()
    for name, level, _, _ in alerts:
        if (level or 0) >= min_level:
            c[str(name).split("_")[0][:3]] += 1
    return dict(c.most_common())


@dataclass
class Insights:
    hourly_w: List[Optional[float]]     # average load by local hour, last 14 days
    base_load_w: Optional[float]        # median 01–05 load (fridge, router, standby)
    week_kwh: float
    prev_week_kwh: Optional[float]      # None when last week has too little data
    import_day_kwh: Optional[float]     # average grid import per full day with data
    month_cost_uah: Optional[float]     # projected at that average
    standby_month_kwh: Optional[float]
    standby_month_uah: Optional[float]
    peak_hour: Optional[int]
    evening_share: Optional[float]      # share of consumption between 18 and 23


def consumption_insights(pts14: Sequence[dict], now: float, tz: str, tariff: float) -> Insights:
    """What eats the energy: hourly profile, standby, week-over-week, projected bill."""
    zone = ZoneInfo(tz)
    sums, counts = [0.0] * 24, [0] * 24
    for p in pts14:
        w = p.get("load_power")
        if w is not None:
            h = datetime.fromtimestamp(p["ts"], zone).hour
            sums[h] += w
            counts[h] += 1
    hourly = [round(sums[h] / counts[h]) if counts[h] >= 6 else None for h in range(24)]
    night = sorted(p["load_power"] for p in pts14 if p.get("load_power") is not None
                   and 1 <= datetime.fromtimestamp(p["ts"], zone).hour < 5)
    base = statistics.median(night) if night else None
    week_pts = [p for p in pts14 if p["ts"] >= now - 7 * 86400]
    prev_pts = [p for p in pts14 if p["ts"] < now - 7 * 86400]
    week = integrate_kwh(week_pts, "load_power")
    prev_known = sum(1 for p in prev_pts if p.get("load_power") is not None)
    week_known = sum(1 for p in week_pts if p.get("load_power") is not None)
    # compare only when last week was measured about as fully as this one
    prev = (integrate_kwh(prev_pts, "load_power")
            if prev_known > 0.6 * 7 * 288 and prev_known > 0.8 * week_known else None)
    # average import over full local days that have most of their points
    days: Dict[str, List[dict]] = {}
    for p in pts14:
        days.setdefault(datetime.fromtimestamp(p["ts"], zone).strftime("%Y-%m-%d"), []).append(p)
    today = datetime.fromtimestamp(now, zone).strftime("%Y-%m-%d")
    full = [integrate_kwh(v, "grid_power", +1) for k, v in days.items() if k != today and len(v) > 0.8 * 288]
    imp_day = statistics.mean(full) if full else None
    known = [w for w in hourly if w is not None]
    total = sum(known)
    evening = sum(w for h, w in enumerate(hourly) if w is not None and 18 <= h < 23)
    if base is not None and base < 5:  # the inverter reports ~0 W at night: no meaningful standby figure
        base = None
    standby_kwh = base * 24 * 30 / 1000 if base else None
    return Insights(
        hourly_w=hourly, base_load_w=base, week_kwh=week, prev_week_kwh=prev, import_day_kwh=imp_day,
        month_cost_uah=imp_day * 30 * tariff if imp_day is not None else None,
        standby_month_kwh=standby_kwh, standby_month_uah=standby_kwh * tariff if standby_kwh else None,
        peak_hour=max(range(24), key=lambda h: hourly[h] or 0) if known else None,
        evening_share=evening / total if total else None)


def appliance_increments(samples: Sequence[dict]) -> List[Tuple[float, float]]:
    """(time, Wh) increments for ONE device from SmartThings snapshots. Samsung appliances report a
    cumulative `energy` counter and/or a `deltaEnergy` per ~15-min report window; each report window is
    counted once (snapshots repeat it), from the counter when both ends have one, else from the delta."""
    out: List[Tuple[float, float]] = []
    prev_end: Optional[float] = None
    prev_energy: Optional[float] = None
    for s in sorted(samples, key=lambda x: x["ts"]):
        end, energy, delta = s.get("report_end"), s.get("energy_wh"), s.get("delta_wh")
        if end is None or end == prev_end:
            continue
        inc = None
        if energy and prev_energy and energy >= prev_energy:
            inc = energy - prev_energy
        if inc is None or (inc == 0 and delta):
            inc = delta or 0.0
        if prev_end is not None or delta:  # the first report only sets the baseline counter
            out.append((end, max(0.0, float(inc))))
        prev_end, prev_energy = end, energy if energy else prev_energy
    return out


def appliance_stats(samples: Sequence[dict], now: float, tz: str, days: int = 14) -> List[dict]:
    """Per device: kWh today / 7 d / 30 d and a daily series for the last `days` days."""
    zone = ZoneInfo(tz)
    today = datetime.fromtimestamp(now, zone).replace(hour=0, minute=0, second=0, microsecond=0)
    by_dev: Dict[str, List[dict]] = {}
    for s in samples:
        by_dev.setdefault(s["device_id"], []).append(s)
    out = []
    for dev, rows in by_dev.items():
        last = rows[-1]
        incs = appliance_increments(rows)
        daily = [0.0] * days
        t0 = (today - timedelta(days=days - 1)).timestamp()
        for t, wh in incs:
            if t >= t0:
                i = int((datetime.fromtimestamp(t, zone).replace(hour=0, minute=0, second=0, microsecond=0)
                         - (today - timedelta(days=days - 1))).days)
                if 0 <= i < days:
                    daily[i] += wh / 1000
        out.append({
            "id": dev, "label": last.get("label"), "kind": last.get("kind"),
            "today_kwh": round(sum(wh for t, wh in incs if t >= today.timestamp()) / 1000, 2),
            "week_kwh": round(sum(wh for t, wh in incs if t >= now - 7 * 86400) / 1000, 2),
            "month_kwh": round(sum(wh for t, wh in incs if t >= now - 30 * 86400) / 1000, 2),
            "daily_kwh": [round(x, 2) for x in daily],
            "since": rows[0]["ts"],
        })
    return sorted(out, key=lambda d: -d["month_kwh"])


def schedule_accuracy(slots: Sequence[Tuple[float, float]], outages: Sequence[Outage], start: float, end: float,
                      tolerance: float = 3600) -> dict:
    """How well the published schedule held in [start, end): only slots that have already ended count.
    An outage belongs to a planned slot when it overlaps the slot widened by `tolerance` on each side;
    everything else is unplanned. Deltas are in minutes, positive = later than planned."""
    done = [(s, e) for s, e in slots if e <= end and s >= start]
    actual = clip(outages, start, end)
    starts, ends, happened = [], [], 0
    used = set()
    for s, e in done:
        hits = [i for i, (a, b) in enumerate(actual) if a < e + tolerance and b > s - tolerance]
        if not hits:
            continue
        happened += 1
        used.update(hits)
        starts.append((actual[hits[0]][0] - s) / 60)
        last_end = actual[hits[-1]][1]
        if last_end < end - 60:  # an outage still going on has no end yet
            ends.append((last_end - e) / 60)
    # an outage inside any planned slot (also one not over yet) is not "unplanned"
    planned_any = lambda a, b: any(a < e + tolerance and b > s - tolerance for s, e in slots)  # noqa: E731
    unplanned = [actual[i] for i in range(len(actual)) if i not in used and actual[i][1] - actual[i][0] >= 600
                 and not planned_any(*actual[i])]
    mean = lambda xs: round(statistics.mean(xs)) if xs else None  # noqa: E731
    return {
        "planned": len(done), "happened": happened,
        "start_delta_min": mean(starts), "end_delta_min": mean(ends),
        "end_late_max_min": round(max(ends)) if ends else None,
        "unplanned": len(unplanned), "unplanned_h": round(sum(b - a for a, b in unplanned) / 3600, 1),
    }


# ---------------- real battery drain & power peaks ----------------
INVERTER_W = 6000.0   # what the inverter can give from the battery
BYPASS_W = 8000.0     # roughly what its grid relay passes through (35 A)
NEAR_LIMIT = 0.85


@dataclass
class RealDrain:
    drain_w: Optional[float]        # what the battery really gave, from the SOC drop
    load_w: Optional[float]         # what the flat used meanwhile
    self_use_w: Optional[float]     # the difference: the inverter's own consumption (and losses)
    samples: int


def real_drain(per_outage: Sequence[OutageBattery], capacity_kwh: float,
               min_hours: float = 1.5, min_drop: float = 2.0) -> RealDrain:
    """Median of outages long enough for the 1 % SOC steps to mean something."""
    drains, loads, selfs = [], [], []
    for o in per_outage:
        hours = (o.end - o.start) / 3600
        if o.soc_start is None or o.soc_min is None or o.avg_load_w is None or hours < min_hours:
            continue
        drop = o.soc_start - o.soc_min
        if drop < min_drop:
            continue
        w = drop / 100 * capacity_kwh * 1000 / hours
        drains.append(w)
        loads.append(o.avg_load_w)
        selfs.append(min(max(w - o.avg_load_w, 0.0), 200.0))
    if not drains:
        return RealDrain(None, None, None, 0)
    return RealDrain(statistics.median(drains), statistics.median(loads), statistics.median(selfs), len(drains))


def power_peaks(points: Sequence[dict], start: float, end: float, tz: str, threshold: float) -> dict:
    """Biggest draw per day and how often it came close to a limit (6 kW from the battery,
    ~8 kW through the grid relay). Deye samples every ~5 min, so short spikes slip through."""
    zone = ZoneInfo(tz)
    days: Dict[str, list] = {}
    near, top = 0, None
    for p in points:
        if not (start <= p["ts"] <= end):
            continue
        load = p.get("load_power") or 0
        grid = p.get("grid_power") or 0
        on = (p.get("grid_voltage") or 0) >= threshold
        draw, limit = (max(grid, load), BYPASS_W) if on else (load, INVERTER_W)
        day = datetime.fromtimestamp(p["ts"], zone).strftime("%Y-%m-%d")
        d = days.setdefault(day, [day, 0.0, None, False])
        if draw > d[1]:
            d[1], d[2] = draw, p["ts"]
        if draw >= NEAR_LIMIT * limit:
            near += 1
            d[3] = True
        if top is None or draw > top[0]:
            top = (draw, p["ts"], on)
    return {
        "days": [[d[0], round(d[1]), d[2], d[3]] for d in sorted(days.values())],
        "max_w": round(top[0]) if top else None, "max_ts": top[1] if top else None,
        "max_on_grid": top[2] if top else None,
        "near_limit": near, "inverter_w": INVERTER_W, "bypass_w": BYPASS_W,
    }
