import tempfile
import time
import unittest
from datetime import datetime
from zoneinfo import ZoneInfo

from deye_monitor import analytics as A
from deye_monitor.dashboard import day_detail, days_to_publish
from deye_monitor.storage import Storage

TZ = "Europe/Kyiv"


def pts(start, n, load=lambda h: 300, grid=200):
    zone = ZoneInfo(TZ)
    out = []
    for i in range(n):
        ts = start + i * 300
        h = datetime.fromtimestamp(ts, zone).hour
        out.append({"ts": ts, "grid_voltage": 230.0, "grid_freq": 50.0, "grid_power": grid, "load_power": load(h),
                    "soc": 80.0, "battery_power": 0.0, "battery_temp": 20.0, "dc_temp": 30.0, "ac_temp": 30.0,
                    "charge_total": 1.0, "discharge_total": 1.0})
    return out


class InsightsTest(unittest.TestCase):
    def test_profile_standby_and_projection(self):
        now = datetime(2026, 11, 20, 12, tzinfo=ZoneInfo(TZ)).timestamp()
        data = pts(now - 14 * 86400, 14 * 288, load=lambda h: 100 if 1 <= h < 5 else (900 if h == 20 else 300))
        ins = A.consumption_insights(data, now, TZ, tariff=4.32)
        self.assertEqual(ins.base_load_w, 100)
        self.assertEqual(ins.peak_hour, 20)
        self.assertAlmostEqual(ins.standby_month_kwh, 72, places=0)
        self.assertAlmostEqual(ins.import_day_kwh, 4.8, delta=0.1)
        self.assertIsNotNone(ins.prev_week_kwh)
        self.assertGreater(ins.evening_share, 0)


class DayArchiveTest(unittest.TestCase):
    def setUp(self):
        self.db = Storage(tempfile.mktemp(suffix=".db"))

    def test_day_detail_and_publish_list(self):
        zone = ZoneInfo(TZ)
        d0 = datetime(2026, 11, 20, tzinfo=zone).timestamp()
        for p in pts(d0, 288):
            pass
        self.db.upsert_points(pts(d0, 288))
        d = day_detail(self.db, "2026-11-20", TZ, 4.32, 180, d0 + 2 * 86400)
        self.assertEqual(len(d["points"]), 288)
        self.assertAlmostEqual(d["totals"]["load_kwh"], 7.2, delta=0.1)
        self.assertIsNone(day_detail(self.db, "2026-11-10", TZ, 4.32, 180, d0 + 2 * 86400))
        keys = days_to_publish(self.db, TZ, d0 + 1.5 * 86400, back=3)
        self.assertEqual(keys[-1], "2026-11-21")   # today
        self.assertIn("2026-11-20", keys)
        self.db.set_state("days_final", "2026-11-20")
        self.db.set_state("day_today_at", str(d0 + 1.5 * 86400 - 60))
        self.assertNotIn("2026-11-20", days_to_publish(self.db, TZ, d0 + 1.5 * 86400, back=3))
        self.assertNotIn("2026-11-21", days_to_publish(self.db, TZ, d0 + 1.5 * 86400, back=3))


if __name__ == "__main__":
    unittest.main()
