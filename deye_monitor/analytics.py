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
