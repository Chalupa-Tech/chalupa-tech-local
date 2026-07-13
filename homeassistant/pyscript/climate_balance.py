"""Pyscript entry point for climate balance.

Phase 1: derived sensors (dew points + chart achievable).
Phase 2: + decision engine (dry-run mode).
  - Threads effective-mode through evaluate() for asymmetric hysteresis
  - Enforces 10-min minimum runtime per mode (cycling cap at ≤3 cycles/hr)
  - Updates sensor.climate_balance_mode / _reason / _status
  - Sends Discord notification on mode transition

Phase 3 (this version): live actuation + manual override + danger warnings.
  - _ACTUATE = True: calls climate.set_* and switch.turn_* for real
  - Manual override detection via context.user_id → per-device snooze
  - Snooze expiry detection → resume notification + re-actuation
  - Danger warnings when temp/humidity thresholds exceeded during snooze
"""
from datetime import datetime, timedelta

from cooler_chart import lookup_achievable_temp
from decision_engine import ClimateState, Config, Decision, Mode, evaluate
from dew_point import dew_point_f


_ACTUATE = True
_NOTIFY_SERVICE = "homeassistant_tejon_frame"   # notify.<service> for Discord
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

# Actuator entity IDs
_E_COOLER = "climate.magiqtouch"
_E_WHF = "switch.wholehousefanplug"

# Helpers
_H_ENABLED = "input_boolean.climate_balance_enabled"
_H_VACATION = "input_boolean.climate_balance_vacation"
_H_TARGET = "input_number.climate_balance_target_temp"
_H_WHF_TARGET = "input_number.climate_balance_whf_target"
_H_MAX_INDOOR_RH = "input_number.climate_balance_max_indoor_rh"
_H_MAX_ATTIC_RH = "input_number.climate_balance_max_attic_rh"
_H_MAX_DP = "input_number.climate_balance_max_dew_point"
_H_DEHUM_BAND = "input_number.climate_balance_dehumidify_hysteresis_band"
_H_OVERRIDE_MIN = "input_number.climate_balance_override_minutes"
_H_COOLER_UNTIL = "input_datetime.cooler_manual_until"
_H_WHF_UNTIL = "input_datetime.whf_manual_until"

# Module-scoped state for hysteresis + min-runtime. Pyscript reloads reset these
# to None, at which point the next evaluation cold-starts (prev_mode=None, no
# min-runtime gate). That's fine — a reload is a known good time to allow a
# fresh transition.
_effective_mode = None
_effective_decision = None
_last_change_ts = None
_last_cooler_snoozed = False
_last_whf_snoozed = False
_warned_during_snooze_cooler_attic = False
_warned_during_snooze_cooler_temp = False
_warned_during_snooze_whf_temp = False


# Mode → emoji for Discord
_MODE_EMOJI = {
    Mode.OFF: "✅",
    Mode.WHF_ONLY: "🌬️",
    Mode.COOLER_FULL: "❄️",
    Mode.COOLER_QUIET: "🌙",
    Mode.DEHUMIDIFY: "💧",
    Mode.RECIRCULATE: "🛑",
    Mode.DISABLED: "⏸️",
}

# Helpers whose change means "the user edited config" — their intent applies
# immediately: hysteresis re-baselines against the new values and the
# min-runtime gate is bypassed (it exists to stop sensor-driven cycling,
# not to delay explicit user commands).
_CONFIG_HELPERS = {
    _H_ENABLED, _H_VACATION, _H_TARGET, _H_WHF_TARGET,
    _H_MAX_INDOOR_RH, _H_MAX_ATTIC_RH, _H_MAX_DP, _H_DEHUM_BAND,
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
        dehumidify_hysteresis_band=_read_float(_H_DEHUM_BAND) or 10.0,
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
    # Use service.call so the service name is a runtime string (notify.<dynamic>)
    service.call(
        "notify", _NOTIFY_SERVICE,
        message=f"{emoji} {body}",
        target=[_DISCORD_TARGET],
    )


def _datetime_helper_in_future(entity_id):
    """True if the input_datetime helper resolves to a future timestamp."""
    raw = state.get(entity_id)
    if not raw or raw in ("unknown", "unavailable"):
        return False
    try:
        ts = datetime.fromisoformat(raw.replace(" ", "T"))
    except ValueError:
        return False
    return ts > datetime.now()


def _snooze_active(device):
    """device: 'cooler' or 'whf'."""
    entity = _H_COOLER_UNTIL if device == "cooler" else _H_WHF_UNTIL
    return _datetime_helper_in_future(entity)


def _cooler_summary():
    """Short human-readable description of the cooler's current state.
    Used in Discord notifications when a manual override is detected so
    the user can tell at a glance what state they just put it in.
    """
    hvac = state.get(_E_COOLER)
    if hvac == "off":
        return "off"
    attrs = state.getattr(_E_COOLER) or {}
    preset = attrs.get("preset_mode") or ""
    fan = attrs.get("fan_mode")
    temp = attrs.get("temperature")
    if hvac == "fan_only":
        return f"fan-only / fan {fan}"
    # cool mode — distinguish temperature- vs fan-speed-preset
    if "set temperature" in preset:
        return f"cool / target {temp}°F"
    if "set fan speed" in preset:
        return f"cool / fan {fan}"
    # Fallback: include whatever we have
    return f"{hvac} / fan {fan} / preset {preset}"


def _whf_summary():
    return state.get(_E_WHF) or "unknown"


def _start_snooze(device):
    duration = _read_float(_H_OVERRIDE_MIN) or 60.0
    until = datetime.now() + timedelta(minutes=duration)
    entity = _H_COOLER_UNTIL if device == "cooler" else _H_WHF_UNTIL
    service.call("input_datetime", "set_datetime",
                 entity_id=entity,
                 datetime=until.strftime("%Y-%m-%d %H:%M:%S"))
    label = "swamp cooler" if device == "cooler" else "whole house fan"
    cur = _cooler_summary() if device == "cooler" else _whf_summary()
    log.info(f"climate_balance: {device} manual override → {until.isoformat()} (state: {cur})")
    service.call("notify", _NOTIFY_SERVICE,
                 message=f"📱 Manual override detected on {label} — "
                         f"currently {cur} — "
                         f"pausing automation for {int(duration)} min",
                 target=[_DISCORD_TARGET])


# Self-action window: when we call a service on a device, mark the device
# "ours" for SELF_ACTION_WINDOW seconds. State changes during the window
# are assumed to be our own service-call echo. Outside the window, any
# state change is treated as a manual user override.
#
# This is more robust than relying on context.user_id (which can be None
# even for user-initiated changes via certain integrations/voice/physical
# remotes — observed in production where a UI-driven hvac_mode change did
# not propagate a user_id through Pyscript's context kwarg).
SELF_ACTION_WINDOW = timedelta(seconds=30)
_self_cooler_until = None
_self_whf_until = None


def _mark_self(device):
    global _self_cooler_until, _self_whf_until
    deadline = datetime.now() + SELF_ACTION_WINDOW
    if device == "cooler":
        _self_cooler_until = deadline
    else:
        _self_whf_until = deadline


def _is_self(device):
    deadline = _self_cooler_until if device == "cooler" else _self_whf_until
    return deadline is not None and datetime.now() < deadline


def _actuate_respecting_overrides(d):
    """Apply Decision but skip devices currently under manual snooze.
    Marks each device "self-actuated" for the SELF_ACTION_WINDOW just
    before issuing the service call, so the state_trigger callback
    doesn't mistake our own write for a manual user override.
    """
    if d.hands_off:
        # Master toggle off — leave devices exactly as the user set them.
        return

    cooler_snoozed = _snooze_active("cooler")
    whf_snoozed = _snooze_active("whf")

    # Cooler: skip all writes if snoozed
    if not cooler_snoozed:
        cur_mode = state.get(_E_COOLER)
        if cur_mode != d.cooler_hvac_mode:
            log.info(f"climate_balance: set cooler hvac_mode → {d.cooler_hvac_mode}")
            _mark_self("cooler")
            service.call("climate", "set_hvac_mode",
                         entity_id=_E_COOLER, hvac_mode=d.cooler_hvac_mode)

        attrs = state.getattr(_E_COOLER)
        cur_preset = attrs.get("preset_mode") if attrs else None
        cur_fan = attrs.get("fan_mode") if attrs else None
        cur_temp = attrs.get("temperature") if attrs else None

        # Preset mode: switch the cooler between "set temperature" and
        # "set fan speed" modes.
        if (d.cooler_preset_mode is not None
                and cur_preset != d.cooler_preset_mode):
            log.info(f"climate_balance: set cooler preset_mode → {d.cooler_preset_mode}")
            _mark_self("cooler")
            service.call("climate", "set_preset_mode",
                         entity_id=_E_COOLER, preset_mode=d.cooler_preset_mode)

        # Target temperature (when in "set temperature" preset).
        if d.cooler_set_temperature_f is not None:
            try:
                cur_temp_f = float(cur_temp) if cur_temp is not None else None
            except (TypeError, ValueError):
                cur_temp_f = None
            if cur_temp_f != float(d.cooler_set_temperature_f):
                log.info(f"climate_balance: set cooler temperature → "
                         f"{d.cooler_set_temperature_f}")
                _mark_self("cooler")
                service.call("climate", "set_temperature",
                             entity_id=_E_COOLER,
                             temperature=d.cooler_set_temperature_f)

        # Explicit fan speed (when in "set fan speed" preset / DEHUMIDIFY).
        if d.cooler_fan_speed is not None:
            desired = str(d.cooler_fan_speed)
            if cur_fan != desired:
                log.info(f"climate_balance: set cooler fan_mode → {desired}")
                _mark_self("cooler")
                service.call("climate", "set_fan_mode",
                             entity_id=_E_COOLER, fan_mode=desired)

    # WHF
    if not whf_snoozed:
        cur_whf = state.get(_E_WHF)
        desired_whf = "on" if d.whf_on else "off"
        if cur_whf != desired_whf:
            log.info(f"climate_balance: set WHF → {desired_whf}")
            _mark_self("whf")
            if d.whf_on:
                service.call("switch", "turn_on", entity_id=_E_WHF)
            else:
                service.call("switch", "turn_off", entity_id=_E_WHF)


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

    if not _read_bool(_H_ENABLED):
        status = "Disabled"
    elif _read_bool(_H_VACATION):
        status = "Vacation"
    elif not _ACTUATE:
        status = "Dry-run"
    else:
        cooler_snoozed = _snooze_active("cooler")
        whf_snoozed = _snooze_active("whf")
        if cooler_snoozed and whf_snoozed:
            status = "Both devices in manual override"
        elif cooler_snoozed:
            status = "Cooler in manual override"
        elif whf_snoozed:
            status = "WHF in manual override"
        else:
            status = "Auto"
    _set_sensor(_S_STATUS, status,
                attrs={"friendly_name": "Climate Balance Status"})


def _on_snooze_expire(device):
    """Called once when a snooze transitions from active → inactive.
    Always notifies (the user wants to know the snooze is over and what
    the engine intends to do). The actuator is idempotent so reapplying
    is safe even if the device already matches.
    """
    if not _read_bool(_H_ENABLED):
        return
    s = _build_state()
    c = _build_config()
    d = evaluate(s, c, datetime.now(), prev_mode=_effective_mode)

    device_label = "swamp cooler" if device == "cooler" else "whole house fan"
    service.call("notify", _NOTIFY_SERVICE,
                 message=f"▶️ Resuming {device_label} automation — "
                         f"switching to {d.mode.value} ({d.reason})",
                 target=[_DISCORD_TARGET])
    _actuate_respecting_overrides(d)


def _maybe_warn_danger(s, c):
    """Warn (once per condition per snooze window) when danger conditions
    persist while the relevant device is under manual override.

    Module-level flag bools track which danger conditions we already warned
    about; they reset when the snooze ends.
    """
    global _warned_during_snooze_cooler_attic
    global _warned_during_snooze_cooler_temp
    global _warned_during_snooze_whf_temp

    if not c.enabled:
        return

    cooler_snoozed = _snooze_active("cooler")
    whf_snoozed = _snooze_active("whf")

    # Attic humidity danger (cooler should be running fan-only to help)
    if (cooler_snoozed and s.attic_rh_pct is not None
            and s.attic_rh_pct > c.max_attic_rh + 10
            and not _warned_during_snooze_cooler_attic):
        service.call("notify", _NOTIFY_SERVICE,
                     message=f"⚠️ Attic humidity at {s.attic_rh_pct:.0f}% but "
                             f"swamp cooler is in manual override — consider "
                             f"intervening",
                     target=[_DISCORD_TARGET])
        _warned_during_snooze_cooler_attic = True

    # Indoor temp danger (either device under snooze)
    if s.indoor_temp_f is not None and s.indoor_temp_f > c.target_temp_f + 5:
        if cooler_snoozed and not _warned_during_snooze_cooler_temp:
            service.call("notify", _NOTIFY_SERVICE,
                         message=f"⚠️ Indoor temperature at "
                                 f"{s.indoor_temp_f:.0f}°F (target "
                                 f"{c.target_temp_f:.0f}°F) but swamp cooler "
                                 f"is in manual override — consider intervening",
                         target=[_DISCORD_TARGET])
            _warned_during_snooze_cooler_temp = True
        if whf_snoozed and not _warned_during_snooze_whf_temp:
            service.call("notify", _NOTIFY_SERVICE,
                         message=f"⚠️ Indoor temperature at "
                                 f"{s.indoor_temp_f:.0f}°F (target "
                                 f"{c.target_temp_f:.0f}°F) but whole house fan "
                                 f"is in manual override — consider intervening",
                         target=[_DISCORD_TARGET])
            _warned_during_snooze_whf_temp = True

    # Clear warning flags when snooze ends
    if not cooler_snoozed:
        _warned_during_snooze_cooler_attic = False
        _warned_during_snooze_cooler_temp = False
    if not whf_snoozed:
        _warned_during_snooze_whf_temp = False


def _evaluate_and_apply(config_changed=False):
    """Read state, evaluate, apply min-runtime gate, expose sensors, notify.

    config_changed=True means the user just edited a helper. User intent
    applies immediately: evaluate with prev_mode=None so hysteresis
    re-baselines against the NEW thresholds (an engaged mode must not keep
    waiting on an exit threshold derived from the old value), and bypass
    the min-runtime gate (it exists to stop sensor-noise cycling, not to
    delay explicit user commands).
    """
    global _effective_mode, _effective_decision, _last_change_ts

    s = _build_state()
    c = _build_config()
    _recompute_derived(s)

    now = datetime.now()
    prev_for_eval = None if config_changed else _effective_mode
    d = evaluate(s, c, now, prev_mode=prev_for_eval)

    cold_start = _effective_mode is None
    wants_change = d.mode != _effective_mode
    cooldown_done = (
        _last_change_ts is not None and (now - _last_change_ts) >= _MIN_RUNTIME
    )

    if cold_start or (wants_change and (cooldown_done or config_changed)):
        prev = _effective_mode
        _effective_mode = d.mode
        _effective_decision = d
        _last_change_ts = now
        _expose_decision(d, d)
        if _ACTUATE:
            _actuate_respecting_overrides(d)
        _notify_transition(prev, d)
    else:
        if not wants_change:
            # Same mode, possibly new parameters (e.g. new target temp while
            # COOLER_FULL is engaged) — adopt the fresh decision so
            # reconciliation applies current values, not stale ones.
            _effective_decision = d
        # Holding due to cooldown. Show engine's wanted mode + reason in
        # attributes so the dashboard is transparent.
        _expose_decision(_effective_decision, current_d=d)
        if _ACTUATE and _effective_decision is not None:
            # State reconciliation: if device drifted from our effective
            # decision (e.g., MagiqTouch revert, snooze just expired, or a
            # cold-start applied a no-op call), re-apply. The actuator is
            # idempotent — only issues service calls when current != desired.
            _actuate_respecting_overrides(_effective_decision)
    _maybe_warn_danger(s, c)


@time_trigger("startup")
def on_startup():
    log.info("climate_balance: startup — Phase 3 live actuation active")
    _evaluate_and_apply()


@state_trigger(
    f"{_S_OUT_T}", f"{_S_OUT_RH}", f"{_S_AVG_T}", f"{_S_AVG_RH}",
    f"{_S_ATTIC_T}", f"{_S_ATTIC_RH}",
    f"{_H_ENABLED}", f"{_H_VACATION}",
    f"{_H_TARGET}", f"{_H_WHF_TARGET}",
    f"{_H_MAX_INDOOR_RH}", f"{_H_MAX_ATTIC_RH}", f"{_H_MAX_DP}",
    f"{_H_DEHUM_BAND}",
)
def on_any_input_change(**kwargs):
    var = kwargs.get("var_name")
    _evaluate_and_apply(config_changed=var in _CONFIG_HELPERS)


@time_trigger("period(now, 5min)")
def heartbeat():
    _evaluate_and_apply()


def _cooler_matches_desired():
    """True if cooler current state matches what the engine currently wants.

    Used to distinguish genuine user actions from MagiqTouch WebSocket sync
    events (which fire state triggers but don't reflect user intent). If the
    state matches the engine's desire, treat as a sync — no snooze.
    """
    if _effective_decision is None:
        return False
    cur_hvac = state.get(_E_COOLER)
    if cur_hvac != _effective_decision.cooler_hvac_mode:
        return False
    attrs = state.getattr(_E_COOLER)
    if _effective_decision.cooler_preset_mode is not None:
        cur_preset = attrs.get("preset_mode") if attrs else None
        if cur_preset != _effective_decision.cooler_preset_mode:
            return False
    if _effective_decision.cooler_set_temperature_f is not None:
        cur_temp = attrs.get("temperature") if attrs else None
        try:
            cur_temp_f = float(cur_temp) if cur_temp is not None else None
        except (TypeError, ValueError):
            cur_temp_f = None
        if cur_temp_f != float(_effective_decision.cooler_set_temperature_f):
            return False
    if _effective_decision.cooler_fan_speed is not None:
        cur_fan = attrs.get("fan_mode") if attrs else None
        if cur_fan != str(_effective_decision.cooler_fan_speed):
            return False
    return True


def _whf_matches_desired():
    if _effective_decision is None:
        return False
    cur_whf = state.get(_E_WHF)
    desired = "on" if _effective_decision.whf_on else "off"
    return cur_whf == desired


@state_trigger(
    _E_COOLER,
    f"{_E_COOLER}.fan_mode",
    f"{_E_COOLER}.preset_mode",
    f"{_E_COOLER}.temperature",
)
def on_cooler_change(**kwargs):
    """Detect manual changes to the cooler and start a snooze.

    Three checks (in order):
    1. _is_self window — we just made a service call, ignore the echo.
    2. _cooler_matches_desired — the new state matches what the engine
       currently wants. Usually a MagiqTouch WebSocket sync rather than a
       user action; don't snooze.
    3. _snooze_active — already snoozed, no need to re-arm.
    """
    if not _read_bool(_H_ENABLED):
        return  # disabled = hands off; manual changes are none of our business
    log.info(f"climate_balance: cooler change var={kwargs.get('var_name')} "
             f"value={kwargs.get('value')} self={_is_self('cooler')} "
             f"matches={_cooler_matches_desired()} "
             f"snoozed={_snooze_active('cooler')}")
    if _is_self("cooler"):
        return
    if _cooler_matches_desired():
        return
    if _snooze_active("cooler"):
        return
    _start_snooze("cooler")


@state_trigger(_E_WHF)
def on_whf_change(**kwargs):
    """Detect manual changes to the WHF. Only the state (on/off) matters."""
    if not _read_bool(_H_ENABLED):
        return  # disabled = hands off; manual changes are none of our business
    log.info(f"climate_balance: WHF change "
             f"self={_is_self('whf')} matches={_whf_matches_desired()} "
             f"snoozed={_snooze_active('whf')}")
    if _is_self("whf"):
        return
    if _whf_matches_desired():
        return
    if _snooze_active("whf"):
        return
    _start_snooze("whf")


@time_trigger("period(now, 1min)")
def check_snooze_expiry():
    """Detect snooze expiry edges and trigger resume."""
    global _last_cooler_snoozed, _last_whf_snoozed
    cur_cooler = _snooze_active("cooler")
    cur_whf = _snooze_active("whf")

    if _last_cooler_snoozed and not cur_cooler:
        _on_snooze_expire("cooler")
    if _last_whf_snoozed and not cur_whf:
        _on_snooze_expire("whf")

    _last_cooler_snoozed = cur_cooler
    _last_whf_snoozed = cur_whf
