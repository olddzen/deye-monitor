"""Reading the Deye hybrid inverter over the Solarman V5 protocol (Wi-Fi logger stick, port 8899).

Register map for single-phase low-voltage hybrids (SUN-xK-SG03LP1 / SG04LP1 / SG05LP1).
Values come from the community map used by the Home Assistant "solarman" integration.
Run `python -m deye_monitor probe` once and compare with the Deye/Solarman app to confirm.
"""
from __future__ import annotations

import math
import time
from dataclasses import dataclass, asdict, field
from typing import List


RUN_STATES = {0: "Standby", 1: "Self-check", 2: "Normal", 3: "Alarm", 4: "Fault"}

REG_RUN_STATE = 59
REG_GRID_FREQ = 79          # x0.01 Hz
BLOCK_START = 150           # read 150..196 in one request
BLOCK_LEN = 47
REG_GRID_VOLTAGE = 150      # x0.1 V
REG_GRID_POWER = 169        # W, signed: + import, - export
REG_LOAD_POWER = 178        # W
REG_BATTERY_VOLTAGE = 183   # x0.01 V
REG_BATTERY_SOC = 184       # %
REG_PV1_POWER = 186         # W
REG_PV2_POWER = 187         # W
REG_BATTERY_POWER = 190     # W, signed: + discharge, - charge
REG_ALARMS = 553            # 553..554 warnings, 555..558 faults


def s16(v: int) -> int:
    return v - 0x10000 if v >= 0x8000 else v


@dataclass
class Reading:
    ts: float
    grid_voltage: float
    grid_freq: float
    grid_power: int
    load_power: int
    pv_power: int
    soc: int
    battery_voltage: float
    battery_power: int
    run_state: int
    alarms: int
    faults: int
    alerts: List[dict] = field(default_factory=list)  # cloud mode: new serious alerts

    @property
    def run_state_name(self) -> str:
        return RUN_STATES.get(self.run_state, f"Unknown({self.run_state})")

    @property
    def has_problem(self) -> bool:
        return self.run_state in (3, 4) or self.faults != 0

    def as_dict(self) -> dict:
        return asdict(self)


def _join(words) -> int:
    value = 0
    for w in words:
        value = (value << 16) | w
    return value


class SolarmanReader:
    def __init__(self, ip: str, serial: int, port: int = 8899, slave_id: int = 1):
        self.ip, self.serial, self.port, self.slave_id = ip, serial, port, slave_id

    def read(self) -> Reading:
        from pysolarmanv5 import PySolarmanV5  # imported lazily so simulate mode needs no deps

        client = PySolarmanV5(self.ip, self.serial, port=self.port, mb_slave_id=self.slave_id,
                              verbose=False, socket_timeout=10)
        try:
            run_state = client.read_holding_registers(REG_RUN_STATE, 1)[0]
            freq = client.read_holding_registers(REG_GRID_FREQ, 1)[0]
            block = client.read_holding_registers(BLOCK_START, BLOCK_LEN)
            flags = client.read_holding_registers(REG_ALARMS, 6)
        finally:
            try:
                client.disconnect()
            except Exception:
                pass

        r = lambda addr: block[addr - BLOCK_START]  # noqa: E731
        return Reading(
            ts=time.time(),
            grid_voltage=r(REG_GRID_VOLTAGE) / 10,
            grid_freq=freq / 100,
            grid_power=s16(r(REG_GRID_POWER)),
            load_power=r(REG_LOAD_POWER),
            pv_power=r(REG_PV1_POWER) + r(REG_PV2_POWER),
            soc=r(REG_BATTERY_SOC),
            battery_voltage=r(REG_BATTERY_VOLTAGE) / 100,
            battery_power=s16(r(REG_BATTERY_POWER)),
            run_state=run_state,
            alarms=_join(flags[0:2]),
            faults=_join(flags[2:6]),
        )


class SimulatedReader:
    """Fake inverter for trying the bot without hardware: grid toggles every `period` seconds."""

    def __init__(self, period: int = 120):
        self.period = period
        self.soc = 80.0

    def read(self) -> Reading:
        now = time.time()
        grid_on = int(now // self.period) % 2 == 0
        self.soc = min(100.0, self.soc + 0.5) if grid_on else max(5.0, self.soc - 1.5)
        load = int(400 + 200 * math.sin(now / 60))
        return Reading(
            ts=now,
            grid_voltage=231.0 if grid_on else 0.0,
            grid_freq=50.0 if grid_on else 0.0,
            grid_power=load + 300 if grid_on else 0,
            load_power=load,
            pv_power=0,
            soc=int(self.soc),
            battery_voltage=52.0,
            battery_power=-300 if grid_on else load,
            run_state=2,
            alarms=0,
            faults=0,
        )


