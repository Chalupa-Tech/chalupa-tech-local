"""Decision engine tests.

Covers priority ordering (rules 1-6), hysteresis dead bands, quiet hours,
and the DEHUMIDIFY→RECIRCULATE fallback when outside dew point would worsen indoor.
"""
import pytest
from datetime import datetime

from decision_engine import (
    ClimateState, Config, Mode, evaluate,
)


def _cfg(**overrides):
    base = dict(
        enabled=True, vacation=False,
        target_temp_f=70.0, whf_target_f=68.0,
        max_indoor_rh=55.0, max_attic_rh=50.0, max_dew_point_f=60.0,
    )
    base.update(overrides)
    return Config(**base)


def _state(**overrides):
    base = dict(
        outside_temp_f=85.0, outside_rh_pct=20.0,
        indoor_temp_f=72.0, indoor_rh_pct=45.0,
        attic_temp_f=80.0, attic_rh_pct=45.0,
    )
    base.update(overrides)
    return ClimateState(**base)


_NOON = datetime(2026, 5, 25, 12, 0)
_BEDTIME = datetime(2026, 5, 25, 22, 0)  # 10 PM, in quiet hours
_EARLY_MORNING = datetime(2026, 5, 25, 4, 0)  # 4 AM, not quiet hours


# ---------- Rule 1: master kill ----------

def test_disabled_returns_off():
    d = evaluate(_state(), _cfg(enabled=False), _NOON)
    assert d.mode == Mode.OFF
    assert "disabled" in d.reason.lower()


def test_vacation_returns_off():
    d = evaluate(_state(), _cfg(vacation=True), _NOON)
    assert d.mode == Mode.OFF
    assert "vacation" in d.reason.lower()


# ---------- Rule 2: dehumidify ----------

def test_attic_humidity_too_high_dehumidify_when_outside_dry():
    d = evaluate(
        _state(attic_rh_pct=58.0, outside_rh_pct=15.0, outside_temp_f=85.0,
               indoor_temp_f=70.0, indoor_rh_pct=45.0),
        _cfg(), _NOON,
    )
    assert d.mode == Mode.DEHUMIDIFY
    assert d.cooler_hvac_mode == "fan_only"
    assert d.whf_on is True
    assert "attic" in d.reason.lower()


def test_indoor_humidity_too_high_dehumidify_when_outside_dry():
    d = evaluate(
        _state(indoor_rh_pct=62.0, outside_rh_pct=15.0, outside_temp_f=85.0,
               indoor_temp_f=70.0),
        _cfg(), _NOON,
    )
    assert d.mode == Mode.DEHUMIDIFY


def test_indoor_humid_hot_outside_humid_recirculate_via_rule4():
    # Indoor 62% RH at 75°F + outside 90°F at 70% RH (DP ~79).
    # Rule 2 falls through (outside DP not better than indoor 62).
    # Rule 3 doesn't fire (outside warmer than indoor).
    # Rule 4 fires, sees outside DP 79 > max 60 → RECIRCULATE.
    d = evaluate(
        _state(indoor_rh_pct=62.0, indoor_temp_f=75.0,
               outside_temp_f=90.0, outside_rh_pct=70.0),
        _cfg(), _NOON,
    )
    assert d.mode == Mode.RECIRCULATE


def test_indoor_humid_outside_cool_within_dp_limit_runs_whf():
    # User's reported scenario: indoor humid (rule 2 triggers) but outside is
    # cooler AND outside DP is slightly higher than indoor DP yet still within
    # max_dew_point_f. Previously this short-circuited to RECIRCULATE from
    # rule 2; now it falls through to rule 3 → WHF_ONLY.
    # Indoor 75 + 50% → DP ~55. Outside 70 + 65% → DP ~58 (worse than indoor
    # but well below max 60). Rule 2 falls through; rule 3 engages WHF.
    d = evaluate(
        _state(indoor_rh_pct=50.0, indoor_temp_f=75.0,
               outside_temp_f=70.0, outside_rh_pct=65.0),
        _cfg(max_indoor_rh=45.0, max_dew_point_f=60.0), _NOON,
    )
    assert d.mode == Mode.WHF_ONLY


def test_whf_blocked_when_outside_dp_exceeds_max():
    # Outside is cooler than indoor BUT muggy enough to exceed max DP.
    # Indoor 75 + 40% → DP ~50. Outside 70 + 85% → DP ~65 (> max 60).
    # Rule 3 fires the new DP guard → RECIRCULATE.
    d = evaluate(
        _state(indoor_rh_pct=40.0, indoor_temp_f=75.0,
               outside_temp_f=70.0, outside_rh_pct=85.0),
        _cfg(max_dew_point_f=60.0, max_indoor_rh=55.0), _NOON,
    )
    assert d.mode == Mode.RECIRCULATE
    assert "dew point" in d.reason.lower()


def test_dehumidify_does_not_engage_at_helper():
    # max_attic_rh=50, attic_rh=50 → below entry (helper+5=55). Don't engage.
    d = evaluate(
        _state(attic_rh_pct=50.0, indoor_temp_f=70.0, indoor_rh_pct=45.0),
        _cfg(max_attic_rh=50.0), _NOON,
    )
    assert d.mode != Mode.DEHUMIDIFY


def test_dehumidify_does_not_engage_inside_entry_buffer():
    # max=50, attic_rh=54 (still in the helper+ENTRY buffer zone, 50-55).
    # User-visible "this is where it's getting sticky" but not yet
    # uncomfortable enough to swap to fan-only mode.
    d = evaluate(
        _state(attic_rh_pct=54.0, indoor_temp_f=70.0, indoor_rh_pct=45.0),
        _cfg(max_attic_rh=50.0), _NOON,
    )
    assert d.mode != Mode.DEHUMIDIFY


def test_dehumidify_engages_above_entry_buffer():
    # max=50, entry threshold = 55. attic_rh=56 → above → engage.
    d = evaluate(
        _state(attic_rh_pct=56.0, indoor_temp_f=70.0, indoor_rh_pct=45.0,
               outside_rh_pct=15.0, outside_temp_f=85.0),
        _cfg(max_attic_rh=50.0), _NOON,
    )
    assert d.mode == Mode.DEHUMIDIFY


def test_dehumidify_stays_engaged_above_exit_threshold():
    # In DEHUMIDIFY (prev), max=50 → exit threshold is 40. RH=42 > 40 → STAY.
    d = evaluate(
        _state(attic_rh_pct=42.0, indoor_temp_f=70.0, indoor_rh_pct=30.0,
               outside_rh_pct=15.0, outside_temp_f=85.0),
        _cfg(max_attic_rh=50.0, max_indoor_rh=50.0), _NOON,
        prev_mode=Mode.DEHUMIDIFY,
    )
    assert d.mode == Mode.DEHUMIDIFY


def test_dehumidify_exits_at_or_below_exit_threshold():
    # In DEHUMIDIFY, max=50, exit threshold=40. RH=40 (at) and 38 (below) → exit.
    for rh in [40.0, 38.0]:
        d = evaluate(
            _state(attic_rh_pct=rh, indoor_temp_f=70.0, indoor_rh_pct=30.0),
            _cfg(max_attic_rh=50.0, max_indoor_rh=50.0), _NOON,
            prev_mode=Mode.DEHUMIDIFY,
        )
        assert d.mode != Mode.DEHUMIDIFY, f"failed at attic_rh={rh}"


def test_dehumidify_does_not_re_engage_in_hysteresis_gap():
    # Dehumidify just exited (prev=OFF). max=50, entry=55, exit=40.
    # RH=45 is in the 40-55 gap. Don't re-engage.
    d = evaluate(
        _state(attic_rh_pct=45.0, indoor_temp_f=70.0, indoor_rh_pct=30.0),
        _cfg(max_attic_rh=50.0, max_indoor_rh=50.0), _NOON,
        prev_mode=Mode.OFF,
    )
    assert d.mode != Mode.DEHUMIDIFY


# ---------- Rule 3: free cooling (WHF only) ----------

def test_free_cooling_when_outside_cooler_and_indoor_above_whf_target():
    d = evaluate(
        _state(outside_temp_f=62.0, outside_rh_pct=30.0,
               indoor_temp_f=72.0, indoor_rh_pct=45.0),
        _cfg(whf_target_f=68.0), _EARLY_MORNING,
    )
    assert d.mode == Mode.WHF_ONLY
    assert d.cooler_hvac_mode == "off"
    assert d.whf_on is True


def test_free_cooling_fires_even_below_cooling_target():
    # Indoor 70°F (= cooling target), but above WHF target (68°F)
    # → still run WHF to push it down to 68
    d = evaluate(
        _state(outside_temp_f=62.0, outside_rh_pct=30.0,
               indoor_temp_f=70.0, indoor_rh_pct=45.0),
        _cfg(target_temp_f=70.0, whf_target_f=68.0), _EARLY_MORNING,
    )
    assert d.mode == Mode.WHF_ONLY


def test_no_free_cooling_when_indoor_at_whf_target():
    d = evaluate(
        _state(outside_temp_f=60.0, outside_rh_pct=30.0,
               indoor_temp_f=68.0, indoor_rh_pct=45.0),
        _cfg(whf_target_f=68.0), _EARLY_MORNING,
    )
    assert d.mode == Mode.OFF


def test_no_free_cooling_when_outside_only_slightly_cooler():
    # 1°F cooler — below 2°F dead band
    d = evaluate(
        _state(outside_temp_f=71.0, outside_rh_pct=30.0,
               indoor_temp_f=72.0, indoor_rh_pct=45.0),
        _cfg(), _EARLY_MORNING,
    )
    assert d.mode != Mode.WHF_ONLY


# ---------- Rule 4: active cooling ----------

def test_active_cooling_full_during_day():
    # Outside 90°F @ 20% → chart achievable 70°F = target. Fan speed: headroom 0 → 4.
    d = evaluate(
        _state(outside_temp_f=90.0, outside_rh_pct=20.0,
               indoor_temp_f=78.0, indoor_rh_pct=45.0),
        _cfg(target_temp_f=70.0), _NOON,
    )
    assert d.mode == Mode.COOLER_FULL
    assert d.cooler_hvac_mode == "cool"
    assert d.whf_on is True
    assert d.cooler_fan_speed == 4  # headroom 0


def test_active_cooling_quiet_during_bedtime():
    d = evaluate(
        _state(outside_temp_f=90.0, outside_rh_pct=20.0,
               indoor_temp_f=78.0, indoor_rh_pct=45.0),
        _cfg(target_temp_f=70.0), _BEDTIME,
    )
    assert d.mode == Mode.COOLER_QUIET
    assert d.cooler_fan_speed <= 4


def test_active_cooling_fan_speed_scales_with_headroom():
    # Outside 95°F @ 10% → chart achievable 71°F. Target 80 → headroom 9 → speed 10.
    d = evaluate(
        _state(outside_temp_f=95.0, outside_rh_pct=10.0,
               indoor_temp_f=85.0, indoor_rh_pct=30.0),
        _cfg(target_temp_f=80.0), _NOON,
    )
    assert d.mode == Mode.COOLER_FULL
    assert d.cooler_fan_speed == 10


def test_cooler_cannot_reach_target_recirculate():
    # Outside 105°F @ 40% → chart achievable 88°F. Target 70 → unreachable.
    # Falls through to RECIRCULATE.
    d = evaluate(
        _state(outside_temp_f=105.0, outside_rh_pct=40.0,
               indoor_temp_f=85.0, indoor_rh_pct=30.0),
        _cfg(target_temp_f=70.0), _NOON,
    )
    assert d.mode == Mode.RECIRCULATE


def test_dew_point_too_high_blocks_cooling():
    # Outside 85°F @ 70% RH → DP ~74°F. Cooler would add moisture indoors.
    d = evaluate(
        _state(outside_temp_f=85.0, outside_rh_pct=70.0,
               indoor_temp_f=78.0, indoor_rh_pct=45.0),
        _cfg(max_dew_point_f=60.0), _NOON,
    )
    assert d.mode == Mode.RECIRCULATE


def test_active_cooling_hysteresis():
    # Indoor exactly at target + 1 (below entry threshold of target + 2)
    d = evaluate(
        _state(outside_temp_f=90.0, outside_rh_pct=20.0,
               indoor_temp_f=71.0, indoor_rh_pct=45.0),
        _cfg(target_temp_f=70.0), _NOON,
    )
    assert d.mode == Mode.OFF


# ---------- Rule 6: idle ----------

def test_everything_in_range_off():
    d = evaluate(
        _state(outside_temp_f=80.0, outside_rh_pct=30.0,
               indoor_temp_f=70.0, indoor_rh_pct=45.0,
               attic_temp_f=78.0, attic_rh_pct=45.0),
        _cfg(), _NOON,
    )
    assert d.mode == Mode.OFF


# ---------- Priority order ----------

def test_master_kill_beats_humidity_emergency():
    d = evaluate(
        _state(attic_rh_pct=70.0, indoor_rh_pct=70.0, indoor_temp_f=85.0),
        _cfg(enabled=False), _NOON,
    )
    assert d.mode == Mode.OFF


def test_dehumidify_beats_cooling():
    # Hot indoor AND attic humid; dehumidify wins
    d = evaluate(
        _state(indoor_temp_f=80.0, attic_rh_pct=58.0,
               outside_temp_f=85.0, outside_rh_pct=15.0),
        _cfg(), _NOON,
    )
    assert d.mode == Mode.DEHUMIDIFY


def test_free_cooling_beats_active_cooling():
    # Outside cool enough for WHF AND indoor above cooling target
    # Free cooling (WHF only) is cheaper than running the cooler
    d = evaluate(
        _state(outside_temp_f=62.0, outside_rh_pct=30.0,
               indoor_temp_f=78.0, indoor_rh_pct=45.0),
        _cfg(target_temp_f=70.0, whf_target_f=68.0), _EARLY_MORNING,
    )
    assert d.mode == Mode.WHF_ONLY


# ---------- Missing sensors ----------

def test_missing_sensors_returns_off_with_unavailable_reason():
    d = evaluate(
        _state(outside_temp_f=None),
        _cfg(), _NOON,
    )
    assert d.mode == Mode.OFF
    assert "sensor" in d.reason.lower()


# ---------- Asymmetric hysteresis (prev_mode aware) ----------

def test_whf_stays_running_between_exit_and_entry_thresholds():
    # whf_target 68; entry > 68, exit ≤ 66 (whf_target - dead band)
    # Indoor 67 is in the hysteresis gap. If we're ALREADY in WHF_ONLY, stay.
    d = evaluate(
        _state(outside_temp_f=55.0, outside_rh_pct=30.0,
               indoor_temp_f=67.0, indoor_rh_pct=45.0),
        _cfg(whf_target_f=68.0), _EARLY_MORNING,
        prev_mode=Mode.WHF_ONLY,
    )
    assert d.mode == Mode.WHF_ONLY


def test_whf_does_not_enter_in_hysteresis_gap_when_off():
    # Same conditions but prev_mode is OFF — don't enter
    d = evaluate(
        _state(outside_temp_f=55.0, outside_rh_pct=30.0,
               indoor_temp_f=67.0, indoor_rh_pct=45.0),
        _cfg(whf_target_f=68.0), _EARLY_MORNING,
        prev_mode=Mode.OFF,
    )
    assert d.mode == Mode.OFF


def test_whf_exits_when_indoor_below_exit_threshold():
    # Indoor 65 is below exit threshold (66) — even with prev WHF_ONLY, exit
    d = evaluate(
        _state(outside_temp_f=55.0, outside_rh_pct=30.0,
               indoor_temp_f=65.0, indoor_rh_pct=45.0),
        _cfg(whf_target_f=68.0), _EARLY_MORNING,
        prev_mode=Mode.WHF_ONLY,
    )
    assert d.mode == Mode.OFF


def test_cooler_stays_running_between_exit_and_entry_thresholds():
    # target 70; entry > 72, exit ≤ 70. Indoor 71 = in the gap.
    # If prev is COOLER_FULL, stay running.
    d = evaluate(
        _state(outside_temp_f=90.0, outside_rh_pct=20.0,
               indoor_temp_f=71.0, indoor_rh_pct=45.0),
        _cfg(target_temp_f=70.0), _NOON,
        prev_mode=Mode.COOLER_FULL,
    )
    assert d.mode == Mode.COOLER_FULL


def test_cooler_exits_when_indoor_at_or_below_target():
    # Indoor 70 = target. With prev COOLER_FULL, indoor > target is False → exit
    d = evaluate(
        _state(outside_temp_f=90.0, outside_rh_pct=20.0,
               indoor_temp_f=70.0, indoor_rh_pct=45.0),
        _cfg(target_temp_f=70.0), _NOON,
        prev_mode=Mode.COOLER_FULL,
    )
    assert d.mode == Mode.OFF


def test_prev_mode_none_uses_entry_thresholds():
    # Cold start (prev_mode=None) → same behavior as before: must clear entry
    d = evaluate(
        _state(outside_temp_f=55.0, outside_rh_pct=30.0,
               indoor_temp_f=67.0, indoor_rh_pct=45.0),
        _cfg(whf_target_f=68.0), _EARLY_MORNING,
        prev_mode=None,
    )
    assert d.mode == Mode.OFF


# ---------- Cooler-effective overshoot tolerance ----------

def test_cooler_fires_when_achievable_within_overshoot_tolerance():
    # Outside 90°F @ 20% RH → chart achievable 70°F. dew point ~44°F (under 60 max).
    # Target 69 → achievable 70 is 1°F over. With COOLER_OVERSHOOT_F = 1.0, fire.
    d = evaluate(
        _state(outside_temp_f=90.0, outside_rh_pct=20.0,
               indoor_temp_f=78.0, indoor_rh_pct=30.0),
        _cfg(target_temp_f=69.0), _NOON,
    )
    assert d.mode == Mode.COOLER_FULL


def test_cooler_recirculates_when_achievable_exceeds_overshoot_tolerance():
    # Outside 105°F @ 40% → achievable 88°F. Target 70 → 88 well above tolerance.
    d = evaluate(
        _state(outside_temp_f=105.0, outside_rh_pct=40.0,
               indoor_temp_f=85.0, indoor_rh_pct=30.0),
        _cfg(target_temp_f=70.0), _NOON,
    )
    assert d.mode == Mode.RECIRCULATE
