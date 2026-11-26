import unittest

from deye_monitor import analytics as A

TZ = "Europe/Kyiv"


class RealDrainTest(unittest.TestCase):
    def test_self_use_from_soc_drop(self):
        # 5 h outage, 99 → 96 % of 11.8 kWh = 354 Wh → ~71 W while the flat used 37 W
        o = A.OutageBattery(start=0, end=5 * 3600, soc_start=99, soc_min=96, discharged_kwh=0.1, avg_load_w=37)
        d = A.real_drain([o], 11.8)
        self.assertEqual(d.samples, 1)
        self.assertAlmostEqual(d.drain_w, 70.8, places=1)
        self.assertAlmostEqual(d.self_use_w, 33.8, places=1)

    def test_short_or_shallow_outages_ignored(self):
        short = A.OutageBattery(0, 3600, 99, 90, 0, 100)
        shallow = A.OutageBattery(0, 6 * 3600, 99, 98, 0, 30)
        self.assertEqual(A.real_drain([short, shallow], 11.8).samples, 0)
        self.assertIsNone(A.real_drain([], 11.8).self_use_w)


class PowerPeaksTest(unittest.TestCase):
    def test_peaks_and_near_limit(self):
        base = 1795125600  # 2026-11-20 00:00 Kyiv
        pts = [
            {"ts": base + 3600, "grid_voltage": 225, "grid_power": 7200, "load_power": 4000},   # on grid, 90 % of 8 kW
            {"ts": base + 7200, "grid_voltage": 225, "grid_power": 300, "load_power": 200},
            {"ts": base + 86400 + 60, "grid_voltage": 0, "grid_power": 0, "load_power": 5300},  # off grid, 88 % of 6 kW
        ]
        r = A.power_peaks(pts, base, base + 2 * 86400, TZ, threshold=180)
        self.assertEqual(r["max_w"], 7200)
        self.assertTrue(r["max_on_grid"])
        self.assertEqual(r["near_limit"], 2)
        self.assertEqual([d[1] for d in r["days"]], [7200, 5300])
        self.assertTrue(all(d[3] for d in r["days"]))


if __name__ == "__main__":
    unittest.main()
