import tempfile
import unittest
from datetime import datetime
from zoneinfo import ZoneInfo

from deye_monitor import analytics as A
from deye_monitor.storage import Storage

TZ = "Europe/Kyiv"


class ApplianceTest(unittest.TestCase):
    def test_counter_and_delta_devices(self):
        db = Storage(tempfile.mktemp(suffix=".db"))
        t0 = datetime(2026, 11, 25, 8, tzinfo=ZoneInfo(TZ)).timestamp()
        for i in range(12):  # 5-min snapshots; reports every 15 min
            ts = t0 + i * 300
            end = t0 + (i // 3) * 900
            db.add_appliance_samples(ts, [
                # boiler plug: cumulative counter +100 Wh per report
                {"id": "plug", "label": "Бойлер", "kind": "plug", "energyWh": 1000 + (i // 3) * 100,
                 "deltaWh": 0, "reportEnd": end, "on": True},
                # TV: counter stuck at 0, 2.5 Wh per report window
                {"id": "tv", "label": "TV", "kind": "tv", "energyWh": 0, "deltaWh": 2.5, "reportEnd": end, "on": False},
            ])
        stats = {d["id"]: d for d in A.appliance_stats(db.appliance_samples_between(0, t0 + 86400), t0 + 3600, TZ)}
        self.assertAlmostEqual(stats["plug"]["today_kwh"], 0.3)      # 3 increments after the baseline
        self.assertAlmostEqual(stats["tv"]["today_kwh"], 0.01)       # 4 windows × 2.5 Wh
        self.assertEqual(stats["plug"]["label"], "Бойлер")
        self.assertEqual(len(stats["plug"]["daily_kwh"]), 14)
        self.assertAlmostEqual(stats["plug"]["daily_kwh"][-1], 0.3)

    def test_counter_reset(self):
        rows = [{"ts": i, "report_end": i, "energy_wh": e, "delta_wh": 0} for i, e in enumerate([500, 600, 50, 80])]
        self.assertEqual([wh for _, wh in A.appliance_increments(rows)], [100, 0, 30])


if __name__ == "__main__":
    unittest.main()
