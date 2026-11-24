from datetime import datetime
from zoneinfo import ZoneInfo

from deye_monitor import analytics as A
from deye_monitor.reports import build_report, due_reports
from deye_monitor.storage import Storage
from tests.test_monitor import cfg

KYIV = ZoneInfo("Europe/Kyiv")


def ts(y, m, d, h=0, mi=0):
    return datetime(y, m, d, h, mi, tzinfo=KYIV).timestamp()


def series(start, minutes, off_from=None, off_to=None, load=300, soc0=100.0):
    """5-min points; grid off between off_from..off_to minutes, battery covers the load."""
    pts, soc = [], soc0
    for i in range(0, minutes, 5):
        off = off_from is not None and off_from <= i < off_to
        if off:
            soc -= load * 5 / 60 / 11800 * 100
        pts.append({"ts": int(start + i * 60), "grid_voltage": 0.0 if off else 230.0, "grid_freq": 50.0,
                    "grid_power": 0 if off else load, "load_power": load, "soc": round(soc, 2),
                    "battery_power": load if off else 0, "battery_temp": 21.0, "dc_temp": 45.0, "ac_temp": 35.0,
                    "discharge_total": 5.0})
    return pts


def test_derive_outages_midpoints_and_open_tail():
    pts = series(0, 120, off_from=30, off_to=60)
    assert A.derive_outages(pts, 180) == [(27.5 * 60, 57.5 * 60)]
    tail = series(0, 60, off_from=40, off_to=60)
    assert A.derive_outages(tail, 180) == [(37.5 * 60, None)]


def test_integration_and_battery_capacity():
    pts = series(0, 600, off_from=60, off_to=480, load=1000)   # 7 h at 1 kW → 7 kWh, ~59 % drop
    out = A.derive_outages(pts, 180)
    per = A.battery_per_outage(pts, out, now=600 * 60)
    assert abs(per[0].discharged_kwh - 7.0) < 0.2
    assert abs(per[0].capacity_kwh - 11.8) < 0.6
    b = A.battery_stats(pts, per, 11.8)
    assert b.health and 0.95 < b.health < 1.05
    assert A.integrate_kwh(pts, "load_power") > 9.5


def test_gaps_are_not_integrated():
    pts = [{"ts": 0, "load_power": 1000}, {"ts": 300, "load_power": 1000}, {"ts": 7200, "load_power": 1000}]
    assert abs(A.integrate_kwh(pts, "load_power") - 1000 * 300 / 3600 / 1000) < 1e-9


def test_hourly_profile_and_busy_ranges():
    day = ts(2026, 11, 2)
    outs = [(day + 18 * 3600, day + 20 * 3600)]
    prof = A.hourly_profile(outs, day, day + 86400, "Europe/Kyiv")
    assert prof[18] == 1.0 and prof[19] == 1.0 and prof[17] == 0
    assert A.busy_ranges(prof) == [(18, 20)]


def test_report_and_schedule():
    db = Storage(":memory:")
    start = ts(2026, 11, 16)
    pts = series(start, 7 * 24 * 60, off_from=3 * 1440 + 1080, off_to=3 * 1440 + 1260)
    db.upsert_points(pts)
    db.replace_outages(A.derive_outages(pts, 180), 0)
    db.upsert_alert("a1", "F47AC_OverFreq_Fault", 2, start + 3600, start + 4000)
    c = cfg()
    now = ts(2026, 11, 23, 10)  # Monday 10:00
    db.set_state("last_monthly", "month:2026-10")
    due = due_reports(db, c, now)
    assert [d[0] for d in due] == ["week:2026-11-16"]
    assert due[0][3] == "Тиждень 16–22 листопада"
    text, png = build_report(db, c, due[0][1], due[0][2], due[0][3])
    assert "Відключення:</b> 1" in text and "3 год" in text and "F47 ×1" in text
    assert png and png[:4] == b"\x89PNG"
    db.set_state("last_weekly", due[0][0])
    assert due_reports(db, c, now + 3600) == []


def test_sparse_period_is_skipped():
    from deye_monitor.reports import send_due_reports
    db = Storage(":memory:")
    db.upsert_points(series(ts(2026, 10, 30), 2 * 1440))      # 2 days of October only
    db.set_state("last_weekly", "week:2026-11-23")
    sent = []
    n = send_due_reports(db, cfg(), ts(2026, 11, 2, 10), sent.append, lambda png, cap: None)
    assert n == 0 and not sent and db.get_state("last_monthly") == "month:2026-10"


def test_monthly_due_on_first():
    db = Storage(":memory:")
    db.set_state("last_weekly", "week:2026-11-24")
    keys = [d[0] for d in due_reports(db, cfg(), ts(2026, 12, 1, 9, 30))]
    assert "month:2026-11" in keys
