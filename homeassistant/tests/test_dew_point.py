"""Dew point calculation tests.

Reference values from NOAA dew-point calculator
(https://www.weather.gov/epz/wxcalc_rh) using the Magnus formula.
Tolerance: ±0.5 °F to allow for floating-point and formula-variant drift.
"""
import pytest
from dew_point import dew_point_f


@pytest.mark.parametrize("temp_f,rh_pct,expected_dp_f", [
    (70.0, 50.0, 50.5),   # standard comfort indoor
    (90.0, 30.0, 55.2),   # typical hot/dry summer outside
    (95.0, 20.0, 49.9),   # arid summer high
    (75.0, 80.0, 68.4),   # muggy
    (32.0, 100.0, 32.0),  # saturated freezing
])
def test_dew_point_matches_reference(temp_f, rh_pct, expected_dp_f):
    result = dew_point_f(temp_f, rh_pct)
    assert result == pytest.approx(expected_dp_f, abs=0.5)


def test_dew_point_rejects_zero_rh():
    with pytest.raises(ValueError):
        dew_point_f(70.0, 0.0)


def test_dew_point_rejects_negative_rh():
    with pytest.raises(ValueError):
        dew_point_f(70.0, -5.0)
