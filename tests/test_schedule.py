import tempfile
import unittest

from deye_monitor import analytics as A
from deye_monitor.storage import Storage

H = 3600


class ScheduleAccuracyTest(unittest.TestCase):
    def test_late_early_missed_unplanned(self):
        slots = [(10 * H, 14 * H), (20 * H, 22 * H), (30 * H, 32 * H), (50 * H, 52 * H)]
        outages = [
            (10 * H + 600, 14 * H + 1800),   # 10 min late, ended 30 min late
            (19 * H + 50 * 60, 21 * H + 50 * 60),  # 10 min early both ends
            # (30..32) never happened
            (40 * H, 41 * H),                # unplanned
            (51 * H, None),                  # slot 50..52 still going on at `end`
        ]
        acc = A.schedule_accuracy(slots, outages, 0, 51.5 * H)
        self.assertEqual(acc["planned"], 3)          # the 50..52 slot hasn't ended
        self.assertEqual(acc["happened"], 2)
        self.assertEqual(acc["start_delta_min"], 0)  # (+10 −10)/2
        self.assertEqual(acc["end_delta_min"], 10)   # (+30 −10)/2
        self.assertEqual(acc["end_late_max_min"], 30)
        self.assertEqual(acc["unplanned"], 1)
        self.assertEqual(acc["unplanned_h"], 1.0)

    def test_storage_replaces_day(self):
        db = Storage(tempfile.mktemp(suffix=".db"))
        db.save_planned_day("2026-11-25", "ScheduleApplies", 0, [(10 * H, 14 * H)], 1)
        db.save_planned_day("2026-11-25", "ScheduleApplies", 0, [(15 * H, 19 * H)], 2)
        days, slots = db.planned_between(0, 86400)
        self.assertEqual(len(days), 1)
        self.assertEqual(slots, [(15 * H, 19 * H)])


if __name__ == "__main__":
    unittest.main()
