"""Pyscript entry point for climate balance.

This file is loaded by the Pyscript add-on from /config/pyscript/.
It defines derived sensors and (in later phases) the decision engine
and actuators. Pure logic lives in sibling modules and is unit-tested
with pytest from this repo's homeassistant/tests/ dir.

Phase 1 scope: derived sensors only — dew points + chart-achievable temp.
"""

# Pyscript imports sibling modules automatically from /config/pyscript/
from dew_point import dew_point_f
from cooler_chart import lookup_achievable_temp


# Sensor entity IDs we emit. Pyscript-created sensors live under sensor.pyscript.*
# unless renamed; we use state.set("sensor.X", ...) to create top-level entities.
_S_OUTSIDE_DP = "sensor.outside_dew_point"
_S_INDOOR_DP = "sensor.indoor_dew_point"
_S_ACHIEVABLE = "sensor.evap_cooler_achievable_temp"

# Input sensors we depend on.
_S_OUT_T = "sensor.stormin_norman_temperature"
_S_OUT_RH = "sensor.stormin_norman_humidity"
_S_AVG_T = "sensor.average_temperature"
_S_AVG_RH = "sensor.average_humidity"


def _read_float(entity_id):
    """Return float value of an entity's state, or None if unavailable/unknown."""
    raw = state.get(entity_id)
    if raw in (None, "unknown", "unavailable", ""):
        return None
    try:
        return float(raw)
    except (TypeError, ValueError):
        return None


def _set_sensor(entity_id, value, unit, attrs=None):
    """Set a sensor state with unit and friendly attrs.

    Pyscript's state.set() accepts new_attributes for arbitrary metadata.
    """
    base_attrs = {
        "unit_of_measurement": unit,
        "device_class": "temperature" if unit == "°F" else None,
        "icon": "mdi:thermometer",
        "source": "pyscript:climate_balance",
    }
    if attrs:
        base_attrs.update(attrs)
    # state.set in Pyscript: state.set(entity, value, new_attributes=...)
    state.set(entity_id, value if value is not None else "unavailable", new_attributes=base_attrs)


def _recompute_derived():
    """Recompute and emit all derived sensors. Safe to call repeatedly."""
    out_t = _read_float(_S_OUT_T)
    out_rh = _read_float(_S_OUT_RH)
    avg_t = _read_float(_S_AVG_T)
    avg_rh = _read_float(_S_AVG_RH)

    # Outside dew point
    outside_dp = None
    if out_t is not None and out_rh is not None and out_rh > 0:
        outside_dp = round(dew_point_f(out_t, out_rh), 1)
    _set_sensor(_S_OUTSIDE_DP, outside_dp, "°F",
                attrs={"friendly_name": "Outside Dew Point"})

    # Indoor dew point
    indoor_dp = None
    if avg_t is not None and avg_rh is not None and avg_rh > 0:
        indoor_dp = round(dew_point_f(avg_t, avg_rh), 1)
    _set_sensor(_S_INDOOR_DP, indoor_dp, "°F",
                attrs={"friendly_name": "Indoor Dew Point"})

    # Evap cooler achievable temp
    achievable = None
    if out_t is not None and out_rh is not None:
        achievable = lookup_achievable_temp(out_t, out_rh)
    _set_sensor(_S_ACHIEVABLE, achievable, "°F",
                attrs={"friendly_name": "Evap Cooler Achievable Temperature"})


@time_trigger("startup")
def on_startup():
    """Compute once at Pyscript startup so sensors aren't 'unavailable' at boot."""
    log.info("climate_balance: initial derived-sensor computation")
    _recompute_derived()


@state_trigger(
    f"{_S_OUT_T}",
    f"{_S_OUT_RH}",
    f"{_S_AVG_T}",
    f"{_S_AVG_RH}",
)
def on_input_change(**kwargs):
    """Recompute derived sensors whenever any input sensor changes."""
    _recompute_derived()


@time_trigger("period(now, 5min)")
def heartbeat():
    """Heartbeat: recompute every 5 minutes even if no state change fired."""
    _recompute_derived()
