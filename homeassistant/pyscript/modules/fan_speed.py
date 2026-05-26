"""MagiqTouch fan speed selection.

Maps chart headroom to fan speed 4-10. Quiet hours cap at 4.
This module imports nothing from Pyscript so it is unit-testable.
"""

_QUIET_CAP = 4


def speed_for_headroom(headroom_f: float, quiet: bool) -> int:
    """Pick a fan speed 4..10 based on how much cooling margin the chart gives us.

    Args:
        headroom_f: target_temp - chart_achievable_temp. Negative means the cooler
            cannot reach the target; we still run at full effort.
        quiet: True during quiet hours (8 PM - 1 AM). Caps result at 4.
    """
    if headroom_f < 0:
        natural = 10  # best effort
    elif headroom_f >= 6:
        natural = 10
    elif headroom_f >= 4:
        natural = 8
    elif headroom_f >= 2:
        natural = 6
    else:
        natural = 4
    return min(natural, _QUIET_CAP) if quiet else natural
