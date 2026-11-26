"""Regression tests for the review fixes."""
from deye_monitor import analytics as A
from deye_monitor.cloud import CloudReader, seal, unseal
from deye_monitor.storage import Storage
from deye_monitor.telegram import Telegram
from tests.test_cloud import FakeClient
from tests.test_monitor import make, reading


def pt(ts, v):
    return {"ts": ts, "grid_voltage": v}


def test_outage_next_to_data_gap_is_flagged():
    pts = [pt(0, 230), pt(300, 230), pt(30000, 0), pt(30300, 0), pt(30600, 230)]  # 8 h hole before
    (start, end, unsure), = A.derive_outages(pts, 180, detailed=True)
    assert unsure and start == 30000 and end == 30450
    exact = [pt(0, 230), pt(300, 0), pt(600, 0), pt(900, 230)]
    assert A.derive_outages(exact, 180, detailed=True) == [(150, 750, False)]


def test_uncertain_flag_is_stored_and_shown():
    mon, _, clock = make()
    mon.db.replace_outages([(100.0, 900.0, True), (2000.0, 2600.0, False)], 0)
    assert len(mon.db.uncertain_outages_between(0, 5000)) == 1
    clock["t"] = 5000
    text = mon.cmd_history()
    assert "≥ " in text and "дірка" in text


def test_bad_message_does_not_block_later_commands(monkeypatch):
    tg = Telegram("x", chat_id=1)
    sent = []

    def fake_call(method, http_timeout=15, **params):
        if method == "getUpdates":
            return [{"update_id": 10, "message": {"chat": {"id": 1}, "text": "/boom"}},
                    {"update_id": 11, "message": {"chat": {"id": 1}, "text": "/ok"}}]
        if method == "sendMessage":
            if "boom" in params["text"]:
                raise RuntimeError("Telegram sendMessage: can't parse entities")
            sent.append(params["text"])
        return True

    monkeypatch.setattr(tg, "_call", fake_call)
    offset = tg.poll_once({"boom": lambda: "boom <b", "ok": lambda: "fine"}, 0)
    assert offset == 12 and sent == ["fine"]


def test_command_error_text_is_escaped(monkeypatch):
    tg = Telegram("x", chat_id=1)
    sent = []
    monkeypatch.setattr(tg, "_call", lambda m, http_timeout=15, **p: sent.append(p.get("text")) or True)

    def broken():
        raise ValueError("voltage < 40V & low")

    tg._handle({"chat": {"id": 1}, "text": "/x"}, {"x": broken})
    assert "&lt; 40V &amp; low" in sent[0]


def test_deye_alert_text_is_escaped():
    mon, sent, _ = make()
    a = {"alertId": "z", "level": 2, "alertName": "F99<odd>", "description": "U < 40 V & more", "status": 1}
    mon.handle(reading(1_000_000.0, alerts=[a]))
    assert "F99&lt;odd&gt;" in sent[0] and "U &lt; 40 V &amp; more" in sent[0]


def test_silent_bms_is_unknown_not_zero():
    pts = [{"key": "GridVoltageL1L2", "value": "220"}, {"key": "SOC", "value": "0"},
           {"key": "Temperature- Battery", "value": "-100"}]
    r = CloudReader(FakeClient(points=pts)).read()
    assert r.soc is None
    mon, sent, _ = make(debounce=1)
    mon.handle(reading(1_000_000.0))
    mon.handle(reading(1_000_060.0, volts=0, soc=None))
    assert "немає даних від BMS" in sent[-1]
    assert not any("поріг" in m for m in sent)  # no false low-battery alert
    assert "немає даних від BMS" in mon.cmd_status()


def test_token_is_sealed():
    sealed = seal("secret", "123:tok")
    assert "tok" not in sealed and unseal("secret", sealed) == "123:tok"
    assert unseal("other", sealed) is None and unseal("secret", "999:plain") is None


def test_long_open_outage_keeps_its_start():
    db = Storage(":memory:")
    day = 86400
    pts = [pt(0, 230), pt(300, 0)] + [pt(300 + i * 300, 0) for i in range(1, 5 * 288)]
    db.upsert_points(pts)
    db.replace_outages(A.derive_outages(pts, 180, detailed=True), 0)
    assert db.current_outage() == 150
    # a later rebuild that only looks at the last 3 days must not move the start
    since = pts[-1]["ts"] - 3 * day
    frm = min(since, db.current_outage()) - day
    db.replace_outages(A.derive_outages(db.points_between(frm, pts[-1]["ts"]), 180, detailed=True), since)
    assert db.current_outage() == 150
