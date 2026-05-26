"""Evaporative cooler chart lookup.

Source: Ed Phillips, Arizona Almanac. Gives delivered air temperature (°F) for
given outside temperature (°F) and outside relative humidity (%). Cells omitted
from a row mean the chart authors considered evap cooling ineffective at those
conditions; lookup returns None for those.

Lookup strategy: nearest-cell rounding. Chart granularity (5° / 5%) is already
coarser than the formula's accuracy, so interpolation adds complexity without
meaningful precision gain.

This module imports nothing from Pyscript so it is unit-testable.
"""
from typing import Optional

# Outside temp (°F) → { outside RH (%) → delivered temp (°F) }
COOLER_CHART: dict[int, dict[int, int]] = {
    75:  {2: 54, 5: 55, 10: 57, 15: 58, 20: 59, 25: 60, 30: 61, 35: 62, 40: 63,
          45: 64, 50: 65, 55: 66, 60: 68, 65: 69, 70: 70, 75: 71, 80: 72},
    80:  {2: 57, 5: 59, 10: 60, 15: 62, 20: 63, 25: 64, 30: 66, 35: 67, 40: 68,
          45: 69, 50: 71, 55: 72, 60: 73, 65: 74, 70: 75, 75: 76, 80: 77},
    85:  {2: 61, 5: 62, 10: 63, 15: 65, 20: 67, 25: 68, 30: 70, 35: 71, 40: 72,
          45: 73, 50: 75, 55: 76, 60: 77, 65: 78, 70: 79},
    90:  {2: 64, 5: 66, 10: 67, 15: 69, 20: 70, 25: 72, 30: 74, 35: 75, 40: 77,
          45: 78, 50: 79, 55: 80, 60: 82, 65: 83, 70: 84},
    95:  {2: 67, 5: 69, 10: 71, 15: 72, 20: 74, 25: 76, 30: 78, 35: 80, 40: 82,
          45: 83, 50: 85, 55: 86, 60: 87},
    100: {2: 69, 5: 71, 10: 73, 15: 76, 20: 77, 25: 79, 30: 82, 35: 83, 40: 85,
          45: 87},
    105: {2: 72, 5: 75, 10: 77, 15: 80, 20: 81, 25: 83, 30: 86, 35: 87, 40: 88},
    110: {2: 75, 5: 78, 10: 80, 15: 83, 20: 85, 25: 87, 30: 90, 35: 92},
    115: {2: 78, 5: 80, 10: 83, 15: 87, 20: 89, 25: 91},
    120: {2: 81, 5: 83, 10: 88, 15: 93, 20: 95},
    125: {2: 83, 5: 86, 10: 90, 15: 93, 20: 96},
}


def _nearest(keys, target):
    """Return the key numerically closest to target.

    Explicit loop instead of ``min(..., key=lambda)`` because Pyscript's
    interpreter does not bind enclosing-function parameters inside lambda
    closures — the lambda raises ``NameError`` for the captured arg at
    evaluation time. The loop is closure-free and works identically in
    plain CPython (for pytest) and Pyscript (for HA runtime).
    """
    best = None
    best_d = None
    for k in keys:
        d = abs(k - target)
        if best is None or d < best_d:
            best = k
            best_d = d
    return best


def lookup_achievable_temp(outside_temp_f: float, outside_rh_pct: float) -> Optional[int]:
    """Return delivered air temperature (°F) at given outside conditions.

    Uses nearest-cell rounding for both temp (5 °F granularity) and RH (5 %).
    Returns None when nearest cell falls in the chart's empty (ineffective) zone.
    Outside temps below 75 °F are returned unchanged (cooler can't improve cold air).
    """
    if outside_temp_f < 75:
        return int(round(outside_temp_f))
    temp_key = _nearest(COOLER_CHART.keys(), outside_temp_f)
    row = COOLER_CHART[temp_key]
    if outside_rh_pct > max(row.keys()):
        return None
    rh_key = _nearest(row.keys(), outside_rh_pct)
    return row.get(rh_key)
