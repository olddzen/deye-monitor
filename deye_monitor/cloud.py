"""Deye Cloud OpenAPI reader (https://developer.deyecloud.com) — works without any device at home.

The logger uploads data to Deye Cloud every ~5 minutes; we poll the cloud and turn the latest
upload into a Reading. Grid voltage comes from /device/latest; if that key can't be found,
grid presence falls back to grid power from /station/latest.
"""
from __future__ import annotations

import hashlib
import logging
import time
from datetime import datetime
from typing import Any, Dict, List, Optional

import requests

from .inverter import Reading

log = logging.getLogger(__name__)

# Candidate measure-point names for grid voltage, most specific first (matched case-insensitively).
GRID_VOLTAGE_KEYS = ("GridVoltageL1L2", "GridVoltageL1", "GridVoltage", "G_V_L1", "GridVoltageL1N")

# Ukrainian hints for Deye fault codes seen on single-phase hybrids (alertName prefix → text).
FAULT_HINTS = {
    "F13": "змінився режим роботи (мережа/батарея)",
    "F25": "проблема з батареєю на боці AC (інвертор втратив батарею під навантаженням)",
    "F47": "завищена частота мережі — нестабільна мережа, часто при подачі/відключенні світла",
    "F56": "низька напруга батареї (DC)",
    "F58": "немає зв'язку з BMS батареї",
    "F64": "перегрів радіатора інвертора",
}


class StaleData(RuntimeError):
    pass


class DeyeCloudError(RuntimeError):
    pass


def sha256_hex(password: str) -> str:
    return hashlib.sha256(password.encode("utf-8")).hexdigest()


def _num(value: Any) -> Optional[float]:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _parse_time(value: Any) -> Optional[float]:
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)) or str(value).isdigit():
        v = float(value)
        return v / 1000 if v > 1e12 else v
    text = str(value).replace("Z", "+00:00")
    for fmt in (None, "%Y-%m-%d %H:%M:%S"):
        try:
            dt = datetime.fromisoformat(text) if fmt is None else datetime.strptime(text, fmt)
            return dt.timestamp()
        except ValueError:
            continue
    return None


class DeyeCloudClient:
    def __init__(self, base_url: str, app_id: str, app_secret: str, email: str, password_sha256: str):
        self.base = base_url.rstrip("/")
        self.app_id, self.app_secret = app_id, app_secret
        self.email, self.password_sha256 = email, password_sha256
        self._token: Optional[str] = None
        self._token_until = 0.0

    def _token_value(self) -> str:
        if self._token and time.time() < self._token_until:
            return self._token
        data = self._post("/v1.0/account/token", {"appSecret": self.app_secret, "email": self.email,
                                                  "password": self.password_sha256},
                          params={"appId": self.app_id}, auth=False)
        token = str(data.get("accessToken") or "")
        if not token:
            raise DeyeCloudError("no accessToken in token response")
        self._token = token[7:] if token.lower().startswith("bearer ") else token
        ttl = _num(data.get("expiresIn")) or 86400
        self._token_until = time.time() + max(300.0, ttl - 3600)
        return self._token

    def _post(self, path: str, body: dict, params: Optional[dict] = None, auth: bool = True) -> dict:
        headers = {"Content-Type": "application/json"}
        if auth:
            headers["Authorization"] = f"Bearer {self._token_value()}"
        try:
            resp = requests.post(self.base + path, json=body, params=params, headers=headers, timeout=20)
            data = resp.json()
        except Exception as exc:
            raise DeyeCloudError(f"{path}: {type(exc).__name__}") from None
        if not data.get("success", False):
            if auth and resp.status_code == 401:
                self._token = None
            raise DeyeCloudError(f"{path}: {data.get('code')} {data.get('msg')}")
        return data

    # --- endpoints ---
    def stations(self) -> List[dict]:
        return self._post("/v1.0/station/list", {"page": 1, "size": 20}).get("stationList") or []

    def devices(self, station_id: int) -> List[dict]:
        # /device/list is not open to personal accounts; /station/device is.
        return self._post("/v1.0/station/device", {"stationIds": [station_id]}).get("deviceListItems") or []

    def station_latest(self, station_id: int) -> dict:
        return self._post("/v1.0/station/latest", {"stationId": station_id})

    def device_latest(self, sn: str) -> dict:
        items = self._post("/v1.0/device/latest", {"deviceList": [sn]}).get("deviceDataList") or []
        return items[0] if items else {}

    def alerts(self, sn: str, start: float, end: float) -> List[dict]:
        return self._post("/v1.0/device/alertList", {
            "deviceSn": sn, "startTimestamp": int(start), "endTimestamp": int(end),
            "page": 1, "size": 100}).get("alertList") or []


def device_points(device_data: dict) -> Dict[str, Any]:
    """Flatten /device/latest dataList ([{key, value, unit}, ...]) into {key: value}."""
    points = {}
    for item in device_data.get("dataList") or []:
        key = item.get("key") or item.get("name")
        if key:
            points[str(key)] = item.get("value")
    return points


def find_grid_voltage(points: Dict[str, Any], preferred: str = "") -> Optional[float]:
    lowered = {k.lower(): v for k, v in points.items()}
    for key in ((preferred,) if preferred else ()) + GRID_VOLTAGE_KEYS:
        if key and key.lower() in lowered:
            return _num(lowered[key.lower()])
    for k, v in lowered.items():  # last resort: any "grid...voltage" point
        if "grid" in k and "volt" in k:
            return _num(v)
    return None


class CloudReader:
    offline_hint = ("Хмара Deye не отримує свіжих даних. Найімовірніше, у квартирі немає світла "
                    "і разом з ним інтернету, або стік втратив Wi-Fi.")

    def __init__(self, client: DeyeCloudClient, station_id: Optional[int] = None, device_sn: str = "",
                 grid_voltage_key: str = "", stale_after: int = 1200, alert_min_level: int = 2):
        self.client = client
        self.station_id, self.device_sn = station_id, device_sn
        self.grid_voltage_key = grid_voltage_key
        self.stale_after, self.alert_min_level = stale_after, alert_min_level
        self._alerts_checked = time.time() - 3600

    def _resolve(self) -> None:
        if not self.station_id:
            stations = self.client.stations()
            if not stations:
                raise DeyeCloudError("no stations in this Deye Cloud account")
            self.station_id = int(stations[0]["id"])
        if not self.device_sn:
            inverters = [d for d in self.client.devices(self.station_id) if str(d.get("deviceType", "")).upper() == "INVERTER"]
            if inverters:
                self.device_sn = str(inverters[0]["deviceSn"])

    def read(self) -> Reading:
        self._resolve()
        st = self.client.station_latest(self.station_id)
        updated = _parse_time(st.get("lastUpdateTime")) or time.time()
        if time.time() - updated > self.stale_after:
            raise StaleData(f"last cloud update {int(time.time() - updated)} s ago")

        points: Dict[str, Any] = {}
        device: Dict[str, Any] = {}
        if self.device_sn:
            try:
                device = self.client.device_latest(self.device_sn)
                points = device_points(device)
            except DeyeCloudError as exc:
                log.warning("device/latest failed: %s", exc)
        def pick(point: str, station_key: str) -> float:
            v = _num(points.get(point))
            if v is None:
                v = _num(st.get(station_key))
            return v or 0.0

        grid_power = _num(points.get("TotalGridPower"))
        if grid_power is None:
            grid_power = _num(st.get("wirePower")) or _num(st.get("gridPower")) or 0.0
        voltage = find_grid_voltage(points, self.grid_voltage_key)
        if voltage is None:  # fallback: any grid flow means grid is present
            voltage = 230.0 if abs(grid_power) > 5 else 0.0
        updated = max(updated, _parse_time(device.get("collectionTime")) or 0)

        return Reading(
            ts=updated,
            grid_voltage=voltage,
            grid_freq=_num(points.get("GridFrequency")) or 0.0,
            grid_power=int(grid_power),
            load_power=int(pick("TotalConsumptionPower", "consumptionPower")),
            pv_power=int(pick("TotalDCInputPower", "generationPower")),
            soc=int(pick("SOC", "batterySOC")),
            battery_voltage=_num(points.get("BatteryVoltage")) or 0.0,
            battery_power=int(pick("BatteryPower", "batteryPower")),
            run_state=2,
            alarms=0,
            faults=0,
            alerts=self._new_alerts(),
        )

    def _new_alerts(self) -> List[dict]:
        if not self.device_sn:
            return []
        now = time.time()
        try:
            items = self.client.alerts(self.device_sn, self._alerts_checked - 600, now)
        except DeyeCloudError as exc:
            log.warning("alertList failed: %s", exc)
            return []
        self._alerts_checked = now
        return [a for a in items if int(_num(a.get("level")) or 0) >= self.alert_min_level]
