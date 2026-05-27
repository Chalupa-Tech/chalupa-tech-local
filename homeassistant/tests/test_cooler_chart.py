"""Cooler chart lookup tests.

The chart (Ed Phillips, Arizona Almanac) gives evaporative-cooler delivered air
temperature for outside temp + relative humidity. Lookup uses nearest-cell rounding
(5° / 5% granularity). Cells in the lower-right are empty (high humidity + low
outside temp where evap cooling is ineffective) and return None.
"""
import pytest
from cooler_chart import lookup_achievable_temp


def test_known_exact_cell_75f_50rh():
    # Row 75, col 50 → 65
    assert lookup_achievable_temp(75, 50) == 65


def test_known_exact_cell_95f_20rh():
    # Row 95, col 20 → 74
    assert lookup_achievable_temp(95, 20) == 74


def test_known_exact_cell_110f_5rh():
    # Row 110, col 5 → 78
    assert lookup_achievable_temp(110, 5) == 78


def test_nearest_cell_rounding_temp():
    # 77 °F rounds to row 75; 22% rounds to col 20 → 59
    assert lookup_achievable_temp(77, 22) == 59


def test_nearest_cell_rounding_rh():
    # 95 °F exact; 47% rounds to col 45 → 83
    assert lookup_achievable_temp(95, 47) == 83


def test_outside_below_75_extrapolates_using_75_row_delta():
    # Outside 71°F @ 44% RH: 75°F row at 45% (nearest) → 64, delta 11.
    # Result: 71 - 11 = 60. (This is the case from the production bug report.)
    assert lookup_achievable_temp(71, 44) == 60

    # Outside 65°F @ 30% RH: 75°F row at 30% → 61, delta 14.
    # Result: 65 - 14 = 51.
    assert lookup_achievable_temp(65, 30) == 51

    # Outside 70°F @ 80% RH: 75°F row at 80% → 72, delta 3.
    # Result: 70 - 3 = 67.
    assert lookup_achievable_temp(70, 80) == 67


def test_outside_below_75_returns_none_if_rh_above_chart():
    # Row 75 max RH is 80. RH=85 has no chart data → None even for sub-75 outside.
    assert lookup_achievable_temp(70, 85) is None


def test_empty_cell_returns_none():
    # Row 110, col 65 is outside the chart's effective zone
    assert lookup_achievable_temp(110, 65) is None
    # Row 120, col 50 is also empty
    assert lookup_achievable_temp(120, 50) is None


def test_high_temp_low_rh_chart_top_right():
    # Row 125, col 20 → 96 (one of the chart's hottest defined cells)
    assert lookup_achievable_temp(125, 20) == 96


def test_above_chart_max_temp_uses_top_row():
    # 130 °F rounds to row 125
    assert lookup_achievable_temp(130, 10) == 90
