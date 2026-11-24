from dataclasses import replace

from deye_monitor.config import Config
from deye_monitor.inverter import Reading
from deye_monitor.monitor import GridDetector, Monitor
from deye_monitor.stats import compute_stats, fmt_duration
from deye_monitor.storage import Storage


def cfg(**kw):
    base = dict(mode="simulate", logger_ip="", logger_serial=0, logger_port=8899, slave_id=1,
                poll_interval=30, grid_voltage_min=180.0, debounce=2, unreachable_alert_after=600,
                soc_alerts=(30, 15), sample_every=300, keep_days=90, tg_token="", tg_chat_id=None,
                db_path=":memory:", tz="Europe/Kyiv")
    base.update(kw)
    return Config(**base)


def reading(ts, volts=230.0, soc=80, **kw):
    r = Reading(ts=ts, grid_voltage=volts, grid_freq=50.0, grid_power=0, load_power=500, pv_power=0,
                soc=soc, battery_voltage=52.0, battery_power=500, run_state=2, alarms=0, faults=0)
    return replace(r, **kw)


class FakeReader:
    def read(self):
        raise OSError("timeout")


def make(**kw):
    sent = []
    clock = {"t": 1_000_000.0}
    mon = Monitor(cfg(**kw), Storage(":memory:"), FakeReader(), sent.append, clock=lambda: clock["t"])
    return mon, sent, clock


def test_detector_debounce():
    d = GridDetector(180, 2)
    assert d.update(230) is None and d.state is True
    assert d.update(0) is None          # one bad reading is not enough
    assert d.update(230) is None
    assert d.update(0) is None
    assert d.update(0) is False         # second in a row → off
    assert d.update(231) is None
    assert d.update(231) is True


def test_outage_cycle_and_stats():
    mon, sent, _ = make()
    t = 1_000_000.0
    mon.handle(reading(t))                      # initial: on, silent
    mon.handle(reading(t + 30, volts=0))
    mon.handle(reading(t + 60, volts=0))        # off confirmed
    assert "вимкнули" in sent[-1]
    mon.handle(reading(t + 3660, volts=229))
    mon.handle(reading(t + 3690, volts=229))    # on confirmed
    assert "дали" in sent[-1] and "1 год" in sent[-1]
    assert len(sent) == 2
    s = compute_stats(mon.db.outages_between(t, t + 7200), t, t + 7200)
    assert s.count == 1 and abs(s.off_seconds - 3630) < 1


def test_battery_alert_once_per_level():
    mon, sent, _ = make(debounce=1)
    t = 2_000_000.0
    mon.handle(reading(t))
    mon.handle(reading(t + 30, volts=0, soc=50))
    mon.handle(reading(t + 60, volts=0, soc=29))
    mon.handle(reading(t + 90, volts=0, soc=28))
    mon.handle(reading(t + 120, volts=0, soc=10))  # jumps past 15
    battery = [m for m in sent if "Батарея" in m and "поріг" in m]
    assert len(battery) == 2


def test_fault_and_unreachable():
    mon, sent, clock = make()
    t = clock["t"]
    mon.handle(reading(t))
    mon.handle(reading(t + 30, run_state=4, faults=0x40))
    mon.handle(reading(t + 60, run_state=4, faults=0x40))   # same fault: no repeat
    mon.handle(reading(t + 90))
    assert sum("Fault" in m for m in sent) == 1 and "зникла" in sent[-1]
    clock["t"] = t + 90 + 700
    mon.tick()
    assert "Немає даних" in sent[-1]
    mon.handle(reading(clock["t"] + 30))
    assert "відновлено" in sent[-1]


def test_open_outage_clipped():
    s = compute_stats([(50.0, None)], 0.0, 100.0)
    assert s.count == 1 and s.off_seconds == 50 and s.availability == 50


def test_fmt_duration():
    assert fmt_duration(30) == "менше хвилини"
    assert fmt_duration(3 * 3600 + 12 * 60) == "3 год 12 хв"
    assert fmt_duration(26 * 3600) == "1 д 2 год"


def test_state_survives_restart():
    mon, sent, _ = make(debounce=1)
    t = 4_000_000.0
    mon.handle(reading(t))
    mon.handle(reading(t + 60, volts=0, soc=25))     # off + battery alert
    mon.save_state()
    mon2 = Monitor(mon.cfg, mon.db, mon.reader, sent.append, clock=mon.clock)
    mon2.load_state()
    mon2.handle(reading(t + 60, volts=0, soc=25))    # same snapshot after restart: nothing new
    mon2.handle(reading(t + 120, volts=0, soc=24))   # same level: no repeat alert
    mon2.handle(reading(t + 180, volts=231))
    assert sum("Батарея" in m and "поріг" in m for m in sent) == 1
    assert "дали" in sent[-1]
