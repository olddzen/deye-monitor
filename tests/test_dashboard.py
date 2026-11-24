import json

from deye_monitor import analytics as A
from deye_monitor.dashboard import build_data, heatmap, morning_due, morning_text
from deye_monitor.storage import Storage
from tests.test_analytics import series, ts
from tests.test_monitor import cfg


def db_with_week():
    db = Storage(":memory:")
    start = ts(2026, 11, 16)
    pts = series(start, 7 * 24 * 60, off_from=3 * 1440 + 1080, off_to=3 * 1440 + 1260)  # Thu 18:00–21:00
    db.upsert_points(pts)
    db.replace_outages(A.derive_outages(pts, 180, detailed=True), 0)
    return db, start


def test_heatmap_marks_thursday_evening():
    db, start = db_with_week()
    hm = heatmap(db.outages_between(start, start + 7 * 86400), start, start + 7 * 86400, "Europe/Kyiv")
    assert hm[3][18] > 0.9 and hm[3][19] > 0.9 and hm[0][18] == 0


def test_build_data_is_compact_json():
    db, start = db_with_week()
    data = build_data(db, cfg(), start + 7 * 86400)
    raw = json.dumps(data)
    assert len(raw) < 200_000
    assert data["week"]["count"] == 1 and abs(data["week"]["off_h"] - 3.0) < 0.2
    assert len(data["series7"]) > 900 and len(data["daily30"]) == 30
    assert data["outages"][0][2] is False


def test_morning_summary():
    db, start = db_with_week()
    c = cfg()
    fri_8 = ts(2026, 11, 20, 8, 5)
    assert morning_due(db, c, fri_8) == "morning:2026-11-20"
    assert morning_due(db, c, ts(2026, 11, 20, 7, 0)) is None
    db.set_state("last_morning", "morning:2026-11-20")
    assert morning_due(db, c, fri_8) is None
    text = morning_text(db, c, fri_8, 97, True)
    assert "Доброго ранку" in text and "Учора: 1 відкл." in text and "3 год" in text
    assert "Вночі світло було весь час" in text
