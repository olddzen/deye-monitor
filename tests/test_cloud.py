import time

import pytest

from deye_monitor.cloud import CloudReader, StaleData, device_points, find_grid_voltage, sha256_hex
from tests.test_monitor import make, reading


class FakeClient:
    def __init__(self, updated=None, points=None, wire=150.0, alerts=()):
        self.updated = updated if updated is not None else time.time() - 60
        self.points = points if points is not None else [{"key": "GridVoltageL1L2", "value": "228.4", "unit": "V"},
                                                          {"key": "SOC", "value": "87", "unit": "%"}]
        self.wire, self._alerts = wire, list(alerts)

    def stations(self):
        return [{"id": 42, "name": "Home"}]

    def devices(self, station_id):
        return [{"deviceSn": "2401010001", "deviceType": "INVERTER"}]

    def station_latest(self, sid):
        assert sid == 42
        return {"batterySOC": None, "batteryPower": -120.0, "consumptionPower": 310.0, "wirePower": self.wire,
                "generationPower": 0.0, "lastUpdateTime": self.updated, "success": True}

    def device_latest(self, sn):
        return {"deviceSn": sn, "dataList": self.points}

    def alerts(self, sn, start, end):
        return self._alerts


def test_reading_from_cloud():
    r = CloudReader(FakeClient()).read()
    assert r.grid_voltage == pytest.approx(228.4) and r.soc == 87 and r.load_power == 310


def test_fallback_to_grid_power_when_no_voltage_point():
    assert CloudReader(FakeClient(points=[], wire=0)).read().grid_voltage == 0
    assert CloudReader(FakeClient(points=[], wire=200)).read().grid_voltage >= 180


def test_stale_cloud_data_raises():
    with pytest.raises(StaleData):
        CloudReader(FakeClient(updated=time.time() - 3600)).read()


def test_only_serious_alerts_kept():
    alerts = [{"alertId": "a", "level": 2, "alertName": "Grid lost"}, {"alertId": "b", "level": 0}]
    assert [a["alertId"] for a in CloudReader(FakeClient(alerts=alerts)).read().alerts] == ["a"]


def test_helpers():
    pts = device_points({"dataList": [{"key": "Some Grid Voltage", "value": "231"}]})
    assert find_grid_voltage(pts) == 231
    assert sha256_hex("abc").startswith("ba7816bf")


def test_alert_notified_once_and_repeat_snapshot_ignored():
    mon, sent, _ = make()
    t = 3_000_000.0
    alert = {"alertId": "x1", "level": 2, "alertName": "F47AC_OverFreq_Fault", "status": 0,
             "alertStartTime": t - 600, "alertEndTime": t - 300}
    mon.handle(reading(t, alerts=[alert]))
    mon.handle(reading(t, alerts=[alert]))           # same cloud upload polled again
    mon.handle(reading(t, volts=0))                  # same ts → grid change ignored
    assert sum("F47AC_OverFreq_Fault" in m for m in sent) == 1
    assert "частота" in sent[0] and "Тривала 5 хв" in sent[0]
    assert not any("вимкнули" in m for m in sent)
