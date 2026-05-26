"""Pure decision engine for climate balance.

Inputs: current sensor readings + helper config + wall-clock time.
Output: a Decision describing desired mode, device actuations, and human-readable reason.

This module imports nothing from Pyscript so it is unit-testable.
Lives under pyscript/modules/ because Pyscript only resolves imports
from that subdir (trigger files at /config/pyscript/ are NOT in sys.path).
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from typing import Optional

from cooler_chart import lookup_achievable_temp
from dew_point import dew_point_f
from fan_speed import speed_for_headroom


class Mode(Enum):
    OFF = "OFF"
    WHF_ONLY = "WHF_ONLY"
    COOLER_FULL = "COOLER_FULL"
    COOLER_QUIET = "COOLER_QUIET"
    DEHUMIDIFY = "DEHUMIDIFY"
    RECIRCULATE = "RECIRCULATE"


@dataclass(frozen=True)
class ClimateState:
    """Snapshot of all sensor readings the engine needs."""
    outside_temp_f: Optional[float]
    outside_rh_pct: Optional[float]
    indoor_temp_f: Optional[float]
    indoor_rh_pct: Optional[float]
    attic_temp_f: Optional[float]
    attic_rh_pct: Optional[float]

    @property
    def has_required(self) -> bool:
        """True if we have the minimum sensors to make any decision."""
        return all(v is not None for v in (
            self.outside_temp_f, self.outside_rh_pct,
            self.indoor_temp_f, self.indoor_rh_pct,
        ))


@dataclass(frozen=True)
class Config:
    """Snapshot of all helper input values."""
    enabled: bool
    vacation: bool
    target_temp_f: float
    whf_target_f: float
    max_indoor_rh: float
    max_attic_rh: float
    max_dew_point_f: float


@dataclass(frozen=True)
class Decision:
    """What the engine decided. Actuators consume this."""
    mode: Mode
    cooler_hvac_mode: str          # "cool", "fan_only", "off"
    cooler_fan_speed: Optional[int]  # 0-10 or None when off
    whf_on: bool
    reason: str                    # human-readable, goes to sensor.climate_balance_reason


TEMP_DEAD_BAND_F = 2.0
RH_DEAD_BAND = 5.0
DEHUMIDIFY_FAN_SPEED = 2
