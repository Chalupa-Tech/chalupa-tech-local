"""Fan speed mapping tests.

Maps chart "headroom" (target_temp - achievable_temp) to MagiqTouch fan speed 0-10.
Quiet-hours flag caps the output at 4 regardless of headroom.
"""
from fan_speed import speed_for_headroom


def test_headroom_huge_returns_max():
    assert speed_for_headroom(headroom_f=10, quiet=False) == 10


def test_headroom_six_returns_ten():
    assert speed_for_headroom(headroom_f=6, quiet=False) == 10


def test_headroom_four_returns_eight():
    assert speed_for_headroom(headroom_f=4, quiet=False) == 8


def test_headroom_two_returns_six():
    assert speed_for_headroom(headroom_f=2, quiet=False) == 6


def test_headroom_zero_returns_four():
    assert speed_for_headroom(headroom_f=0, quiet=False) == 4


def test_headroom_negative_returns_max_best_effort():
    # Cooler can't reach target — run full blast anyway
    assert speed_for_headroom(headroom_f=-3, quiet=False) == 10


def test_quiet_caps_at_four():
    assert speed_for_headroom(headroom_f=10, quiet=True) == 4
    assert speed_for_headroom(headroom_f=4, quiet=True) == 4
    assert speed_for_headroom(headroom_f=-5, quiet=True) == 4


def test_quiet_below_cap_unchanged():
    # If natural speed would be 6, quiet caps it to 4
    assert speed_for_headroom(headroom_f=2, quiet=True) == 4
