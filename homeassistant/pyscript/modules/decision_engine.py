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
    # Master toggle off: the engine relinquishes control. Unlike OFF (an
    # active decision to shut devices down), DISABLED means "touch nothing".
    DISABLED = "DISABLED"


@dataclass(frozen=True)
class ClimateState:
    """Snapshot of all sensor readings the engine needs."""
    outside_temp_f: Optional[float]
    outside_rh_pct: Optional[float]
    indoor_temp_f: Optional[float]
    indoor_rh_pct: Optional[float]
    attic_temp_f: Optional[float]
    attic_rh_pct: Optional[float]


def has_required(s: ClimateState) -> bool:
    """True if we have the minimum sensors to make any decision.

    Module-level helper rather than @property on the dataclass because
    Pyscript's interpreter does not honor descriptor protocol — accessing
    a @property attribute returns the bare EvalFunc wrapper instead of
    invoking the getter. Explicit boolean expression rather than
    `all(... for ... in ...)` because Pyscript also does not implement
    generator expressions (NotImplementedError: ast_generatorexp).
    Plain CPython is fine either way.
    """
    return (
        s.outside_temp_f is not None
        and s.outside_rh_pct is not None
        and s.indoor_temp_f is not None
        and s.indoor_rh_pct is not None
    )


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
    # Percentage points the engaged-DEHUMIDIFY exit threshold sits below the
    # helper. With max_indoor_rh=45 and band=10, engage at >45 / exit at <=35.
    dehumidify_hysteresis_band: float = 10.0


@dataclass(frozen=True)
class Decision:
    """What the engine decided. Actuators consume this.

    Preset mode + temperature OR fan speed are mutually exclusive paths.
    COOLER_FULL uses the "set temperature" preset so the MagiqTouch firmware
    chooses fan speed to hit the target. COOLER_QUIET and DEHUMIDIFY use
    the fan-speed path because we want explicit control (4-cap for quiet,
    speed 2 for dehumidify).
    """
    mode: Mode
    cooler_hvac_mode: str               # "cool", "fan_only", "off"
    cooler_preset_mode: Optional[str]   # e.g. "Cooling: set temperature"
    cooler_set_temperature_f: Optional[int]  # target when in temp preset
    cooler_fan_speed: Optional[int]     # 1-10 when in fan-speed preset
    whf_on: bool
    reason: str
    # When True the actuator must not issue ANY device commands — devices
    # stay exactly as the user left them (master toggle off).
    hands_off: bool = False


TEMP_DEAD_BAND_F = 2.0
RH_DEAD_BAND = 5.0
# Dehumidify rule has strict humidity priority (engage at RH > helper, no
# entry buffer). The asymmetric exit threshold is controlled by
# Config.dehumidify_hysteresis_band — once engaged, stay engaged until RH
# drops to (helper - band). Default 10 points; user-tunable via the
# climate_balance_dehumidify_hysteresis_band input_number helper.
DEHUMIDIFY_FAN_SPEED = 2


def _in_quiet_hours(now: datetime) -> bool:
    """8 PM - 1 AM local time."""
    h = now.hour
    return h >= 20 or h < 1


def _off(reason: str) -> Decision:
    return Decision(
        mode=Mode.OFF, cooler_hvac_mode="off",
        cooler_preset_mode=None, cooler_set_temperature_f=None,
        cooler_fan_speed=None, whf_on=False, reason=reason,
    )


def _disabled(reason: str) -> Decision:
    return Decision(
        mode=Mode.DISABLED, cooler_hvac_mode="off",
        cooler_preset_mode=None, cooler_set_temperature_f=None,
        cooler_fan_speed=None, whf_on=False, reason=reason,
        hands_off=True,
    )


def _recirculate(reason: str) -> Decision:
    return Decision(
        mode=Mode.RECIRCULATE, cooler_hvac_mode="off",
        cooler_preset_mode=None, cooler_set_temperature_f=None,
        cooler_fan_speed=None, whf_on=False, reason=reason,
    )


def _whf_only(reason: str) -> Decision:
    return Decision(
        mode=Mode.WHF_ONLY, cooler_hvac_mode="off",
        cooler_preset_mode=None, cooler_set_temperature_f=None,
        cooler_fan_speed=None, whf_on=True, reason=reason,
    )


def _dehumidify(reason: str) -> Decision:
    return Decision(
        mode=Mode.DEHUMIDIFY, cooler_hvac_mode="fan_only",
        cooler_preset_mode=None, cooler_set_temperature_f=None,
        cooler_fan_speed=DEHUMIDIFY_FAN_SPEED, whf_on=True, reason=reason,
    )


def _cooler_full_temp(set_temp_f: int, reason: str) -> Decision:
    """COOLER_FULL via the MagiqTouch 'set temperature' preset — firmware
    chooses fan speed to hit the target. Used during normal hours."""
    return Decision(
        mode=Mode.COOLER_FULL, cooler_hvac_mode="cool",
        cooler_preset_mode="Cooling: set temperature",
        cooler_set_temperature_f=set_temp_f,
        cooler_fan_speed=None,
        whf_on=True, reason=reason,
    )


def _cooler_quiet_fan(fan_speed: int, reason: str) -> Decision:
    """COOLER_QUIET via explicit fan speed (capped at 4) — quiet hours
    need predictable, low fan operation."""
    return Decision(
        mode=Mode.COOLER_QUIET, cooler_hvac_mode="cool",
        cooler_preset_mode="Cooling: set fan speed",
        cooler_set_temperature_f=None,
        cooler_fan_speed=fan_speed,
        whf_on=True, reason=reason,
    )


COOLER_OVERSHOOT_F = 1.0  # Rule 4: accept achievable ≤ target + this margin.


def evaluate(
    s: ClimateState,
    c: Config,
    now: datetime,
    prev_mode: Optional[Mode] = None,
) -> Decision:
    """Compute the desired operating mode given current state, config, and time.

    `prev_mode` enables asymmetric hysteresis on rules 3 and 4: once a cooling
    mode is engaged, it sticks until indoor temp drops below the *exit* threshold
    (whf_target or target_temp) rather than re-evaluating against the *entry*
    threshold (whf_target + dead band, target_temp + dead band). Reduces cycling.
    Pass None on cold start; the engine treats that as "not currently running".

    Pure function — no I/O. See spec rules 1-6.
    """
    # Rule 1: master kill. Disabled = hands off — leave devices exactly as
    # they are. Vacation = nobody home — actively turn everything off.
    if not c.enabled:
        return _disabled(
            "Climate balance disabled (master toggle) — devices left as-is"
        )
    if c.vacation:
        return _off("Vacation mode — climate balance suspended")

    if not has_required(s):
        return _off("Required sensor unavailable — holding off")

    # Rule 2: dehumidify — asymmetric hysteresis on exit only
    # Entry: RH > helper.
    # Exit (when in DEHUMIDIFY): RH <= helper - dehumidify_hysteresis_band.
    # Humidity strict priority — engage immediately when above helper.
    in_dehumidify = prev_mode == Mode.DEHUMIDIFY
    attic_threshold = (c.max_attic_rh - c.dehumidify_hysteresis_band
                       if in_dehumidify else c.max_attic_rh)
    indoor_threshold = (c.max_indoor_rh - c.dehumidify_hysteresis_band
                        if in_dehumidify else c.max_indoor_rh)
    attic_too_humid = (s.attic_rh_pct is not None
                      and s.attic_rh_pct > attic_threshold)
    indoor_too_humid = s.indoor_rh_pct > indoor_threshold
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
        # Outside DP not strictly better than indoor — don't engage DEHUMIDIFY,
        # but DON'T short-circuit to RECIRCULATE either. Cooling (rules 3/4)
        # may still be the right action even if it can't fix humidity. Rules
        # 3 and 4 have their own absolute DP guard (outside_dp > max_dew_point_f)
        # to prevent bringing in genuinely muggy air.

    # Rule 3: free cooling (WHF only) — asymmetric hysteresis
    # Entry: indoor > whf_target. Exit: indoor ≤ whf_target - 2.
    # When already in WHF_ONLY, threshold drops by TEMP_DEAD_BAND_F so we keep
    # running until indoor falls well below target instead of bouncing right at it.
    outside_cooler = s.outside_temp_f < s.indoor_temp_f - TEMP_DEAD_BAND_F
    in_whf = prev_mode == Mode.WHF_ONLY
    whf_threshold = c.whf_target_f - TEMP_DEAD_BAND_F if in_whf else c.whf_target_f
    if outside_cooler and s.indoor_temp_f > whf_threshold:
        outside_dp = dew_point_f(s.outside_temp_f, s.outside_rh_pct)
        if outside_dp > c.max_dew_point_f:
            return _recirculate(
                f"Cooler outside ({s.outside_temp_f:.0f}°F) but outside dew "
                f"point {outside_dp:.0f}°F > limit {c.max_dew_point_f:.0f}°F "
                f"— recirculating"
            )
        return _whf_only(
            f"Free cooling — outside {s.outside_temp_f:.0f}°F < indoor "
            f"{s.indoor_temp_f:.0f}°F, target {c.whf_target_f:.0f}°F"
        )

    # Rule 4: active cooling — asymmetric hysteresis
    # Entry: indoor > target + 2. Exit: indoor ≤ target.
    in_cooler = prev_mode in (Mode.COOLER_FULL, Mode.COOLER_QUIET, Mode.RECIRCULATE)
    cool_threshold = c.target_temp_f if in_cooler else c.target_temp_f + TEMP_DEAD_BAND_F
    needs_cooling = s.indoor_temp_f > cool_threshold
    if needs_cooling:
        achievable = lookup_achievable_temp(s.outside_temp_f, s.outside_rh_pct)
        outside_dp = dew_point_f(s.outside_temp_f, s.outside_rh_pct)
        if outside_dp > c.max_dew_point_f:
            return _recirculate(
                f"Cooling needed but outside dew point {outside_dp:.0f}°F > limit "
                f"{c.max_dew_point_f:.0f}°F — recirculating"
            )
        # Accept achievable when EITHER:
        #   (a) near target: achievable ≤ target + COOLER_OVERSHOOT_F.
        #   (b) meaningful indoor relief: achievable ≤ indoor - TEMP_DEAD_BAND_F.
        # (b) covers the hot-day case where the chart can't reach target but the
        # cooler still delivers real cooling vs. the current indoor temp.
        # Without it, on a 95°F day with achievable=72 and indoor=78 we'd
        # recirculate and let indoor sit at 78°F instead of pulling it toward 72.
        if achievable is None:
            return _recirculate(
                f"Cooling needed but cooler chart says outside conditions are "
                f"out of effective range — recirculating"
            )
        near_target = achievable <= c.target_temp_f + COOLER_OVERSHOOT_F
        meaningful_relief = achievable <= s.indoor_temp_f - TEMP_DEAD_BAND_F
        if not (near_target or meaningful_relief):
            return _recirculate(
                f"Cooling needed but chart says achievable {achievable}°F > "
                f"target {c.target_temp_f:.0f}°F + {COOLER_OVERSHOOT_F:.0f}°F "
                f"and not {TEMP_DEAD_BAND_F:.0f}°F below indoor "
                f"{s.indoor_temp_f:.0f}°F — recirculating"
            )
        quiet = _in_quiet_hours(now)
        env_text = (
            f"indoor {s.indoor_temp_f:.0f}°F @ {s.indoor_rh_pct:.0f}% RH, "
            f"outside {s.outside_temp_f:.0f}°F @ {s.outside_rh_pct:.0f}% RH"
        )
        if quiet:
            headroom = c.target_temp_f - achievable
            speed = speed_for_headroom(headroom, quiet=True)
            return _cooler_quiet_fan(
                speed,
                f"Quiet cooler + WHF — fan speed {speed} (chart says we can "
                f"hit {achievable}°F; {env_text})"
            )
        # Normal hours: use temperature-set preset with the thermostat at the
        # USER's target. The chart's achievable temp only gates whether
        # cooling is worthwhile — setting the thermostat to it would drive
        # indoor below target on mild days (achievable < target) and is an
        # unreachable setpoint on hot days anyway. The MagiqTouch firmware
        # chooses fan speed; it simply bottoms out near achievable when
        # target is out of reach.
        set_temp = int(round(c.target_temp_f))
        return _cooler_full_temp(
            set_temp,
            f"cooler + WHF — thermostat {set_temp}°F "
            f"(chart says achievable {achievable}°F; {env_text})"
        )

    # Rule 6: idle
    return _off(
        f"All in range — indoor {s.indoor_temp_f:.0f}°F (target "
        f"{c.target_temp_f:.0f}°F), RH {s.indoor_rh_pct:.0f}%"
    )
