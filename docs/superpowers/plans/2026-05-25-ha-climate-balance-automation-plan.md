# Home Assistant Climate Balance Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Pyscript-based Home Assistant automation that orchestrates a MagiqTouch swamp cooler and whole house fan to maintain target indoor temperature/humidity using the Phillips evaporative-cooling chart, with per-device manual override and Discord notifications.

**Architecture:** Pure-Python logic modules (chart lookup, dew point, decision engine, fan-speed mapping) live in `homeassistant/pyscript/` and are unit-tested with pytest. A thin Pyscript wrapper file (also in `homeassistant/pyscript/`) provides `@state_trigger` decorators that read HA state, call the pure engine, and apply results via HA service calls. HA helpers (input_boolean, input_number, input_datetime) ship via a packages file. Files are mirrored into HAOS `/config/` via Samba (manual sync — see Prerequisites).

**Tech Stack:** Python 3.13 (matches HAOS Pyscript runtime), pytest for unit tests, Home Assistant Pyscript add-on (HACS), Home Assistant `discord` notify integration, `weather.tejon` forecast entity.

**Spec reference:** `docs/superpowers/specs/2026-05-25-ha-climate-balance-automation-design.md`

---

## Prerequisites (must be true before Task 1)

- The Pyscript add-on is installed in HA via HACS. From the HA UI: HACS → Integrations → search "pyscript" → install → restart HA → Settings → Devices & Services → Add Integration → "Pyscript Python scripting" → enable `allow_all_imports: true` and `hass_is_global: true`.
- The Discord notify integration is configured in HA with service name `notify.discord` and channel target `1508674689256652850` already accepted (you provided this in brainstorming).
- A way to push files from this repo's `homeassistant/pyscript/` and `homeassistant/packages/` directories into the HAOS VM's `/config/pyscript/` and `/config/packages/` respectively. Easiest: enable the Samba add-on in HA (Settings → Add-ons → Samba share) and mount `\\homeassistant.local\config` from your dev machine. We will NOT automate this sync in this plan — it is a manual `cp` you run after each phase. (Automating sync is documented as future work in the spec.)
- `configuration.yaml` already includes `homeassistant: packages: !include_dir_named packages` — if not, Task 5 will add a one-line note to do this manually.
- Python 3.13 available locally for running pytest (`brew install python@3.13` if not installed).

---

## File structure (created across the plan)

```
homeassistant/                                    NEW top-level dir in this repo
├── pyscript/
│   ├── climate_balance.py                        Pyscript entry — state triggers, actuators, notifier
│   ├── cooler_chart.py                           Pure Python — chart data + nearest-cell lookup
│   ├── dew_point.py                              Pure Python — Magnus formula
│   ├── fan_speed.py                              Pure Python — headroom → fan speed mapping
│   └── decision_engine.py                        Pure Python — rules + hysteresis + state machine
├── tests/
│   ├── __init__.py
│   ├── conftest.py                               Adds parent dir to sys.path
│   ├── test_cooler_chart.py
│   ├── test_dew_point.py
│   ├── test_fan_speed.py
│   └── test_decision_engine.py
├── packages/
│   └── climate_balance.yaml                      HA helpers (input_boolean / input_number / input_datetime)
├── pyproject.toml                                pytest config, Python 3.13 pin
└── README.md                                     Sync + deployment instructions
```

**Why split pure logic from Pyscript wrapper:** Pyscript injects globals (`state`, `task`, `log`, `@state_trigger`) that don't exist at module-import time outside HA. Pure modules import nothing from Pyscript and can be unit-tested with vanilla pytest. The wrapper file is thin glue.

**Why tests live OUTSIDE `pyscript/`:** Pyscript scans `/config/pyscript/` and tries to execute every `.py` file. Test files import `pytest` (not available in HA's Python) and would error. Keeping tests in a sibling dir prevents pollution.

---

## Phase 1 — Foundation + pure logic + HA helpers (one PR)

End state of phase 1: helpers visible in HA UI; `sensor.outside_dew_point`, `sensor.indoor_dew_point`, `sensor.evap_cooler_achievable_temp` populated and updating; no decision logic yet, no actuation, no notifications.

### Task 1: Scaffold `homeassistant/` directory + pytest setup

**Files:**
- Create: `homeassistant/pyproject.toml`
- Create: `homeassistant/tests/__init__.py`
- Create: `homeassistant/tests/conftest.py`
- Create: `homeassistant/README.md` (stub)
- Create: `homeassistant/.gitignore`

- [ ] **Step 1: Create directory skeleton**

```bash
mkdir -p homeassistant/pyscript homeassistant/tests homeassistant/packages
```

- [ ] **Step 2: Write `homeassistant/pyproject.toml`**

```toml
[project]
name = "ha-climate-balance"
version = "0.1.0"
description = "Pyscript-based climate balance automation for Home Assistant"
requires-python = ">=3.13"

[tool.pytest.ini_options]
testpaths = ["tests"]
python_files = ["test_*.py"]
addopts = "-ra"
```

- [ ] **Step 3: Write `homeassistant/tests/__init__.py`**

Empty file (presence makes `tests` an importable package).

```python
```

- [ ] **Step 4: Write `homeassistant/tests/conftest.py`**

```python
"""Make pyscript/ modules importable as plain Python during tests."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "pyscript"))
```

- [ ] **Step 5: Write `homeassistant/.gitignore`**

```gitignore
__pycache__/
*.pyc
.pytest_cache/
.venv/
```

- [ ] **Step 6: Write `homeassistant/README.md` stub**

```markdown
# Home Assistant Climate Balance

Pyscript-based automation that orchestrates the MagiqTouch swamp cooler and whole house fan.
See `docs/superpowers/specs/2026-05-25-ha-climate-balance-automation-design.md` for design.

## Layout

- `pyscript/` — copies into HAOS `/config/pyscript/`
- `packages/` — copies into HAOS `/config/packages/`
- `tests/` — pytest unit tests for pure logic modules; do NOT sync to HA

## Local test

```bash
cd homeassistant
python3.13 -m venv .venv && source .venv/bin/activate
pip install pytest
pytest
```

## Deploy to HAOS

Manual sync via Samba — see Prerequisites in
`docs/superpowers/plans/2026-05-25-ha-climate-balance-automation-plan.md`.
Later tasks will fill in step-by-step instructions.
```

- [ ] **Step 7: Verify pytest discovers no tests yet (and exits clean)**

```bash
cd homeassistant && python3.13 -m venv .venv && source .venv/bin/activate && pip install pytest && pytest
```

Expected last line: `no tests ran` (exit code 5, which is normal).

- [ ] **Step 8: Commit**

```bash
git checkout -b feat/ha-climate-balance-phase1
git add homeassistant/
git commit -m "feat(ha-climate-balance): scaffold homeassistant/ directory + pytest setup"
```

---

### Task 2: Dew point function (TDD)

**Why dew point first:** Used by the decision engine to compare outside vs indoor moisture content. Trivial pure function, ideal first TDD cycle.

**Files:**
- Create: `homeassistant/pyscript/dew_point.py`
- Create: `homeassistant/tests/test_dew_point.py`

- [ ] **Step 1: Write the failing test**

`homeassistant/tests/test_dew_point.py`:

```python
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
```

- [ ] **Step 2: Run test, verify it fails**

```bash
cd homeassistant && pytest tests/test_dew_point.py -v
```

Expected: `ModuleNotFoundError: No module named 'dew_point'`.

- [ ] **Step 3: Implement `homeassistant/pyscript/dew_point.py`**

```python
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
```

- [ ] **Step 4: Run test, verify it passes**

```bash
cd homeassistant && pytest tests/test_dew_point.py -v
```

Expected: 7 passed (5 parametrized + 2 error cases).

- [ ] **Step 5: Commit**

```bash
git add homeassistant/pyscript/dew_point.py homeassistant/tests/test_dew_point.py
git commit -m "feat(ha-climate-balance): dew point calculation (Magnus formula)"
```

---

### Task 3: Cooler chart lookup (TDD)

**Files:**
- Create: `homeassistant/pyscript/cooler_chart.py`
- Create: `homeassistant/tests/test_cooler_chart.py`

- [ ] **Step 1: Write the failing test**

`homeassistant/tests/test_cooler_chart.py`:

```python
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


def test_outside_below_75_passthrough():
    # Cooler can't improve sub-75 input; lookup returns the input temp
    assert lookup_achievable_temp(65, 30) == 65
    assert lookup_achievable_temp(70, 80) == 70


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
```

- [ ] **Step 2: Run test, verify it fails**

```bash
cd homeassistant && pytest tests/test_cooler_chart.py -v
```

Expected: `ModuleNotFoundError: No module named 'cooler_chart'`.

- [ ] **Step 3: Implement `homeassistant/pyscript/cooler_chart.py`**

```python
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


def lookup_achievable_temp(outside_temp_f: float, outside_rh_pct: float) -> Optional[int]:
    """Return delivered air temperature (°F) at given outside conditions.

    Uses nearest-cell rounding for both temp (5 °F granularity) and RH (5 %).
    Returns None when nearest cell falls in the chart's empty (ineffective) zone.
    Outside temps below 75 °F are returned unchanged (cooler can't improve cold air).
    """
    if outside_temp_f < 75:
        return int(round(outside_temp_f))
    temp_key = min(COOLER_CHART.keys(), key=lambda k: abs(k - outside_temp_f))
    row = COOLER_CHART[temp_key]
    rh_key = min(row.keys(), key=lambda k: abs(k - outside_rh_pct))
    return row.get(rh_key)
```

- [ ] **Step 4: Run test, verify it passes**

```bash
cd homeassistant && pytest tests/test_cooler_chart.py -v
```

Expected: 9 passed.

- [ ] **Step 5: Commit**

```bash
git add homeassistant/pyscript/cooler_chart.py homeassistant/tests/test_cooler_chart.py
git commit -m "feat(ha-climate-balance): evap cooler chart lookup with nearest-cell rounding"
```

---

### Task 4: Fan speed mapping (TDD)

**Files:**
- Create: `homeassistant/pyscript/fan_speed.py`
- Create: `homeassistant/tests/test_fan_speed.py`

- [ ] **Step 1: Write the failing test**

`homeassistant/tests/test_fan_speed.py`:

```python
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
```

- [ ] **Step 2: Run test, verify it fails**

```bash
cd homeassistant && pytest tests/test_fan_speed.py -v
```

Expected: `ModuleNotFoundError: No module named 'fan_speed'`.

- [ ] **Step 3: Implement `homeassistant/pyscript/fan_speed.py`**

```python
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
```

- [ ] **Step 4: Run test, verify it passes**

```bash
cd homeassistant && pytest tests/test_fan_speed.py -v
```

Expected: 8 passed.

- [ ] **Step 5: Commit**

```bash
git add homeassistant/pyscript/fan_speed.py homeassistant/tests/test_fan_speed.py
git commit -m "feat(ha-climate-balance): fan speed mapping with quiet-hours cap"
```

---

### Task 5: HA helpers package YAML

**Files:**
- Create: `homeassistant/packages/climate_balance.yaml`

- [ ] **Step 1: Write `homeassistant/packages/climate_balance.yaml`**

```yaml
# Climate Balance helpers.
# Copy this file to HAOS /config/packages/climate_balance.yaml
# Requires configuration.yaml to contain:
#   homeassistant:
#     packages: !include_dir_named packages

input_boolean:
  climate_balance_enabled:
    name: "Climate Balance Enabled"
    initial: on
    icon: mdi:home-thermometer
  climate_balance_vacation:
    name: "Climate Balance Vacation Mode"
    initial: off
    icon: mdi:airplane

input_number:
  climate_balance_target_temp:
    name: "Target Indoor Temperature"
    min: 65
    max: 80
    step: 1
    initial: 70
    unit_of_measurement: "°F"
    icon: mdi:thermometer
  climate_balance_whf_target:
    name: "Whole House Fan Target Temperature"
    min: 60
    max: 75
    step: 1
    initial: 68
    unit_of_measurement: "°F"
    icon: mdi:fan
  climate_balance_max_indoor_rh:
    name: "Max Indoor Relative Humidity"
    min: 40
    max: 70
    step: 1
    initial: 55
    unit_of_measurement: "%"
    icon: mdi:water-percent
  climate_balance_max_attic_rh:
    name: "Max Attic Relative Humidity"
    min: 40
    max: 70
    step: 1
    initial: 50
    unit_of_measurement: "%"
    icon: mdi:home-roof
  climate_balance_max_dew_point:
    name: "Max Acceptable Dew Point"
    min: 50
    max: 70
    step: 1
    initial: 60
    unit_of_measurement: "°F"
    icon: mdi:water-thermometer
  climate_balance_override_minutes:
    name: "Manual Override Duration"
    min: 15
    max: 240
    step: 15
    initial: 60
    unit_of_measurement: "min"
    icon: mdi:timer

input_datetime:
  cooler_manual_until:
    name: "Swamp Cooler Manual Override Until"
    has_date: true
    has_time: true
  whf_manual_until:
    name: "Whole House Fan Manual Override Until"
    has_date: true
    has_time: true
```

- [ ] **Step 2: Deploy to HAOS**

Copy via Samba mount:

```bash
cp homeassistant/packages/climate_balance.yaml /Volumes/config/packages/climate_balance.yaml
```

(Mount path varies — `\\homeassistant.local\config` mounted as `/Volumes/config` on macOS.)

Or via SSH/HAOS terminal if you have it set up. Same target path: `/config/packages/climate_balance.yaml`.

- [ ] **Step 3: Verify packages include line in configuration.yaml**

In HA UI → Settings → Add-ons → File editor → open `/config/configuration.yaml`. Confirm the `homeassistant:` section contains:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

If missing, add it. (If the file already has another `homeassistant:` key, add `packages: !include_dir_named packages` as a child rather than duplicating the key.)

- [ ] **Step 4: Reload HA YAML config**

In HA UI: Developer Tools → YAML → "All YAML configuration" → reload.

Watch the notification panel: any YAML error will surface immediately.

- [ ] **Step 5: Verify helpers exist**

In HA UI → Settings → Devices & Services → Helpers tab. Search for "climate_balance". You should see:

- 2 input_boolean entries
- 7 input_number entries
- 2 input_datetime entries

Or in Developer Tools → States, type `input_boolean.climate_balance_enabled` — should resolve to state `on`.

- [ ] **Step 6: Commit**

```bash
git add homeassistant/packages/climate_balance.yaml
git commit -m "feat(ha-climate-balance): HA helpers package (input_boolean/number/datetime)"
```

---

### Task 6: Pyscript derived sensors entry point

**Why this task:** Get the dew-point and chart-achievable sensors visible in HA. No decision logic yet — just expose computed values so we can verify the data before building any state machine on top of it.

**Files:**
- Create: `homeassistant/pyscript/climate_balance.py`

- [ ] **Step 1: Write `homeassistant/pyscript/climate_balance.py`**

```python
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
```

- [ ] **Step 2: Deploy pyscript files to HAOS**

```bash
cp homeassistant/pyscript/dew_point.py /Volumes/config/pyscript/dew_point.py
cp homeassistant/pyscript/cooler_chart.py /Volumes/config/pyscript/cooler_chart.py
cp homeassistant/pyscript/fan_speed.py /Volumes/config/pyscript/fan_speed.py
cp homeassistant/pyscript/climate_balance.py /Volumes/config/pyscript/climate_balance.py
```

`fan_speed.py` is unused in Phase 1 but copying it now means Phase 2 doesn't need a redeploy of every file — only the changed one.

- [ ] **Step 3: Reload Pyscript**

In HA UI → Developer Tools → Services → call `pyscript.reload` (no parameters). Watch the Logs panel for `climate_balance: initial derived-sensor computation`.

If you see `ModuleNotFoundError` on any sibling import, confirm `allow_all_imports: true` in Pyscript integration config (Settings → Devices & Services → Pyscript → Configure).

- [ ] **Step 4: Verify sensors populated**

In HA UI → Developer Tools → States. Search each:

- `sensor.outside_dew_point` — should show a number with unit `°F`, e.g., `52.3`. Cross-check by hand: at the current outside temp + RH, the result should be within ~5 °F of the temp for typical conditions.
- `sensor.indoor_dew_point` — similar.
- `sensor.evap_cooler_achievable_temp` — should show an integer °F value matching the chart. If outside is below 75 °F, value equals outside temp.

If any sensor shows `unavailable`, check the source entity is populated (e.g., `sensor.attic_sensor_humidity` not `unknown`).

- [ ] **Step 5: Commit**

```bash
git add homeassistant/pyscript/climate_balance.py
git commit -m "feat(ha-climate-balance): derived sensors (dew points + chart achievable temp)"
```

---

### Task 7: Phase 1 README + open PR

**Files:**
- Modify: `homeassistant/README.md`

- [ ] **Step 1: Expand `homeassistant/README.md`**

Replace the stub with:

```markdown
# Home Assistant Climate Balance

Pyscript-based automation that orchestrates the MagiqTouch swamp cooler and whole
house fan to maintain target indoor temperature/humidity using the Phillips
evaporative-cooling chart.

Spec: `docs/superpowers/specs/2026-05-25-ha-climate-balance-automation-design.md`
Plan: `docs/superpowers/plans/2026-05-25-ha-climate-balance-automation-plan.md`

## Layout

| Path | Purpose | Synced to HAOS? |
|---|---|---|
| `pyscript/dew_point.py` | Magnus formula | yes → `/config/pyscript/` |
| `pyscript/cooler_chart.py` | Chart data + nearest-cell lookup | yes → `/config/pyscript/` |
| `pyscript/fan_speed.py` | Headroom → fan speed mapping | yes → `/config/pyscript/` |
| `pyscript/decision_engine.py` | Pure decision logic (Phase 2+) | yes → `/config/pyscript/` |
| `pyscript/climate_balance.py` | Pyscript entry (state triggers, actuators, notifier) | yes → `/config/pyscript/` |
| `packages/climate_balance.yaml` | HA helpers (input_boolean / input_number / input_datetime) | yes → `/config/packages/` |
| `tests/` | pytest unit tests for pure modules | **no** — never copy to HAOS |
| `pyproject.toml` | pytest config | **no** |

## Local test

```bash
cd homeassistant
python3.13 -m venv .venv && source .venv/bin/activate
pip install pytest
pytest -v
```

All pure-logic modules (`dew_point`, `cooler_chart`, `fan_speed`, `decision_engine`)
are testable without HA. The Pyscript wrapper file (`climate_balance.py`) is not
unit-tested — its logic is thin glue, and integration is verified by deploying
to HA and watching `sensor.climate_balance_*` entities.

## Deploy to HAOS

1. Enable Samba in HA (Settings → Add-ons → Samba share).
2. Mount `\\homeassistant.local\config` on your dev machine.
3. Sync (macOS example):

   ```bash
   cp pyscript/*.py /Volumes/config/pyscript/
   cp packages/*.yaml /Volumes/config/packages/
   ```

4. Reload:
   - YAML config: HA UI → Developer Tools → YAML → "All YAML configuration"
   - Pyscript: HA UI → Developer Tools → Services → `pyscript.reload`

5. Verify in HA UI → Developer Tools → States:
   - `sensor.outside_dew_point`, `sensor.indoor_dew_point`,
     `sensor.evap_cooler_achievable_temp` populated with numeric °F values
   - `sensor.climate_balance_mode`, `sensor.climate_balance_reason`,
     `sensor.climate_balance_status` populated once Phase 2 lands

## Verify on HAOS

After any deploy, in HA UI → Settings → System → Logs, filter for `pyscript` to see
state-trigger fires and decision-engine notifications.

## Master kill

`input_boolean.climate_balance_enabled` → off disables the automation entirely.
`input_boolean.climate_balance_vacation` → on does the same and also clears any
active per-device manual overrides.
```

- [ ] **Step 2: Commit + open PR**

```bash
git add homeassistant/README.md
git commit -m "docs(ha-climate-balance): README with sync + verify instructions"
git push -u origin feat/ha-climate-balance-phase1
gh pr create --title "feat(ha-climate-balance): phase 1 — derived sensors + helpers" --body "$(cat <<'EOF'
## Summary
- Scaffolds `homeassistant/` directory with pytest setup
- Pure Python modules: dew point, cooler chart, fan speed (all unit-tested)
- HA helpers package: input_booleans, input_numbers, input_datetimes
- Pyscript entry exposing `sensor.outside_dew_point`, `sensor.indoor_dew_point`, `sensor.evap_cooler_achievable_temp`
- README with sync + verify instructions

No decision logic, no actuation, no notifications yet — those land in Phase 2.

Spec: `docs/superpowers/specs/2026-05-25-ha-climate-balance-automation-design.md`
Plan: `docs/superpowers/plans/2026-05-25-ha-climate-balance-automation-plan.md`

## Test plan
- [ ] `cd homeassistant && pytest -v` passes (dew_point, cooler_chart, fan_speed)
- [ ] Helpers visible in HA UI → Settings → Devices & Services → Helpers
- [ ] `sensor.outside_dew_point` populated with sane °F value
- [ ] `sensor.indoor_dew_point` populated with sane °F value
- [ ] `sensor.evap_cooler_achievable_temp` populated with chart value for current outside conditions

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Phase 2 — Decision engine + dry-run integration (one PR)

End state of phase 2: `sensor.climate_balance_mode` and `sensor.climate_balance_reason` reflect what the engine *would* do; Discord notifications fire on every mode transition; no actuation yet (cooler and WHF untouched). User verifies decisions match expectations for 1-2 days before Phase 3.

### Task 8: Decision engine — dataclasses + skeleton

**Files:**
- Create: `homeassistant/pyscript/decision_engine.py`

- [ ] **Step 1: Write `homeassistant/pyscript/decision_engine.py` (dataclasses + enum only)**

```python
"""Pure decision engine for climate balance.

Inputs: current sensor readings + helper config + wall-clock time + last-transition info.
Output: a Decision describing desired mode, device actuations, and human-readable reason.

This module imports nothing from Pyscript so it is unit-testable.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Optional

from cooler_chart import lookup_achievable_temp
from dew_point import dew_point_f
from fan_speed import speed_for_headroom


class Mode(Enum):
    OFF = "OFF"
    WHF_ONLY = "WHF_ONLY"
    COOLER_FULL = "COOLER_FULL"
    COOLER_QUIET = "COOLER_QUIET"
    DEHUMIDIFY = "DEHUMIDIFY"
    RECIRCULATE = "RECIRCULATE"


@dataclass(frozen=True)
class ClimateState:
    """Snapshot of all sensor readings the engine needs."""
    outside_temp_f: Optional[float]
    outside_rh_pct: Optional[float]
    indoor_temp_f: Optional[float]
    indoor_rh_pct: Optional[float]
    attic_temp_f: Optional[float]
    attic_rh_pct: Optional[float]

    @property
    def has_required(self) -> bool:
        """True if we have the minimum sensors to make any decision."""
        return all(v is not None for v in (
            self.outside_temp_f, self.outside_rh_pct,
            self.indoor_temp_f, self.indoor_rh_pct,
        ))


@dataclass(frozen=True)
class Config:
    """Snapshot of all helper input values."""
    enabled: bool
    vacation: bool
    target_temp_f: float
    whf_target_f: float
    max_indoor_rh: float
    max_attic_rh: float
    max_dew_point_f: float


@dataclass(frozen=True)
class Decision:
    """What the engine decided. Actuators consume this."""
    mode: Mode
    cooler_hvac_mode: str          # "cool", "fan_only", "off"
    cooler_fan_speed: Optional[int]  # 0-10 or None when off
    whf_on: bool
    reason: str                    # human-readable, goes to sensor.climate_balance_reason


# Dead bands for hysteresis (entry threshold; exit is the configured limit)
TEMP_DEAD_BAND_F = 2.0
RH_DEAD_BAND = 5.0
DEHUMIDIFY_FAN_SPEED = 2
```

- [ ] **Step 2: Verify import works**

```bash
cd homeassistant && python3.13 -c "from pyscript.decision_engine import Mode, Decision, ClimateState, Config; print('ok')"
```

Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git checkout -b feat/ha-climate-balance-phase2 main
git add homeassistant/pyscript/decision_engine.py
git commit -m "feat(ha-climate-balance): decision engine dataclasses + Mode enum"
```

---

### Task 9: Decision engine — `evaluate()` with all rules (TDD)

**Files:**
- Modify: `homeassistant/pyscript/decision_engine.py`
- Create: `homeassistant/tests/test_decision_engine.py`

- [ ] **Step 1: Write the failing test (covers all rules + priority order + hysteresis)**

`homeassistant/tests/test_decision_engine.py`:

```python
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


def test_indoor_humid_but_outside_humid_too_recirculate():
    # Indoor 62% RH at 75°F → indoor DP ~62°F.
    # Outside 90°F at 70% RH → outside DP ~79°F. Worse — recirculate.
    d = evaluate(
        _state(indoor_rh_pct=62.0, indoor_temp_f=75.0,
               outside_temp_f=90.0, outside_rh_pct=70.0),
        _cfg(), _NOON,
    )
    assert d.mode == Mode.RECIRCULATE


def test_attic_humidity_hysteresis():
    # Below threshold + 5 (i.e., 54%) → should NOT fire DEHUMIDIFY
    d = evaluate(
        _state(attic_rh_pct=53.0, indoor_temp_f=70.0, indoor_rh_pct=45.0),
        _cfg(max_attic_rh=50.0), _NOON,
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
```

- [ ] **Step 2: Run test, verify it fails**

```bash
cd homeassistant && pytest tests/test_decision_engine.py -v
```

Expected: `ImportError` — `evaluate` not defined.

- [ ] **Step 3: Append the `evaluate()` function to `homeassistant/pyscript/decision_engine.py`**

```python
def _in_quiet_hours(now: datetime) -> bool:
    """8 PM - 1 AM local time."""
    h = now.hour
    return h >= 20 or h < 1


def _off(reason: str) -> Decision:
    return Decision(
        mode=Mode.OFF, cooler_hvac_mode="off",
        cooler_fan_speed=None, whf_on=False, reason=reason,
    )


def _recirculate(reason: str) -> Decision:
    return Decision(
        mode=Mode.RECIRCULATE, cooler_hvac_mode="off",
        cooler_fan_speed=None, whf_on=False, reason=reason,
    )


def _whf_only(reason: str) -> Decision:
    return Decision(
        mode=Mode.WHF_ONLY, cooler_hvac_mode="off",
        cooler_fan_speed=None, whf_on=True, reason=reason,
    )


def _dehumidify(reason: str) -> Decision:
    return Decision(
        mode=Mode.DEHUMIDIFY, cooler_hvac_mode="fan_only",
        cooler_fan_speed=DEHUMIDIFY_FAN_SPEED, whf_on=True, reason=reason,
    )


def _cooler(quiet: bool, fan_speed: int, reason: str) -> Decision:
    return Decision(
        mode=Mode.COOLER_QUIET if quiet else Mode.COOLER_FULL,
        cooler_hvac_mode="cool", cooler_fan_speed=fan_speed,
        whf_on=True, reason=reason,
    )


def evaluate(s: ClimateState, c: Config, now: datetime) -> Decision:
    """Compute the desired operating mode given current state, config, and time.

    Pure function — no I/O. See spec rules 1-6.
    """
    # Rule 1: master kill
    if not c.enabled:
        return _off("Climate balance disabled (master toggle)")
    if c.vacation:
        return _off("Vacation mode — climate balance suspended")

    if not s.has_required:
        return _off("Required sensor unavailable — holding off")

    # Rule 2: dehumidify (attic OR indoor RH above limit + dead band)
    attic_too_humid = (s.attic_rh_pct is not None
                      and s.attic_rh_pct > c.max_attic_rh + RH_DEAD_BAND)
    indoor_too_humid = s.indoor_rh_pct > c.max_indoor_rh + RH_DEAD_BAND
    if attic_too_humid or indoor_too_humid:
        outside_dp = dew_point_f(s.outside_temp_f, s.outside_rh_pct)
        indoor_dp = dew_point_f(s.indoor_temp_f, s.indoor_rh_pct)
        if outside_dp < indoor_dp:
            src = (f"attic RH {s.attic_rh_pct:.0f}%" if attic_too_humid
                   else f"indoor RH {s.indoor_rh_pct:.0f}%")
            return _dehumidify(
                f"Dehumidify — {src} above limit; outside DP {outside_dp:.0f}°F "
                f"< indoor DP {indoor_dp:.0f}°F so pulling outside air helps"
            )
        return _recirculate(
            f"Indoor humid but outside dew point {outside_dp:.0f}°F worse than "
            f"indoor {indoor_dp:.0f}°F — recirculating only"
        )

    # Rule 3: free cooling (WHF only)
    outside_cooler = s.outside_temp_f < s.indoor_temp_f - TEMP_DEAD_BAND_F
    above_whf_target = s.indoor_temp_f > c.whf_target_f
    if outside_cooler and above_whf_target:
        return _whf_only(
            f"Free cooling — outside {s.outside_temp_f:.0f}°F < indoor "
            f"{s.indoor_temp_f:.0f}°F, target {c.whf_target_f:.0f}°F"
        )

    # Rule 4: active cooling
    needs_cooling = s.indoor_temp_f > c.target_temp_f + TEMP_DEAD_BAND_F
    if needs_cooling:
        achievable = lookup_achievable_temp(s.outside_temp_f, s.outside_rh_pct)
        outside_dp = dew_point_f(s.outside_temp_f, s.outside_rh_pct)
        if outside_dp > c.max_dew_point_f:
            return _recirculate(
                f"Cooling needed but outside dew point {outside_dp:.0f}°F > limit "
                f"{c.max_dew_point_f:.0f}°F — recirculating"
            )
        if achievable is None or achievable > c.target_temp_f:
            return _recirculate(
                f"Cooling needed but chart says achievable "
                f"{achievable if achievable is not None else 'N/A'} > target "
                f"{c.target_temp_f:.0f}°F — recirculating"
            )
        quiet = _in_quiet_hours(now)
        headroom = c.target_temp_f - achievable
        speed = speed_for_headroom(headroom, quiet=quiet)
        return _cooler(
            quiet, speed,
            f"{'Quiet ' if quiet else ''}cooler + WHF — chart says we can hit "
            f"{achievable}°F (outside {s.outside_temp_f:.0f}°F @ "
            f"{s.outside_rh_pct:.0f}% RH, fan speed {speed})"
        )

    # Rule 6: idle
    return _off(
        f"All in range — indoor {s.indoor_temp_f:.0f}°F (target "
        f"{c.target_temp_f:.0f}°F), RH {s.indoor_rh_pct:.0f}%"
    )
```

- [ ] **Step 4: Run all tests, verify they pass**

```bash
cd homeassistant && pytest -v
```

Expected: All tests pass (dew_point + cooler_chart + fan_speed + decision_engine ≈ 35+ tests).

- [ ] **Step 5: Commit**

```bash
git add homeassistant/pyscript/decision_engine.py homeassistant/tests/test_decision_engine.py
git commit -m "feat(ha-climate-balance): decision engine rules 1-6 with hysteresis"
```

---

### Task 10: Pyscript integration — dry-run engine + Discord notifier + mode/reason/status sensors

**Why one large task:** these three pieces are inseparable for verifying Phase 2 works (you can't see decisions without sensors; you can't validate dry-run without notifications).

**Files:**
- Modify: `homeassistant/pyscript/climate_balance.py`

- [ ] **Step 1: Rewrite `homeassistant/pyscript/climate_balance.py` with dry-run engine**

Replace the entire file with:

```python
"""Pyscript entry point for climate balance.

Phase 1: derived sensors only.
Phase 2 (this version): derived sensors + decision engine in DRY-RUN mode.
  - Computes desired mode via decision_engine.evaluate()
  - Updates sensor.climate_balance_mode / _reason / _status
  - Sends Discord notification on mode transition
  - Does NOT call climate.set_* or switch.turn_* yet

Phase 3 will flip _ACTUATE = True and wire actuators.
"""
from datetime import datetime

from cooler_chart import lookup_achievable_temp
from decision_engine import ClimateState, Config, Decision, Mode, evaluate
from dew_point import dew_point_f


_ACTUATE = False   # Phase 3 flips this to True
_DISCORD_TARGET = "1508674689256652850"

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


def _build_state() -> ClimateState:
    return ClimateState(
        outside_temp_f=_read_float(_S_OUT_T),
        outside_rh_pct=_read_float(_S_OUT_RH),
        indoor_temp_f=_read_float(_S_AVG_T),
        indoor_rh_pct=_read_float(_S_AVG_RH),
        attic_temp_f=_read_float(_S_ATTIC_T),
        attic_rh_pct=_read_float(_S_ATTIC_RH),
    )


def _build_config() -> Config:
    return Config(
        enabled=_read_bool(_H_ENABLED),
        vacation=_read_bool(_H_VACATION),
        target_temp_f=_read_float(_H_TARGET) or 70.0,
        whf_target_f=_read_float(_H_WHF_TARGET) or 68.0,
        max_indoor_rh=_read_float(_H_MAX_INDOOR_RH) or 55.0,
        max_attic_rh=_read_float(_H_MAX_ATTIC_RH) or 50.0,
        max_dew_point_f=_read_float(_H_MAX_DP) or 60.0,
    )


def _recompute_derived(s: ClimateState):
    """Update outside/indoor DP + achievable sensors."""
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


def _notify_transition(prev: Mode, d: Decision):
    """Send Discord notification when mode changes."""
    emoji = _MODE_EMOJI.get(d.mode, "ℹ️")
    body = f"{d.mode.value} — {d.reason}"
    if not _ACTUATE:
        body = f"[DRY-RUN] {body}"
    log.info(f"climate_balance transition: {prev.value if prev else 'init'} -> "
             f"{d.mode.value}: {d.reason}")
    notify.discord(message=f"{emoji} {body}", target=[_DISCORD_TARGET])


def _expose_decision(d: Decision):
    """Push mode + reason to sensors regardless of transition."""
    _set_sensor(_S_MODE, d.mode.value,
                attrs={"friendly_name": "Climate Balance Mode",
                       "icon": "mdi:home-thermometer"})
    _set_sensor(_S_REASON, d.reason,
                attrs={"friendly_name": "Climate Balance Reason"})
    _set_sensor(_S_STATUS, "Auto" if _ACTUATE else "Dry-run (Phase 2)",
                attrs={"friendly_name": "Climate Balance Status"})


def _evaluate_and_apply():
    """Main loop: read state, decide, expose, notify on transition."""
    s = _build_state()
    c = _build_config()
    _recompute_derived(s)
    d = evaluate(s, c, datetime.now())

    prev_raw = state.get(_S_MODE)
    try:
        prev = Mode(prev_raw) if prev_raw and prev_raw not in (
            "unknown", "unavailable", "") else None
    except ValueError:
        prev = None

    _expose_decision(d)

    if prev != d.mode:
        _notify_transition(prev, d)


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
```

- [ ] **Step 2: Deploy to HAOS**

```bash
cp homeassistant/pyscript/decision_engine.py /Volumes/config/pyscript/
cp homeassistant/pyscript/climate_balance.py /Volumes/config/pyscript/
```

- [ ] **Step 3: Reload Pyscript**

HA UI → Developer Tools → Services → `pyscript.reload`.

Watch logs for `climate_balance: startup — Phase 2 dry-run engine active`.

- [ ] **Step 4: Verify mode sensor exists**

HA UI → Developer Tools → States. Search:

- `sensor.climate_balance_mode` — should resolve to one of the 6 mode values (e.g., `OFF`)
- `sensor.climate_balance_reason` — should resolve to a human-readable sentence
- `sensor.climate_balance_status` — should resolve to `Dry-run (Phase 2)`

If any show `unavailable`, check Pyscript logs for errors.

- [ ] **Step 5: Force a transition to verify Discord**

In HA UI → Developer Tools → States, click on `input_number.climate_balance_target_temp` and set value to `60`. This makes any current indoor temp "too hot" and forces a non-OFF decision. Watch:

1. `sensor.climate_balance_mode` updates within ~1 second
2. Discord channel `1508674689256652850` receives a message starting with `[DRY-RUN]`

Set the target back to `70` after verifying.

- [ ] **Step 6: Commit + open PR**

```bash
git add homeassistant/pyscript/climate_balance.py
git commit -m "feat(ha-climate-balance): dry-run engine integration + Discord notifications"
git push -u origin feat/ha-climate-balance-phase2
gh pr create --title "feat(ha-climate-balance): phase 2 — decision engine + dry-run integration" --body "$(cat <<'EOF'
## Summary
- Pure decision engine with all 6 rules, hysteresis, and quiet-hours handling (~25 unit tests)
- Pyscript dry-run integration: engine evaluates on every state change + 5-min heartbeat
- `sensor.climate_balance_mode` / `_reason` / `_status` expose what engine would do
- Discord notifications fire on mode transitions, prefixed `[DRY-RUN]`
- No actuation yet — Phase 3 wires that up

Spec: `docs/superpowers/specs/2026-05-25-ha-climate-balance-automation-design.md`
Plan: `docs/superpowers/plans/2026-05-25-ha-climate-balance-automation-plan.md`

## Test plan
- [ ] `cd homeassistant && pytest -v` passes (≈ 35+ tests)
- [ ] `sensor.climate_balance_mode` populated with one of 6 valid Mode values
- [ ] `sensor.climate_balance_reason` populated with human-readable sentence
- [ ] Forcing target_temp = 60 causes mode transition + Discord notification within 1 second
- [ ] Discord notifications prefixed `[DRY-RUN]`
- [ ] Run for 24-48 hours and confirm mode decisions match user judgment

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Phase 3 — Actuation + manual override (one PR, gated on Phase 2 verification)

End state of phase 3: engine actually controls `climate.magiqtouch` and `switch.wholehousefanplug`; per-device manual override detection works; danger warnings fire during overrides; status sensor reflects override state.

### Task 11: Actuator functions

**Files:**
- Modify: `homeassistant/pyscript/climate_balance.py`

- [ ] **Step 1: Add actuator helpers**

At the top of `climate_balance.py` near other constants, add:

```python
_E_COOLER = "climate.magiqtouch"
_E_WHF = "switch.wholehousefanplug"
```

Before the `_evaluate_and_apply` function, add:

```python
def _actuate(d: Decision):
    """Apply Decision to the physical devices. Idempotent: only calls services
    if device state actually differs from the desired state.
    """
    # Cooler HVAC mode
    cur_mode = state.get(_E_COOLER)  # "cool" / "fan_only" / "off"
    if cur_mode != d.cooler_hvac_mode:
        climate.set_hvac_mode(entity_id=_E_COOLER, hvac_mode=d.cooler_hvac_mode)

    # Cooler fan speed (only meaningful when not off)
    if d.cooler_fan_speed is not None:
        cur_fan = state.getattr(_E_COOLER).get("fan_mode")
        desired_fan = str(d.cooler_fan_speed)
        if cur_fan != desired_fan:
            climate.set_fan_mode(entity_id=_E_COOLER, fan_mode=desired_fan)

    # WHF
    cur_whf = state.get(_E_WHF)  # "on" / "off"
    desired_whf = "on" if d.whf_on else "off"
    if cur_whf != desired_whf:
        if d.whf_on:
            switch.turn_on(entity_id=_E_WHF)
        else:
            switch.turn_off(entity_id=_E_WHF)
```

- [ ] **Step 2: Commit (no behavior change yet — gated by `_ACTUATE`)**

```bash
git checkout -b feat/ha-climate-balance-phase3 main
git add homeassistant/pyscript/climate_balance.py
git commit -m "feat(ha-climate-balance): actuator functions (still dry-run via _ACTUATE flag)"
```

---

### Task 12: Manual override detection + per-device snooze

**Why bundled:** detection and snooze are two halves of the same feature; can't test one without the other.

**Files:**
- Modify: `homeassistant/pyscript/climate_balance.py`

- [ ] **Step 1: Add override-aware state + snooze helpers**

Near other constants in `climate_balance.py`:

```python
_H_OVERRIDE_MIN = "input_number.climate_balance_override_minutes"
_H_COOLER_UNTIL = "input_datetime.cooler_manual_until"
_H_WHF_UNTIL = "input_datetime.whf_manual_until"

# Track our own service-call context so we can distinguish "we did it" from
# "user did it" in @state_trigger callbacks. Pyscript context_id is populated
# when WE call a service; user actions get a different context.
_OUR_USER_IDS: set[str] = set()
```

Add helpers:

```python
from datetime import timedelta


def _datetime_helper_in_future(entity_id) -> bool:
    """True if input_datetime helper resolves to a time later than now."""
    raw = state.get(entity_id)
    if not raw or raw in ("unknown", "unavailable"):
        return False
    try:
        # HA input_datetime serializes as 'YYYY-MM-DD HH:MM:SS'
        ts = datetime.fromisoformat(raw.replace(" ", "T"))
    except ValueError:
        return False
    return ts > datetime.now()


def _snooze_active(device: str) -> bool:
    """device: 'cooler' or 'whf'."""
    return _datetime_helper_in_future(
        _H_COOLER_UNTIL if device == "cooler" else _H_WHF_UNTIL
    )


def _start_snooze(device: str):
    duration = _read_float(_H_OVERRIDE_MIN) or 60.0
    until = datetime.now() + timedelta(minutes=duration)
    service_data = {
        "entity_id": (_H_COOLER_UNTIL if device == "cooler"
                      else _H_WHF_UNTIL),
        "datetime": until.strftime("%Y-%m-%d %H:%M:%S"),
    }
    # input_datetime.set_datetime service call
    service.call("input_datetime", "set_datetime", **service_data)
    log.info(f"climate_balance: {device} manual override → {until.isoformat()}")
    notify.discord(
        message=f"📱 Manual override detected on "
                f"{'swamp cooler' if device == 'cooler' else 'whole house fan'} "
                f"— pausing automation for {int(duration)} min",
        target=[_DISCORD_TARGET],
    )
```

Add state triggers for manual changes (place near other `@state_trigger` defs):

```python
@state_trigger(_E_COOLER)
def on_cooler_change(value=None, old_value=None, context=None):
    """If user changed the cooler (not us), start a snooze on it."""
    # context.user_id is None when state.set fired without a user; set when a
    # service call from a real user (UI, app, Z-Wave, voice) triggered it.
    user_id = getattr(context, "user_id", None) if context else None
    if user_id is None:
        return
    if user_id in _OUR_USER_IDS:
        return
    _start_snooze("cooler")


@state_trigger(_E_WHF)
def on_whf_change(value=None, old_value=None, context=None):
    user_id = getattr(context, "user_id", None) if context else None
    if user_id is None:
        return
    if user_id in _OUR_USER_IDS:
        return
    _start_snooze("whf")
```

Wrap the actuator to respect snoozes and record context:

```python
def _actuate_respecting_overrides(d: Decision):
    """Apply Decision but skip devices currently under manual snooze."""
    cooler_snoozed = _snooze_active("cooler")
    whf_snoozed = _snooze_active("whf")

    # Cooler
    if not cooler_snoozed:
        cur_mode = state.get(_E_COOLER)
        if cur_mode != d.cooler_hvac_mode:
            climate.set_hvac_mode(entity_id=_E_COOLER, hvac_mode=d.cooler_hvac_mode)
        if d.cooler_fan_speed is not None:
            cur_fan = state.getattr(_E_COOLER).get("fan_mode")
            desired_fan = str(d.cooler_fan_speed)
            if cur_fan != desired_fan:
                climate.set_fan_mode(entity_id=_E_COOLER, fan_mode=desired_fan)

    # WHF
    if not whf_snoozed:
        cur_whf = state.get(_E_WHF)
        desired_whf = "on" if d.whf_on else "off"
        if cur_whf != desired_whf:
            if d.whf_on:
                switch.turn_on(entity_id=_E_WHF)
            else:
                switch.turn_off(entity_id=_E_WHF)
```

Update `_expose_decision` to reflect snooze status:

```python
def _expose_decision(d: Decision):
    _set_sensor(_S_MODE, d.mode.value,
                attrs={"friendly_name": "Climate Balance Mode"})
    _set_sensor(_S_REASON, d.reason,
                attrs={"friendly_name": "Climate Balance Reason"})

    cooler_snoozed = _snooze_active("cooler")
    whf_snoozed = _snooze_active("whf")
    if not _read_bool(_H_ENABLED):
        status = "Disabled"
    elif _read_bool(_H_VACATION):
        status = "Vacation"
    elif cooler_snoozed and whf_snoozed:
        status = "Both devices in manual override"
    elif cooler_snoozed:
        status = "Cooler in manual override"
    elif whf_snoozed:
        status = "WHF in manual override"
    else:
        status = "Auto"
    _set_sensor(_S_STATUS, status,
                attrs={"friendly_name": "Climate Balance Status"})
```

- [ ] **Step 2: Deploy + reload**

```bash
cp homeassistant/pyscript/climate_balance.py /Volumes/config/pyscript/
```

HA UI → Developer Tools → Services → `pyscript.reload`.

- [ ] **Step 3: Verify manual override end-to-end**

1. In HA UI, manually toggle `switch.wholehousefanplug` from your phone or browser
2. Within 1-2 seconds, expect a Discord message: `📱 Manual override detected on whole house fan — pausing automation for 60 min`
3. `sensor.climate_balance_status` should now read `WHF in manual override`
4. `input_datetime.whf_manual_until` should be set to ~60 min in the future
5. Set `input_datetime.whf_manual_until` to a past time (HA UI → click on it → set date/time to yesterday)
6. Trigger a re-evaluation by changing target temp briefly
7. `sensor.climate_balance_status` should return to `Auto`

- [ ] **Step 4: Commit**

```bash
git add homeassistant/pyscript/climate_balance.py
git commit -m "feat(ha-climate-balance): per-device manual override detection + snooze"
```

---

### Task 13: Enable actuation + resume-after-snooze + danger warnings

**Files:**
- Modify: `homeassistant/pyscript/climate_balance.py`

- [ ] **Step 1: Flip `_ACTUATE` and call `_actuate_respecting_overrides()`**

In `climate_balance.py`:

```python
_ACTUATE = True   # Phase 3: live!
```

Update `_evaluate_and_apply` to actuate:

```python
def _evaluate_and_apply():
    s = _build_state()
    c = _build_config()
    _recompute_derived(s)
    d = evaluate(s, c, datetime.now())

    prev_raw = state.get(_S_MODE)
    try:
        prev = Mode(prev_raw) if prev_raw and prev_raw not in (
            "unknown", "unavailable", "") else None
    except ValueError:
        prev = None

    _expose_decision(d)

    if _ACTUATE:
        _actuate_respecting_overrides(d)

    if prev != d.mode:
        _notify_transition(prev, d)

    _maybe_warn_danger(s, c, d)
```

- [ ] **Step 2: Add resume-after-snooze logic**

Add a 1-minute trigger that checks for newly-expired snoozes:

```python
_last_cooler_snoozed = False
_last_whf_snoozed = False


@time_trigger("period(now, 1min)")
def check_snooze_expiry():
    """Detect snooze expiry edges and notify resume."""
    global _last_cooler_snoozed, _last_whf_snoozed
    cur_cooler = _snooze_active("cooler")
    cur_whf = _snooze_active("whf")

    if _last_cooler_snoozed and not cur_cooler:
        _on_snooze_expire("cooler")
    if _last_whf_snoozed and not cur_whf:
        _on_snooze_expire("whf")

    _last_cooler_snoozed = cur_cooler
    _last_whf_snoozed = cur_whf


def _on_snooze_expire(device: str):
    """Called once when a snooze transitions from active → inactive."""
    s = _build_state()
    c = _build_config()
    d = evaluate(s, c, datetime.now())

    device_label = "swamp cooler" if device == "cooler" else "whole house fan"

    # If current device state already matches desired, silent resume
    if device == "cooler":
        cur_mode = state.get(_E_COOLER)
        if cur_mode == d.cooler_hvac_mode:
            log.info(f"climate_balance: cooler snooze expired, silent resume "
                     f"(already in {cur_mode})")
            return
    else:
        cur_whf = state.get(_E_WHF)
        desired = "on" if d.whf_on else "off"
        if cur_whf == desired:
            log.info(f"climate_balance: whf snooze expired, silent resume "
                     f"(already {cur_whf})")
            return

    notify.discord(
        message=f"▶️ Resuming {device_label} automation — switching to "
                f"{d.mode.value} ({d.reason})",
        target=[_DISCORD_TARGET],
    )
    _actuate_respecting_overrides(d)
```

- [ ] **Step 3: Add danger-condition warning during snoozes**

```python
# Module-level dict tracking which danger conditions we already warned about
# within the current snooze window. Cleared when snooze expires.
_warned_during_snooze: dict[str, set[str]] = {"cooler": set(), "whf": set()}


def _maybe_warn_danger(s: ClimateState, c: Config, d: Decision):
    """Warn (once per condition per snooze) when danger conditions persist
    while the relevant device is under manual override."""
    if not s.has_required:
        return

    # Danger: attic RH > limit + 10
    if (s.attic_rh_pct is not None
            and s.attic_rh_pct > c.max_attic_rh + 10
            and _snooze_active("cooler")
            and "attic_humid" not in _warned_during_snooze["cooler"]):
        notify.discord(
            message=f"⚠️ Attic humidity at {s.attic_rh_pct:.0f}% but swamp cooler "
                    f"is in manual override — consider intervening",
            target=[_DISCORD_TARGET],
        )
        _warned_during_snooze["cooler"].add("attic_humid")

    # Danger: indoor > target + 5
    if (s.indoor_temp_f > c.target_temp_f + 5
            and (_snooze_active("cooler") or _snooze_active("whf"))):
        for device in ("cooler", "whf"):
            if _snooze_active(device) and "too_hot" not in _warned_during_snooze[device]:
                device_label = "swamp cooler" if device == "cooler" else "whole house fan"
                notify.discord(
                    message=f"⚠️ Indoor temperature at {s.indoor_temp_f:.0f}°F "
                            f"(target {c.target_temp_f:.0f}°F) but {device_label} "
                            f"is in manual override — consider intervening",
                    target=[_DISCORD_TARGET],
                )
                _warned_during_snooze[device].add("too_hot")

    # Clear warnings when snooze ends
    for device in ("cooler", "whf"):
        if not _snooze_active(device):
            _warned_during_snooze[device].clear()
```

- [ ] **Step 4: Deploy + reload**

```bash
cp homeassistant/pyscript/climate_balance.py /Volumes/config/pyscript/
```

HA UI → Developer Tools → Services → `pyscript.reload`.

Watch logs for any errors.

- [ ] **Step 5: End-to-end verification**

1. Set `input_number.climate_balance_target_temp` to a value below current indoor temp. Confirm:
   - `sensor.climate_balance_mode` switches to a cooling mode
   - Discord notification fires (no longer prefixed `[DRY-RUN]`)
   - `climate.magiqtouch` actually changes mode in the HA UI
   - `switch.wholehousefanplug` actually turns on (you may hear it)
2. Restore target_temp to 70.
3. Manually flip `switch.wholehousefanplug` off via HA UI. Confirm:
   - Discord override notification fires
   - `sensor.climate_balance_status` reads `WHF in manual override`
   - The cooler is still automated (test by toggling target temp again — cooler responds, WHF stays off)
4. Manually set `input_datetime.whf_manual_until` to a time 30 seconds in the future. Wait. Confirm:
   - Within ~1 min, Discord resume notification fires
   - WHF actuator engages if needed

- [ ] **Step 6: Commit + open PR**

```bash
git add homeassistant/pyscript/climate_balance.py
git commit -m "feat(ha-climate-balance): live actuation + resume-after-snooze + danger warnings"
git push -u origin feat/ha-climate-balance-phase3
gh pr create --title "feat(ha-climate-balance): phase 3 — actuation + manual override" --body "$(cat <<'EOF'
## Summary
- Engine now actuates `climate.magiqtouch` and `switch.wholehousefanplug`
- Per-device manual override via `context.user_id` detection
- 60-min default snooze (configurable via `input_number.climate_balance_override_minutes`)
- Resume-after-snooze notifications
- Danger warnings when humidity/temp dangerous during override

Spec: `docs/superpowers/specs/2026-05-25-ha-climate-balance-automation-design.md`

## Test plan
- [ ] Pure-logic tests still pass (`pytest -v`)
- [ ] Setting target_temp below indoor causes cooler + WHF to actuate within 1s
- [ ] Manually flipping WHF triggers override notification + sensor status update
- [ ] Cooler remains automated while WHF is in override (and vice versa)
- [ ] Setting override datetime to past triggers resume notification within 1 min
- [ ] Master `input_boolean.climate_balance_enabled = off` halts all actuation

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Phase 4 — Predictive aggressive cooling (one PR)

End state: engine reads forecast from `weather.tejon`; rule #5 downshifts cooler fan speed when an outside-temp drop is imminent and indoor isn't yet hot.

### Task 14: Forecast integration + rule #5 (TDD on the rule, manual verification on the integration)

**Files:**
- Modify: `homeassistant/pyscript/decision_engine.py`
- Modify: `homeassistant/tests/test_decision_engine.py`
- Modify: `homeassistant/pyscript/climate_balance.py`

- [ ] **Step 1: Add rule #5 to the pure engine (extend Decision and evaluate)**

In `homeassistant/pyscript/decision_engine.py`:

Add to `ClimateState`:

```python
@dataclass(frozen=True)
class ClimateState:
    outside_temp_f: Optional[float]
    outside_rh_pct: Optional[float]
    indoor_temp_f: Optional[float]
    indoor_rh_pct: Optional[float]
    attic_temp_f: Optional[float]
    attic_rh_pct: Optional[float]
    forecast_min_temp_next_2h_f: Optional[float] = None  # NEW
    # ... rest unchanged
```

Modify the active-cooling branch of `evaluate()`:

```python
    # Rule 4: active cooling
    needs_cooling = s.indoor_temp_f > c.target_temp_f + TEMP_DEAD_BAND_F
    if needs_cooling:
        achievable = lookup_achievable_temp(s.outside_temp_f, s.outside_rh_pct)
        outside_dp = dew_point_f(s.outside_temp_f, s.outside_rh_pct)
        if outside_dp > c.max_dew_point_f:
            return _recirculate(
                f"Cooling needed but outside dew point {outside_dp:.0f}°F > limit "
                f"{c.max_dew_point_f:.0f}°F — recirculating"
            )
        if achievable is None or achievable > c.target_temp_f:
            return _recirculate(
                f"Cooling needed but chart says achievable "
                f"{achievable if achievable is not None else 'N/A'} > target "
                f"{c.target_temp_f:.0f}°F — recirculating"
            )
        quiet = _in_quiet_hours(now)
        headroom = c.target_temp_f - achievable
        speed = speed_for_headroom(headroom, quiet=quiet)

        # Rule 5: predictive downshift
        # If forecast shows outside dropping below indoor in next 2 hrs AND
        # indoor is at most 1°F above target, ease off the cooler.
        predictive_note = ""
        if (s.forecast_min_temp_next_2h_f is not None
                and s.forecast_min_temp_next_2h_f < s.indoor_temp_f
                and s.indoor_temp_f <= c.target_temp_f + 1):
            speed = max(speed - 2, 4)
            predictive_note = (f" (predictive downshift: forecast "
                              f"{s.forecast_min_temp_next_2h_f:.0f}°F in ≤2h)")

        return _cooler(
            quiet, speed,
            f"{'Quiet ' if quiet else ''}cooler + WHF — chart says we can hit "
            f"{achievable}°F (outside {s.outside_temp_f:.0f}°F @ "
            f"{s.outside_rh_pct:.0f}% RH, fan speed {speed}){predictive_note}"
        )
```

- [ ] **Step 2: Add tests for rule #5**

In `homeassistant/tests/test_decision_engine.py`, add:

```python
# ---------- Rule 5: predictive downshift ----------

def test_predictive_downshift_engages():
    # Indoor 71 (target + 1), forecast 60 in next 2h → downshift by 2 from natural speed
    # Outside 90 @ 20% → achievable 70, headroom 0 → natural 4, downshift to max(4-2, 4) = 4
    # Use a case with non-floor speed: target 75, achievable 70 → headroom 5 → natural 8 → downshift to 6
    d = evaluate(
        ClimateState(
            outside_temp_f=90.0, outside_rh_pct=20.0,
            indoor_temp_f=76.0, indoor_rh_pct=45.0,
            attic_temp_f=80.0, attic_rh_pct=45.0,
            forecast_min_temp_next_2h_f=60.0,
        ),
        _cfg(target_temp_f=75.0),
        _NOON,
    )
    assert d.mode == Mode.COOLER_FULL
    assert d.cooler_fan_speed == 6   # natural 8 minus 2


def test_predictive_no_downshift_when_indoor_hot():
    # Indoor 5°F above target — no downshift, we need full cooling
    d = evaluate(
        ClimateState(
            outside_temp_f=90.0, outside_rh_pct=20.0,
            indoor_temp_f=80.0, indoor_rh_pct=45.0,
            attic_temp_f=80.0, attic_rh_pct=45.0,
            forecast_min_temp_next_2h_f=60.0,
        ),
        _cfg(target_temp_f=75.0),
        _NOON,
    )
    assert d.cooler_fan_speed == 8


def test_no_forecast_no_downshift():
    d = evaluate(
        ClimateState(
            outside_temp_f=90.0, outside_rh_pct=20.0,
            indoor_temp_f=76.0, indoor_rh_pct=45.0,
            attic_temp_f=80.0, attic_rh_pct=45.0,
            forecast_min_temp_next_2h_f=None,
        ),
        _cfg(target_temp_f=75.0),
        _NOON,
    )
    assert d.cooler_fan_speed == 8
```

- [ ] **Step 3: Run all tests, verify all pass**

```bash
cd homeassistant && pytest -v
```

Expected: all tests pass (now ≈ 38 tests).

- [ ] **Step 4: Wire forecast into Pyscript wrapper**

In `homeassistant/pyscript/climate_balance.py`, update `_build_state`:

```python
_E_WEATHER = "weather.tejon"


def _forecast_min_next_2h():
    """Return min hourly forecast temp (°F) within next 2 hours, or None.

    weather.tejon exposes forecast via 'get_forecasts' service (HA 2024+).
    """
    try:
        result = service.call(
            "weather", "get_forecasts",
            entity_id=_E_WEATHER, type="hourly",
            return_response=True,
        )
        # result: {"weather.tejon": {"forecast": [{...}, {...}, ...]}}
        entries = result.get(_E_WEATHER, {}).get("forecast", [])
    except Exception as e:
        log.warning(f"climate_balance: forecast fetch failed: {e}")
        return None

    if not entries:
        return None
    # Take first 2 entries (assumes hourly cadence)
    next_2h = entries[:2]
    temps = [e.get("temperature") for e in next_2h if e.get("temperature") is not None]
    if not temps:
        return None
    # HA forecast temps are in the unit system of the weather entity.
    # weather.tejon (US) reports °F natively. If your entity reports °C, convert here.
    return float(min(temps))


def _build_state() -> ClimateState:
    return ClimateState(
        outside_temp_f=_read_float(_S_OUT_T),
        outside_rh_pct=_read_float(_S_OUT_RH),
        indoor_temp_f=_read_float(_S_AVG_T),
        indoor_rh_pct=_read_float(_S_AVG_RH),
        attic_temp_f=_read_float(_S_ATTIC_T),
        attic_rh_pct=_read_float(_S_ATTIC_RH),
        forecast_min_temp_next_2h_f=_forecast_min_next_2h(),
    )
```

- [ ] **Step 5: Deploy + reload**

```bash
cp homeassistant/pyscript/decision_engine.py /Volumes/config/pyscript/
cp homeassistant/pyscript/climate_balance.py /Volumes/config/pyscript/
```

HA UI → Developer Tools → Services → `pyscript.reload`.

- [ ] **Step 6: Verify forecast fetch works in HA logs**

Tail Pyscript log:

HA UI → Settings → System → Logs → filter for "pyscript".

Look for warnings about forecast fetch. If you see `forecast fetch failed`, the weather entity may not support `get_forecasts`; you'll need to switch to the deprecated `weather.forecast` attribute. Test the service manually:

HA UI → Developer Tools → Services → call `weather.get_forecasts` with:

```yaml
entity_id: weather.tejon
type: hourly
```

Click "Call service" — should return a `forecast` array.

- [ ] **Step 7: End-to-end verification of rule #5**

This rule only fires under specific conditions (cooling-needed AND forecast drop imminent AND indoor near target). You can force it by:

1. Set `input_number.climate_balance_target_temp` to ~1 °F below current indoor temp (e.g., if indoor is 73 °F, set target to 72)
2. If the actual forecast happens to show cooler temps within 2 hours, you'll see `(predictive downshift: forecast XX°F in ≤2h)` appended to `sensor.climate_balance_reason`
3. If forecast doesn't naturally show a drop, this rule is dormant — verify by checking that the reason text does NOT contain "predictive downshift"

Restore target_temp to 70.

- [ ] **Step 8: Commit + open PR**

```bash
git checkout -b feat/ha-climate-balance-phase4 main
git add homeassistant/pyscript/decision_engine.py homeassistant/tests/test_decision_engine.py homeassistant/pyscript/climate_balance.py
git commit -m "feat(ha-climate-balance): predictive downshift via weather.tejon forecast"
git push -u origin feat/ha-climate-balance-phase4
gh pr create --title "feat(ha-climate-balance): phase 4 — predictive cooling via forecast" --body "$(cat <<'EOF'
## Summary
- Engine reads `weather.tejon` hourly forecast
- Rule #5: if forecast shows outside dropping below indoor in ≤2h AND indoor at most 1°F above target, downshift cooler fan by 2 (floor at 4)
- Reason text includes `(predictive downshift: ...)` when active
- Aggressive variant per design: NEVER stops cooling when waiting for forecast drop; only eases off

Spec: `docs/superpowers/specs/2026-05-25-ha-climate-balance-automation-design.md`

## Test plan
- [ ] `cd homeassistant && pytest -v` passes (≈ 38 tests)
- [ ] `weather.get_forecasts` service call for `weather.tejon` returns hourly forecast
- [ ] No `forecast fetch failed` warnings in Pyscript logs
- [ ] When indoor near target and forecast shows imminent cool-down, reason includes "predictive downshift"

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Post-merge monitoring (no commit — runbook)

After Phase 4 lands, run the system for at least one week with these checkpoints:

- [ ] Day 1: Watch Discord — verify mode transitions match your judgment. Note any "wrong" decisions.
- [ ] Day 3: Check Pyscript logs for any tracebacks. Tune `input_number` helpers if hysteresis feels too tight/loose.
- [ ] Day 7: Validate attic humidity stayed below ~55 % and indoor temp stayed within ±2 °F of target during cooler-effective conditions.

Failures of these checks → open an issue + add a failing test → fix → PR. Do not silently tune thresholds — adjust the spec or helpers explicitly.

---

## Self-Review

**Spec coverage check:**

| Spec section | Implementing task(s) |
|---|---|
| Magnus dew point | Task 2 |
| Cooler chart (data + lookup) | Task 3 |
| Fan speed mapping | Task 4 |
| Helpers (input_boolean/number/datetime) | Task 5 |
| Derived sensors (DP, achievable) | Task 6 |
| Operating modes (OFF/WHF/COOLER/etc.) | Tasks 8-9 |
| Priority rules 1-6 | Task 9 |
| Hysteresis dead bands | Task 9 |
| Quiet hours (8 PM - 1 AM cap fan 4) | Task 9 |
| `_in_quiet_hours` | Task 9 |
| Pre-cool night purge (falls out of rule 3) | Task 9 (no separate code) |
| Mode/reason/status sensors | Task 10 |
| Discord transition notifications | Task 10 |
| Actuator service calls | Task 11 |
| Manual override detection via context.user_id | Task 12 |
| Per-device snooze timers | Task 12 |
| Resume-after-snooze notification | Task 13 |
| Danger condition warnings during snooze | Task 13 |
| Predictive downshift (rule 5) | Task 14 |
| File layout (pyscript/, packages/) | Task 1 + subsequent |
| README with sync instructions | Task 7 |

All spec requirements have a task. No gaps.

**Placeholder scan:** None found.

**Type consistency:** `evaluate()` signature is `(ClimateState, Config, datetime) -> Decision` across all tasks. `Mode` enum used consistently. `Decision` fields `cooler_hvac_mode` / `cooler_fan_speed` / `whf_on` / `reason` / `mode` used consistently in tasks 9-14.

One thing worth flagging: Task 14's forecast integration assumes `weather.tejon` returns Fahrenheit natively. If it returns Celsius, add a conversion in `_forecast_min_next_2h()` (commented note in the code points to this).
