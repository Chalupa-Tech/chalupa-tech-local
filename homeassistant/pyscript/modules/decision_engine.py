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


def _in_quiet_hours(now: datetime) -> bool:
    """8 PM - 1 AM local time."""
    h = now.hour
    return h >= 20 or h < 1


def _off(reason: str) -> Decision:
    return Decision(
        mode=Mode.OFF, cooler_hvac_mode="off",
        cooler_fan_speed=None, whf_on=False, reason=reason,
    )


def _recirculate(reason: str) -> Decision:
    return Decision(
        mode=Mode.RECIRCULATE, cooler_hvac_mode="off",
        cooler_fan_speed=None, whf_on=False, reason=reason,
    )


def _whf_only(reason: str) -> Decision:
    return Decision(
        mode=Mode.WHF_ONLY, cooler_hvac_mode="off",
        cooler_fan_speed=None, whf_on=True, reason=reason,
    )


def _dehumidify(reason: str) -> Decision:
    return Decision(
        mode=Mode.DEHUMIDIFY, cooler_hvac_mode="fan_only",
        cooler_fan_speed=DEHUMIDIFY_FAN_SPEED, whf_on=True, reason=reason,
    )


def _cooler(quiet: bool, fan_speed: int, reason: str) -> Decision:
    return Decision(
        mode=Mode.COOLER_QUIET if quiet else Mode.COOLER_FULL,
        cooler_hvac_mode="cool", cooler_fan_speed=fan_speed,
        whf_on=True, reason=reason,
    )


def evaluate(s: ClimateState, c: Config, now: datetime) -> Decision:
    """Compute the desired operating mode given current state, config, and time.

    Pure function — no I/O. See spec rules 1-6.
    """
    # Rule 1: master kill
    if not c.enabled:
        return _off("Climate balance disabled (master toggle)")
    if c.vacation:
        return _off("Vacation mode — climate balance suspended")

    if not s.has_required:
        return _off("Required sensor unavailable — holding off")

    # Rule 2: dehumidify (attic OR indoor RH above limit + dead band)
    attic_too_humid = (s.attic_rh_pct is not None
                      and s.attic_rh_pct > c.max_attic_rh + RH_DEAD_BAND)
    indoor_too_humid = s.indoor_rh_pct > c.max_indoor_rh + RH_DEAD_BAND
    if attic_too_humid or indoor_too_humid:
        outside_dp = dew_point_f(s.outside_temp_f, s.outside_rh_pct)
        indoor_dp = dew_point_f(s.indoor_temp_f, s.indoor_rh_pct)
        if outside_dp < indoor_dp:
            src = (f"attic RH {s.attic_rh_pct:.0f}%" if attic_too_humid
                   else f"indoor RH {s.indoor_rh_pct:.0f}%")
            return _dehumidify(
                f"Dehumidify — {src} above limit; outside DP {outside_dp:.0f}°F "
                f"< indoor DP {indoor_dp:.0f}°F so pulling outside air helps"
            )
        return _recirculate(
            f"Indoor humid but outside dew point {outside_dp:.0f}°F worse than "
            f"indoor {indoor_dp:.0f}°F — recirculating only"
        )

    # Rule 3: free cooling (WHF only)
    outside_cooler = s.outside_temp_f < s.indoor_temp_f - TEMP_DEAD_BAND_F
    above_whf_target = s.indoor_temp_f > c.whf_target_f
    if outside_cooler and above_whf_target:
        return _whf_only(
            f"Free cooling — outside {s.outside_temp_f:.0f}°F < indoor "
            f"{s.indoor_temp_f:.0f}°F, target {c.whf_target_f:.0f}°F"
        )

    # Rule 4: active cooling
    needs_cooling = s.indoor_temp_f > c.target_temp_f + TEMP_DEAD_BAND_F
    if needs_cooling:
        achievable = lookup_achievable_temp(s.outside_temp_f, s.outside_rh_pct)
        outside_dp = dew_point_f(s.outside_temp_f, s.outside_rh_pct)
        if outside_dp > c.max_dew_point_f:
            return _recirculate(
                f"Cooling needed but outside dew point {outside_dp:.0f}°F > limit "
                f"{c.max_dew_point_f:.0f}°F — recirculating"
            )
        if achievable is None or achievable > c.target_temp_f:
            return _recirculate(
                f"Cooling needed but chart says achievable "
                f"{achievable if achievable is not None else 'N/A'} > target "
                f"{c.target_temp_f:.0f}°F — recirculating"
            )
        quiet = _in_quiet_hours(now)
        headroom = c.target_temp_f - achievable
        speed = speed_for_headroom(headroom, quiet=quiet)
        return _cooler(
            quiet, speed,
            f"{'Quiet ' if quiet else ''}cooler + WHF — chart says we can hit "
            f"{achievable}°F (outside {s.outside_temp_f:.0f}°F @ "
            f"{s.outside_rh_pct:.0f}% RH, fan speed {speed})"
        )

    # Rule 6: idle
    return _off(
        f"All in range — indoor {s.indoor_temp_f:.0f}°F (target "
        f"{c.target_temp_f:.0f}°F), RH {s.indoor_rh_pct:.0f}%"
    )
