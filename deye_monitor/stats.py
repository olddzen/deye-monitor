"""Pure helpers: outage statistics and Ukrainian formatting."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Iterable, Optional, Tuple
from zoneinfo import ZoneInfo


@dataclass
class Stats:
    count: int
    off_seconds: float
    longest: float
    window: float

    @property
    def availability(self) -> float:
        return 100.0 if self.window <= 0 else 100.0 * (1 - self.off_seconds / self.window)


def compute_stats(outages: Iterable[Tuple[float, Optional[float]]], start: float, end: float) -> Stats:
    """Outage time clipped to [start, end]; an open outage (end None) lasts until `end`."""
    count, total, longest = 0, 0.0, 0.0
    for o_start, o_end in outages:
        s, e = max(o_start, start), min(o_end if o_end is not None else end, end)
        if e <= s:
            continue
        count += 1
        total += e - s
        longest = max(longest, (o_end if o_end is not None else end) - o_start)
    return Stats(count=count, off_seconds=total, longest=longest, window=end - start)


def fmt_duration(seconds: float) -> str:
    minutes = int(round(seconds / 60))
    if minutes < 1:
        return "менше хвилини"
    days, rem = divmod(minutes, 24 * 60)
    hours, mins = divmod(rem, 60)
    parts = []
    if days:
        parts.append(f"{days} д")
    if hours:
        parts.append(f"{hours} год")
    if mins and not days:
        parts.append(f"{mins} хв")
    return " ".join(parts)


def fmt_time(ts: float, tz: str, with_date: bool = False) -> str:
    dt = datetime.fromtimestamp(ts, ZoneInfo(tz))
    return dt.strftime("%d.%m %H:%M" if with_date else "%H:%M")


def start_of_day(ts: float, tz: str) -> float:
    dt = datetime.fromtimestamp(ts, ZoneInfo(tz))
    return dt.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
