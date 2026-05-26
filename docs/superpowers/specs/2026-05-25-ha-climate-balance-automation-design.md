# Home Assistant Climate Balance Automation — Design

**Status:** Draft
**Date:** 2026-05-25
**Author:** Tayven Bigelow (via Claude brainstorming session)
**Implementation surface:** Pyscript inside Home Assistant OS (VM 250, `homeassistant`)

---

## Problem

The house uses a **MagiqTouch swamp cooler** (`climate.magiqtouch`) and a **whole house fan**
(`switch.wholehousefanplug`) to manage temperature in a hot dry climate. Today these are operated
manually. The goal is an automation that decides when to run each device based on indoor/outdoor
temperature, humidity, dew point, the evaporative cooling efficiency chart, and time of day —
while gracefully respecting manual overrides.

## Goals

- Maintain indoor temperature near a configurable target (default 70 °F) using the most efficient
  combination of swamp cooler and whole house fan available at any given moment.
- Use the evaporative cooler chart to determine when the cooler can actually achieve the target.
- Keep attic relative humidity below 50 % to prevent mold/condensation risk.
- Keep indoor relative humidity below 55 % for comfort.
- Use cheap free cooling (whole house fan only) whenever outside is sufficiently cooler than inside.
- Run quieter at night (8 PM – 1 AM).
- Honor manual overrides per device with a configurable snooze (default 60 min).
- Notify Discord on every mode transition with a human-readable reason.

## Non-goals

- HVAC integration with central AC (the house doesn't have one).
- Window/door open detection (no sensors installed).
- PM2.5 / AQI suppression (no sensor today; documented as future work).
- Cooler water-pad maintenance tracking (deferred).
- HADashboard / custom Lovelace UI work (sensors expose state; the user builds their own card).

## Inputs

### Existing entities (do not create)

| Entity | Purpose |
|---|---|
| `climate.magiqtouch` | Swamp cooler; modes Cool / Fan Only / Off; presets and fan speeds 0–10 |
| `switch.wholehousefanplug` | Whole house fan (on/off) |
| `sensor.average_temperature` | House-wide average indoor temperature (°F) |
| `sensor.average_humidity` | House-wide average indoor relative humidity (%) |
| `sensor.attic_sensor_air_temperature` | Attic temperature (°F) |
| `sensor.attic_sensor_humidity` | Attic relative humidity (%) |
| `sensor.stormin_norman_temperature` | Outside temperature (°F) |
| `sensor.stormin_norman_humidity` | Outside relative humidity (%) |
| `weather.tejon` | Forecast source for predictive cooling logic |
| `notify.discord` | Discord notify service; channel target `1508674689256652850` |

### New helpers (created in `/config/packages/climate_balance.yaml`)

```yaml
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
  climate_balance_whf_target:
    name: "Whole House Fan Target Temperature"
    min: 60
    max: 75
    step: 1
    initial: 68
    unit_of_measurement: "°F"
  climate_balance_max_indoor_rh:
    name: "Max Indoor Relative Humidity"
    min: 40
    max: 70
    step: 1
    initial: 55
    unit_of_measurement: "%"
  climate_balance_max_attic_rh:
    name: "Max Attic Relative Humidity"
    min: 40
    max: 70
    step: 1
    initial: 50
    unit_of_measurement: "%"
  climate_balance_max_dew_point:
    name: "Max Acceptable Dew Point"
    min: 50
    max: 70
    step: 1
    initial: 60
    unit_of_measurement: "°F"
  climate_balance_override_minutes:
    name: "Manual Override Duration"
    min: 15
    max: 240
    step: 15
    initial: 60
    unit_of_measurement: "min"

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

## Derived sensors

All computed by Pyscript and exposed as `sensor.*` entities via `state.set()`:

| Sensor | Computation |
|---|---|
| `sensor.outside_dew_point` | Magnus formula on outside temp + RH |
| `sensor.indoor_dew_point` | Magnus formula on `sensor.average_temperature` + `sensor.average_humidity` |
| `sensor.evap_cooler_achievable_temp` | Chart lookup; `unavailable` when conditions fall in chart's empty (ineffective) zone |
| `sensor.climate_balance_mode` | Current operating mode: `OFF` / `WHF_ONLY` / `COOLER_FULL` / `COOLER_QUIET` / `DEHUMIDIFY` / `RECIRCULATE` |
| `sensor.climate_balance_reason` | Free-text explanation of why we're in the current mode |
| `sensor.climate_balance_status` | `Auto` / `Cooler manual override (43 min left)` / `WHF manual override (12 min left)` / `Disabled` / `Vacation` |

### Magnus formula (dew point)

```python
import math

def dew_point_f(temp_f, rh_pct):
    temp_c = (temp_f - 32) * 5 / 9
    a, b = 17.625, 243.04
    alpha = math.log(rh_pct / 100) + (a * temp_c) / (b + temp_c)
    dp_c = (b * alpha) / (a - alpha)
    return dp_c * 9 / 5 + 32
```

## Evaporative cooler chart

The chart from Ed Phillips / Arizona Almanac gives delivered air temperature for given outside
temperature and relative humidity. Stored as a 2D dict-of-dicts in `cooler_chart.py`.
Empty cells (high humidity + low temp where evap cooling is ineffective) are omitted; lookup
returns `None` for those.

```python
# cooler_chart.py
COOLER_CHART = {
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

def lookup_achievable_temp(outside_temp_f, outside_rh_pct):
    """Return delivered air temp (°F) at given outside conditions.
    Uses nearest-cell rounding (chart granularity is 5° / 5%).
    Returns None when conditions fall in the chart's empty (ineffective) zone."""
    if outside_temp_f < 75:
        return outside_temp_f  # Cooler can't improve sub-75 air; pass-through
    temp_key = min(COOLER_CHART.keys(), key=lambda k: abs(k - outside_temp_f))
    row = COOLER_CHART[temp_key]
    # Find nearest RH within available columns for this row
    rh_key = min(row.keys(), key=lambda k: abs(k - outside_rh_pct))
    return row.get(rh_key)
```

**Why nearest-cell rather than bilinear interpolation:** The chart is already a rough guideline.
A 1–2 °F discrepancy from interpolation is meaningless when the chart values themselves are
±2 °F estimates. Nearest-cell keeps the lookup readable and trivially debuggable. Can swap to
bilinear later if needed (~10 LoC change).

## Operating modes

| Mode | `climate.magiqtouch` | `switch.wholehousefanplug` | Description |
|---|---|---|---|
| `OFF` | Off | Off | Nothing to do |
| `WHF_ONLY` | Off | On | Free cooling — outside cooler than inside |
| `COOLER_FULL` | Cool, fan speed per chart headroom (10/8/6/4) | On | Active evaporative cooling |
| `COOLER_QUIET` | Cool, fan ≤ 4 | On | Same as COOLER_FULL but quiet hours (8 PM – 1 AM) |
| `DEHUMIDIFY` | Fan Only, fan speed 2 | On | Pull dry outside air through the house to lower indoor RH |
| `RECIRCULATE` | Off | Off | Indoor uncomfortable but outside air would make it worse; do nothing |

### Fan speed mapping (used for `COOLER_FULL`)

| Headroom (target − chart_achievable) | Fan speed |
|---|---|
| ≥ 6 °F | 10 |
| 4–5 °F | 8 |
| 2–3 °F | 6 |
| 0–1 °F | 4 |
| < 0 (cooler can't reach target) | 10 (best effort) |

Quiet hours (8 PM – 1 AM, local time) cap the resulting speed at **4** and flip the mode label
to `COOLER_QUIET`.

## Decision priority (first match wins)

Evaluated on every input state change and on a 5-minute heartbeat:

1. **Master kill** — `climate_balance_enabled = off` OR `climate_balance_vacation = on` → `OFF`
2. **Dehumidify** — `attic_RH > max_attic_rh + 5` OR `indoor_RH > max_indoor_rh + 5`
   - If `outside_dew_point < indoor_dew_point` → `DEHUMIDIFY`
   - Else → `RECIRCULATE` (bringing in outside air would worsen things)
3. **Free cooling opportunity** — `outside_temp < indoor_temp − 2` AND
   `indoor_temp > whf_target` (default 68 °F) → `WHF_ONLY`.
   Fires whenever outside air can pull indoor down toward the WHF target, even when
   indoor is already below the cooling `target_temp`. This is the "use free cooling whenever
   you can get it" branch. Exits when `indoor_temp ≤ whf_target` or `outside_temp ≥ indoor_temp`.
4. **Active cooling needed** — `indoor_temp > target_temp + 2` (hysteresis dead band) AND
   rule #3 didn't already match:
   - If chart `achievable_temp ≤ target_temp` AND `outside_dew_point ≤ max_dew_point`:
     - Time 8 PM – 1 AM → `COOLER_QUIET`
     - Else → `COOLER_FULL`
   - Else → `RECIRCULATE` (outside dew point too high, or chart says cooler can't reach target)
5. **Predictive aggressive** — if `weather.tejon` forecast shows outside dropping below indoor in
   ≤ 2 hours AND `indoor_temp ≤ target_temp + 1`:
   - If currently in `COOLER_FULL` → downshift fan speed by 2 (keep running, don't stop)
   - Never let indoor climb to `target + 2` while waiting; rule #4 will re-engage
6. **Idle** — everything in range → `OFF`

### Hysteresis & rate limiting

- **2 °F dead band** on all temperature thresholds (enter at one value, exit at value ± 2).
- **5 % dead band** on humidity thresholds.
- **10-minute minimum runtime** per mode before allowing a mode transition.
- Heartbeat re-evaluates every 5 minutes but does not force transitions; it only updates
  derived sensors and triggers transitions when the cooldown has elapsed.

### Pre-cool night purge (an instantiation of rule #3)

`WHF_ONLY` naturally runs at night because the cool-air-outside condition is usually true after
sunset. Rule #3 exits at `indoor_temp ≤ whf_target` (68 °F) or when outside warms back up at
sunrise. No separate rule needed.

## Manual override behavior

### Detection

Every state change on `climate.magiqtouch` or `switch.wholehousefanplug` is inspected via
Pyscript's `context.user_id`. If the context user_id is **not** the automation's service account
(or `None`, i.e. internal), the change is treated as **manual**.

### Per-device snooze

- Manual change to cooler → set `input_datetime.cooler_manual_until = now + override_minutes`
- Manual change to WHF → set `input_datetime.whf_manual_until = now + override_minutes`
- When a snooze is active, the decision engine still computes the desired mode but
  **skips actuation on that device only**. The other device is still automated.

### Master kill

`input_boolean.climate_balance_enabled = off` is a **permanent** disable — no timer, no auto-resume.
Setting `climate_balance_vacation = on` has the same effect plus clears any active per-device snoozes
(returning to a clean state on vacation).

### Resume behavior

When a snooze expires:
1. Recompute desired mode for that device.
2. If current device state already matches desired → silent resume.
3. If different → Discord notification *"▶️ Resuming automation on <device> — switching to <mode>"*
   then transition normally.

### Danger condition warning

If a per-device snooze is active AND the decision engine determines danger conditions —
specifically `attic_RH > max + 10` or `indoor_temp > target + 5` — send a Discord warning
**without** overriding the snooze:

> ⚠️ Attic humidity at 62 % but swamp cooler is in manual override (38 min left) — consider intervening

Warning is rate-limited to one per condition per snooze window (no spam).

## Discord notifications

All notifications go through a single `send_notification(emoji, mode, reason)` helper which
calls:

```python
notify.discord(message=f"{emoji} {body}", target=["1508674689256652850"])
```

### Notification catalogue

| Event | Example |
|---|---|
| Mode transition: WHF only | 🌬️ Whole House Fan only — outside 65 °F, inside 74 °F |
| Mode transition: Cooler full | ❄️ Cooler + WHF — chart says we can hit 69 °F (outside 92 °F @ 22 % RH, fan speed 8) |
| Mode transition: Cooler quiet | 🌙 Quiet Cooler mode — fan speed 4, bedtime hours |
| Mode transition: Dehumidify | 💧 Cooler fan-only + WHF — attic humidity at 53 % |
| Mode transition: Recirculate | 🛑 Recirculate only — indoor 76 °F but outside dew point 64 °F (too humid to help) |
| Mode transition: Off | ✅ Climate balance idle — temperatures and humidity in range |
| Manual override start | 📱 Manual override detected on swamp cooler — pausing cooler automation for 60 min |
| Resume after snooze | ▶️ Resuming swamp cooler automation — switching to COOLER_FULL (indoor 76 °F, target 70 °F) |
| Master disable | 🛑 Climate balance disabled (master toggle) |
| Vacation | ✈️ Vacation mode — climate balance suspended |
| Danger during override | ⚠️ Attic humidity at 62 % but swamp cooler is in manual override (38 min left) — consider intervening |

## File layout

```
/config/
├── pyscript/
│   ├── climate_balance.py      # Decision engine, state triggers, actuators, notifier
│   └── cooler_chart.py         # Chart data + lookup_achievable_temp()
└── packages/
    └── climate_balance.yaml    # All input_booleans, input_numbers, input_datetimes
```

`configuration.yaml` must include `homeassistant: packages: !include_dir_named packages` if not
already present, and `pyscript:` to enable the Pyscript add-on.

## Implementation phases

Each phase is independently mergeable and testable.

**Phase 1 — Observability scaffolding.** Add `packages/climate_balance.yaml` with all helpers.
Add `cooler_chart.py` and Pyscript-computed derived sensors (`outside_dew_point`,
`indoor_dew_point`, `evap_cooler_achievable_temp`). No decision logic, no actuation. Verify
sensor values look right for current weather conditions.

**Phase 2 — Decision engine in dry-run mode.** Add decision engine. It logs to
`sensor.climate_balance_mode` / `sensor.climate_balance_reason` and sends Discord notifications,
but does **not** call `climate.set_*` or `switch.turn_*`. Watch it for 1–2 days; verify the
mode transitions match what you'd manually decide.

**Phase 3 — Enable actuation + manual override.** Flip a flag at the top of the engine to enable
device actuation. Add `context.user_id`-based manual override detection. Per-device snooze timers
become functional. `sensor.climate_balance_status` reflects override state.

**Phase 4 — Predictive aggressive cooling.** Add forecast integration via `weather.tejon`.
Implement rule #4 (downshift fan speed when forecast shows imminent outside drop).

## Edge cases the design handles

- **Outside temp < 75 °F.** Chart lookup returns the outside temp directly (passthrough); cooler
  in `Cool` mode at sub-75 °F input is effectively just fan-only — `WHF_ONLY` will win the
  decision before this matters.
- **Outside humidity > 80 %.** Chart lookup uses the nearest row, but real evap performance
  collapses; the `max_dew_point` guard in rule #4 catches this case and falls through to
  `RECIRCULATE`.
- **Stale sensor data.** Each derived-sensor function returns `unavailable` if any input is
  `unknown` / `unavailable`. The decision engine treats `unavailable` mode as no-op (don't
  change current state, don't notify).
- **Pyscript reload.** On reload, the engine immediately re-evaluates and reports current mode
  without spurious transition notifications (compares to current device state, not to
  "previous in-memory mode").
- **Time zone for quiet hours.** Uses HA's `state.get("sun.sun")` and local time. Quiet hours
  are 8 PM – 1 AM **local**.

## What the design explicitly does NOT do

- **No interpolation between chart cells.** Nearest-cell only; revisit if needed.
- **No "lock forever on manual" mode.** Snooze always expires.
- **No automation override of manual changes within the snooze window** — only warnings.
- **No notification batching / digest.** Every transition gets its own message. If this becomes
  noisy in practice, add a 60-second debounce in Phase 3+.
- **No integration with calendar / occupancy.** Defer until requested.
- **No water-pad / cooler maintenance reminder.** Defer.

## Open questions / future work

- **PM2.5 / AQI suppression** — when a sensor is added, slot in as rule #2 (before dehumidify).
  Logic: outside AQI > unhealthy threshold → force `RECIRCULATE` regardless of other conditions.
  The notify message would be ⚠️ Wildfire/AQI override — outdoor air unhealthy.
- **Pulumi-managed HA config?** HAOS stores its config inside the VM. Not currently in this
  repo. If we ever externalize HA config (e.g., bind-mount `/config` from TrueNAS NFS), this
  spec's `packages/` and `pyscript/` directories would land in a new repo path. For now they
  live only inside the HAOS VM.
- **Bilinear chart interpolation** — if nearest-cell proves too coarse near boundaries.

## References

- Evaporative cooling chart source: Ed Phillips, Arizona Almanac
- Pyscript docs: https://hacs-pyscript.readthedocs.io/
- HA Discord notify: https://www.home-assistant.io/integrations/discord/
- Magnus formula for dew point: standard meteorological approximation
