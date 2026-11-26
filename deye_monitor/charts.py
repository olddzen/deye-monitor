"""PNG charts for Telegram reports (matplotlib, headless), in the same style as the dashboard.

Three stacked panels, never a dual axis: battery charge, apartment load, and the share of days
without power for each hour. Outages are shaded with the status 'critical' tint in the time panels.
"""
from __future__ import annotations

import io
import math
from datetime import datetime
from typing import Optional, Sequence
from zoneinfo import ZoneInfo

from .analytics import Outage, clip

SURFACE = "#fcfcfb"
TEXT = "#0b0b0b"
TEXT_2 = "#52514e"
MUTED = "#8a8984"
GRID = "#e6e5e0"
SERIES = "#2a78d6"          # categorical slot 1 / sequential blue
OFF = "#d03b3b"             # status: critical
WEEKDAYS = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Нд"]
SEQ = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95"]


def _series(points: Sequence[dict], key: str, to_dt, max_gap: int = 1200):
    """x/y lists with NaN breaks across data gaps, so lines don't bridge missing periods."""
    xs, ys, prev = [], [], None
    for p in points:
        v = p.get(key)
        if v is None:
            continue
        if prev is not None and p["ts"] - prev > max_gap:
            xs.append(to_dt(prev + 1))
            ys.append(float("nan"))
        xs.append(to_dt(p["ts"]))
        ys.append(v)
        prev = p["ts"]
    return xs, ys


def _nice(v: float) -> float:
    if not v or v <= 0:
        return 1.0
    p = 10 ** math.floor(math.log10(v))
    f = v / p
    return (1 if f <= 1 else 2 if f <= 2 else 2.5 if f <= 2.5 else 5 if f <= 5 else 10) * p


def _style(ax, title: str) -> None:
    ax.set_facecolor(SURFACE)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color(GRID)
    ax.tick_params(colors=MUTED, labelsize=9, length=0)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    ax.set_title(title, loc="left", fontsize=10.5, color=TEXT_2, fontweight="bold", pad=8)


def overview_png(points: Sequence[dict], outages: Sequence[Outage], profile: Sequence[float],
                 start: float, end: float, tz: str, title: str) -> Optional[bytes]:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.dates as mdates
    import matplotlib.pyplot as plt

    zone = ZoneInfo(tz)
    to_dt = lambda ts: datetime.fromtimestamp(ts, zone)  # noqa: E731
    plt.rcParams.update({"font.family": "DejaVu Sans"})
    fig, (ax, lx, bx) = plt.subplots(3, 1, figsize=(9, 7.6), gridspec_kw={"height_ratios": [3, 2.2, 2]},
                                     facecolor=SURFACE)
    fig.suptitle(title, x=0.06, ha="left", fontsize=15, fontweight="bold", color=TEXT)
    spans = clip(outages, start, end)
    span_days = (end - start) / 86400
    from matplotlib.ticker import FuncFormatter

    def _label(x, _pos):
        d = mdates.num2date(x, tz=zone)
        return d.strftime("%d.%m") if span_days > 8 else f"{WEEKDAYS[d.weekday()]} {d.day}"
    fmt = FuncFormatter(_label)

    # 1) battery charge
    _style(ax, "Заряд батареї, %")
    for s, e in spans:
        ax.axvspan(to_dt(s), to_dt(e), color=OFF, alpha=0.13, lw=0)
    sx, sy = _series(points, "soc", to_dt)
    if sx:
        ax.plot(sx, sy, color=SERIES, lw=2, solid_capstyle="round")
    else:
        ax.text(0.5, 0.5, "BMS не передавав дані", transform=ax.transAxes, ha="center", color=MUTED)
    ax.set_ylim(0, 105)
    ax.set_yticks([0, 50, 100])
    ax.set_xlim(to_dt(start), to_dt(end))
    ax.xaxis.set_major_formatter(fmt)

    # 2) load
    _style(lx, "Споживання квартири, Вт")
    for s, e in spans:
        lx.axvspan(to_dt(s), to_dt(e), color=OFF, alpha=0.13, lw=0)
    lxs, lys = _series(points, "load_power", to_dt)
    if lxs:
        top = _nice(max((y for y in lys if not math.isnan(y)), default=1))
        lx.plot(lxs, lys, color=SERIES, lw=1.4)
        lx.set_ylim(0, top)
        lx.set_yticks([0, top / 2, top])
    lx.set_xlim(to_dt(start), to_dt(end))
    lx.xaxis.set_major_formatter(fmt)

    # 3) hour-of-day profile (sequential: darker = more often without power)
    _style(bx, "Коли зазвичай немає світла, % днів")
    vals = [v * 100 for v in profile]
    peak_v = max(vals, default=0) or 1
    colors = [SEQ[min(len(SEQ) - 1, int(v / peak_v * (len(SEQ) - 1) + 0.5))] if v > 0 else GRID for v in vals]
    bx.bar(range(24), [max(v, 0.6) for v in vals], color=colors, width=0.78)
    bx.set_xticks(range(0, 24, 3))
    bx.set_xticklabels([f"{h:02d}" for h in range(0, 24, 3)])
    bx.set_xlim(-0.6, 23.6)
    bx.set_ylim(0, max(10, _nice(max(vals, default=0))))
    peak = max(range(24), key=lambda h: vals[h])
    if vals[peak] > 0:
        bx.annotate(f"{vals[peak]:.0f}%", (peak, vals[peak]), textcoords="offset points", xytext=(0, 4),
                    ha="center", fontsize=9, color=TEXT_2)

    handles = [plt.Rectangle((0, 0), 1, 1, color=OFF, alpha=0.25)]
    fig.legend(handles, ["без світла"], loc="upper right", frameon=False, fontsize=9, labelcolor=TEXT_2,
               bbox_to_anchor=(0.97, 0.985))
    fig.tight_layout(rect=(0, 0, 1, 0.95))
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=120, facecolor=SURFACE)
    plt.close(fig)
    return buf.getvalue()
