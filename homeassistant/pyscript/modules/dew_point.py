"""Dew point calculation using the Magnus formula.

Magnus constants: a=17.625, b=243.04 (NOAA-recommended variant).
This module imports nothing from Pyscript so it is unit-testable.
"""
import math

_MAGNUS_A = 17.625
_MAGNUS_B = 243.04


def dew_point_f(temp_f: float, rh_pct: float) -> float:
    """Return dew point in °F for given air temperature and relative humidity.

    Args:
        temp_f: Air temperature in degrees Fahrenheit.
        rh_pct: Relative humidity in percent (0 < rh <= 100).

    Raises:
        ValueError: if rh_pct <= 0.
    """
    if rh_pct <= 0:
        raise ValueError(f"relative humidity must be > 0, got {rh_pct}")
    temp_c = (temp_f - 32.0) * 5.0 / 9.0
    alpha = math.log(rh_pct / 100.0) + (_MAGNUS_A * temp_c) / (_MAGNUS_B + temp_c)
    dp_c = (_MAGNUS_B * alpha) / (_MAGNUS_A - alpha)
    return dp_c * 9.0 / 5.0 + 32.0
