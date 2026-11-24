"""PNG charts for Telegram (matplotlib, headless)."""
from __future__ import annotations

import io
from datetime import datetime
from typing import Optional, Sequence
from zoneinfo import ZoneInfo

from .analytics import Outage, clip

OFF = "#d9534f"
SOC = "#2e8b57"
LOAD = "#7a7a7a"
BAR = "#4a6fa5"


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


def overview_png(points: Sequence[dict], outages: Sequence[Outage], profile: Sequence[float],
                 start: float, end: float, tz: str, title: str) -> Optional[bytes]:
    """Top: battery SOC and load over the window with outages shaded. Bottom: off-share by hour of day."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.dates as mdates
    import matplotlib.pyplot as plt

    zone = ZoneInfo(tz)
    to_dt = lambda ts: datetime.fromtimestamp(ts, zone)  # noqa: E731
    fig, (ax, bx) = plt.subplots(2, 1, figsize=(9, 6.2), gridspec_kw={"height_ratios": [3, 2]})
    fig.suptitle(title, fontsize=13, fontweight="bold")

    for s, e in clip(outages, start, end):
        ax.axvspan(to_dt(s), to_dt(e), color=OFF, alpha=0.25, lw=0)
    sx, sy = _series(points, "soc", to_dt)
    if sx:
        ax.plot(sx, sy, color=SOC, lw=1.6, label="Батарея, %")
    ax.set_ylim(0, 105)
    ax.set_ylabel("Заряд, %")
    ax.set_xlim(to_dt(start), to_dt(end))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%d.%m", tz=zone))
    ax.grid(alpha=0.25)
    lx = ax.twinx()
    lxs, lys = _series(points, "load_power", to_dt)
    if lxs:
        lx.plot(lxs, lys, color=LOAD, lw=0.7, alpha=0.6, label="Споживання, Вт")
    lx.set_ylabel("Вт", color=LOAD)
    lx.tick_params(axis="y", colors=LOAD)
    handles = [plt.Rectangle((0, 0), 1, 1, color=OFF, alpha=0.25, label="Без світла")]
    handles += ax.get_legend_handles_labels()[0] + lx.get_legend_handles_labels()[0]
    ax.legend(handles=handles, loc="lower left", fontsize=8, framealpha=0.8)

    bx.bar(range(24), [v * 100 for v in profile], color=BAR, width=0.8)
    bx.set_xticks(range(0, 24, 2))
    bx.set_xlim(-0.6, 23.6)
    bx.set_xlabel("Година доби")
    bx.set_ylabel("Без світла, % днів")
    bx.set_title("Коли зазвичай немає світла", fontsize=10)
    bx.grid(axis="y", alpha=0.25)

    fig.tight_layout()
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=110)
    plt.close(fig)
    return buf.getvalue()
