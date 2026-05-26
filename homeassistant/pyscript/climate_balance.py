"""Pyscript entry point for climate balance.

Phase 1: derived sensors (dew points + chart achievable).
Phase 2 (this version): + decision engine in DRY-RUN mode.
  - Threads effective-mode through evaluate() for asymmetric hysteresis
  - Enforces 10-min minimum runtime per mode (cycling cap at ≤3 cycles/hr)
  - Updates sensor.climate_balance_mode / _reason / _status
  - Sends Discord notification on mode transition (prefixed [DRY-RUN])
  - Does NOT call climate.set_* or switch.turn_* yet

Phase 3 will flip _ACTUATE = True and wire actuators + manual override.
"""
from datetime import datetime, timedelta

from cooler_chart import lookup_achievable_temp
from decision_engine import ClimateState, Config, Decision, Mode, evaluate
from dew_point import dew_point_f


_ACTUATE = False   # Phase 3 flips this to True
_DISCORD_TARGET = "1508674689256652850"
_MIN_RUNTIME = timedelta(minutes=10)


# Derived sensor entity IDs
_S_OUTSIDE_DP = "sensor.outside_dew_point"
_S_INDOOR_DP = "sensor.indoor_dew_point"
_S_ACHIEVABLE = "sensor.evap_cooler_achievable_temp"
_S_MODE = "sensor.climate_balance_mode"
_S_REASON = "sensor.climate_balance_reason"
_S_STATUS = "sensor.climate_balance_status"

# Input sensors
_S_OUT_T = "sensor.stormin_norman_temperature"
_S_OUT_RH = "sensor.stormin_norman_humidity"
_S_AVG_T = "sensor.average_temperature"
_S_AVG_RH = "sensor.average_humidity"
_S_ATTIC_T = "sensor.attic_sensor_air_temperature"
_S_ATTIC_RH = "sensor.attic_sensor_humidity"

# Helpers
_H_ENABLED = "input_boolean.climate_balance_enabled"
_H_VACATION = "input_boolean.climate_balance_vacation"
_H_TARGET = "input_number.climate_balance_target_temp"
_H_WHF_TARGET = "input_number.climate_balance_whf_target"
_H_MAX_INDOOR_RH = "input_number.climate_balance_max_indoor_rh"
_H_MAX_ATTIC_RH = "input_number.climate_balance_max_attic_rh"
_H_MAX_DP = "input_number.climate_balance_max_dew_point"

# Module-scoped state for hysteresis + min-runtime. Pyscript reloads reset these
# to None, at which point the next evaluation cold-starts (prev_mode=None, no
# min-runtime gate). That's fine — a reload is a known good time to allow a
# fresh transition.
_effective_mode = None
_effective_decision = None
_last_change_ts = None


# Mode → emoji for Discord
_MODE_EMOJI = {
    Mode.OFF: "✅",
    Mode.WHF_ONLY: "🌬️",
    Mode.COOLER_FULL: "❄️",
    Mode.COOLER_QUIET: "🌙",
    Mode.DEHUMIDIFY: "💧",
    Mode.RECIRCULATE: "🛑",
}


def _read_float(entity_id):
    raw = state.get(entity_id)
    if raw in (None, "unknown", "unavailable", ""):
        return None
    try:
        return float(raw)
    except (TypeError, ValueError):
        return None


def _read_bool(entity_id):
    return state.get(entity_id) == "on"


def _set_sensor(entity_id, value, unit=None, attrs=None):
    base_attrs = {"source": "pyscript:climate_balance"}
    if unit:
        base_attrs["unit_of_measurement"] = unit
        if unit == "°F":
            base_attrs["device_class"] = "temperature"
            base_attrs["icon"] = "mdi:thermometer"
    if attrs:
        base_attrs.update(attrs)
    display = value if value is not None else "unavailable"
    state.set(entity_id, display, new_attributes=base_attrs)


def _build_state():
    return ClimateState(
        outside_temp_f=_read_float(_S_OUT_T),
        outside_rh_pct=_read_float(_S_OUT_RH),
        indoor_temp_f=_read_float(_S_AVG_T),
        indoor_rh_pct=_read_float(_S_AVG_RH),
        attic_temp_f=_read_float(_S_ATTIC_T),
        attic_rh_pct=_read_float(_S_ATTIC_RH),
    )


def _build_config():
    return Config(
        enabled=_read_bool(_H_ENABLED),
        vacation=_read_bool(_H_VACATION),
        target_temp_f=_read_float(_H_TARGET) or 70.0,
        whf_target_f=_read_float(_H_WHF_TARGET) or 68.0,
        max_indoor_rh=_read_float(_H_MAX_INDOOR_RH) or 45.0,
        max_attic_rh=_read_float(_H_MAX_ATTIC_RH) or 45.0,
        max_dew_point_f=_read_float(_H_MAX_DP) or 60.0,
    )


def _recompute_derived(s):
    out_dp = (round(dew_point_f(s.outside_temp_f, s.outside_rh_pct), 1)
              if s.outside_temp_f is not None and s.outside_rh_pct
              and s.outside_rh_pct > 0 else None)
    _set_sensor(_S_OUTSIDE_DP, out_dp, "°F",
                attrs={"friendly_name": "Outside Dew Point"})

    in_dp = (round(dew_point_f(s.indoor_temp_f, s.indoor_rh_pct), 1)
             if s.indoor_temp_f is not None and s.indoor_rh_pct
             and s.indoor_rh_pct > 0 else None)
    _set_sensor(_S_INDOOR_DP, in_dp, "°F",
                attrs={"friendly_name": "Indoor Dew Point"})

    achievable = (lookup_achievable_temp(s.outside_temp_f, s.outside_rh_pct)
                  if s.outside_temp_f is not None and s.outside_rh_pct is not None
                  else None)
    _set_sensor(_S_ACHIEVABLE, achievable, "°F",
                attrs={"friendly_name": "Evap Cooler Achievable Temperature"})


def _notify_transition(prev, d):
    """Send Discord notification when mode changes."""
    emoji = _MODE_EMOJI.get(d.mode, "ℹ️")
    body = f"{d.mode.value} — {d.reason}"
    if not _ACTUATE:
        body = f"[DRY-RUN] {body}"
    log.info(f"climate_balance transition: {prev.value if prev else 'init'} -> "
             f"{d.mode.value}: {d.reason}")
    notify.discord(message=f"{emoji} {body}", target=[_DISCORD_TARGET])


def _expose_decision(effective_d, current_d=None):
    """Update mode/reason/status sensors.

    effective_d: decision currently engaged (post min-runtime gating)
    current_d:   engine's latest raw output. May differ from effective_d
                 while a cooldown is gating a transition. Defaults to
                 effective_d. Always show current_d.reason so the
                 dashboard reflects what conditions look like NOW.
    """
    if current_d is None:
        current_d = effective_d

    holding = current_d.mode != effective_d.mode
    mode_attrs = {
        "friendly_name": "Climate Balance Mode",
        "icon": "mdi:home-thermometer",
        "wanted_mode": current_d.mode.value,
        "wanted_reason": current_d.reason,
        "holding_for_min_runtime": holding,
    }
    _set_sensor(_S_MODE, effective_d.mode.value, attrs=mode_attrs)

    if holding:
        reason_text = (
            f"{current_d.reason} (holding {effective_d.mode.value} until "
            f"min-runtime cooldown ends)"
        )
    else:
        reason_text = current_d.reason
    _set_sensor(_S_REASON, reason_text,
                attrs={"friendly_name": "Climate Balance Reason"})

    _set_sensor(_S_STATUS, "Auto" if _ACTUATE else "Dry-run (Phase 2)",
                attrs={"friendly_name": "Climate Balance Status"})


def _evaluate_and_apply():
    """Read state, evaluate, apply min-runtime gate, expose sensors, notify."""
    global _effective_mode, _effective_decision, _last_change_ts

    s = _build_state()
    c = _build_config()
    _recompute_derived(s)

    now = datetime.now()
    d = evaluate(s, c, now, prev_mode=_effective_mode)

    cold_start = _effective_mode is None
    wants_change = d.mode != _effective_mode
    cooldown_done = (
        _last_change_ts is not None and (now - _last_change_ts) >= _MIN_RUNTIME
    )

    if cold_start or (wants_change and cooldown_done):
        prev = _effective_mode
        _effective_mode = d.mode
        _effective_decision = d
        _last_change_ts = now
        _expose_decision(d, d)
        _notify_transition(prev, d)
    else:
        # Holding due to cooldown. Show engine's wanted mode + reason in
        # attributes so the dashboard is transparent.
        _expose_decision(_effective_decision, current_d=d)


@time_trigger("startup")
def on_startup():
    log.info("climate_balance: startup — Phase 2 dry-run engine active")
    _evaluate_and_apply()


@state_trigger(
    f"{_S_OUT_T}", f"{_S_OUT_RH}", f"{_S_AVG_T}", f"{_S_AVG_RH}",
    f"{_S_ATTIC_T}", f"{_S_ATTIC_RH}",
    f"{_H_ENABLED}", f"{_H_VACATION}",
    f"{_H_TARGET}", f"{_H_WHF_TARGET}",
    f"{_H_MAX_INDOOR_RH}", f"{_H_MAX_ATTIC_RH}", f"{_H_MAX_DP}",
)
def on_any_input_change(**kwargs):
    _evaluate_and_apply()


@time_trigger("period(now, 5min)")
def heartbeat():
    _evaluate_and_apply()
