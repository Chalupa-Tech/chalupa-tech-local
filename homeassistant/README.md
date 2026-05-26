# Home Assistant Climate Balance

Pyscript-based automation that orchestrates the MagiqTouch swamp cooler and whole
house fan to maintain target indoor temperature/humidity using the Phillips
evaporative-cooling chart.

Spec: `docs/superpowers/specs/2026-05-25-ha-climate-balance-automation-design.md`
Plan: `docs/superpowers/plans/2026-05-25-ha-climate-balance-automation-plan.md`

## Layout

Pyscript treats top-level `.py` files in `/config/pyscript/` as **trigger
scripts** (containing `@state_trigger` / `@time_trigger`). Importable libraries
must live in `/config/pyscript/modules/`. Our pure-logic modules go there.

| Path | Purpose | Synced to HAOS? |
|---|---|---|
| `pyscript/modules/dew_point.py` | Magnus formula | yes → `/config/pyscript/modules/` |
| `pyscript/modules/cooler_chart.py` | Chart data + nearest-cell lookup | yes → `/config/pyscript/modules/` |
| `pyscript/modules/fan_speed.py` | Headroom → fan speed mapping | yes → `/config/pyscript/modules/` |
| `pyscript/climate_balance.py` | Pyscript entry (state triggers; Phase 2+ adds engine + actuators) | yes → `/config/pyscript/` |
| `packages/climate_balance.yaml` | HA helpers (input_boolean / input_number / input_datetime) | yes → `/config/packages/` |
| `tests/` | pytest unit tests for pure logic modules | **no** — never copy to HAOS |
| `pyproject.toml` | pytest config | **no** |

## Local test

```bash
cd homeassistant
# Use python 3.13+ (matches HAOS Pyscript runtime). 3.14 works.
# macOS: brew install python@3.13
python3.13 -m venv .venv 2>/dev/null || python3.14 -m venv .venv
source .venv/bin/activate
pip install pytest
pytest -v
```

All pure-logic modules (`dew_point`, `cooler_chart`, `fan_speed`) are testable
without HA. After Phase 2, `decision_engine` joins the test suite. The Pyscript
wrapper file (`climate_balance.py`) is not unit-tested — its logic is thin
glue, and integration is verified by deploying to HA and watching the
`sensor.climate_balance_*` entities.

## Deploy to HAOS

### Prerequisites

- Pyscript add-on installed via HACS, configured with `allow_all_imports: true`
  and `hass_is_global: true`.
- `configuration.yaml` includes:
  ```yaml
  homeassistant:
    packages: !include_dir_named packages
  ```
- A way to push files into HAOS `/config/`. Two options:
  - **Samba share** (default): enable the Samba add-on in HA, mount
    `\\homeassistant.local\config` on your dev machine.
  - **SSH** (preferred once set up): the SSH & Web Terminal add-on with a
    public key authorized — *being set up out-of-band; this README will be
    updated when access lands.*

### Sync (Samba example, macOS)

```bash
mkdir -p /Volumes/config/pyscript/modules /Volumes/config/packages
cp pyscript/climate_balance.py /Volumes/config/pyscript/
cp pyscript/modules/*.py /Volumes/config/pyscript/modules/
cp packages/*.yaml /Volumes/config/packages/
```

### Reload

- YAML config: HA UI → Developer Tools → YAML → "All YAML configuration"
- Pyscript: HA UI → Developer Tools → Services → `pyscript.reload`

### Verify (Phase 1)

In HA UI → Settings → Devices & Services → Helpers, search "climate_balance".
You should see 2 input_booleans + 6 input_numbers + 2 input_datetimes.

In HA UI → Developer Tools → States, search:

- `sensor.outside_dew_point` — populated with numeric °F value
- `sensor.indoor_dew_point` — populated with numeric °F value
- `sensor.evap_cooler_achievable_temp` — populated with chart value matching
  current outside conditions

If any read `unavailable`, check the upstream sensors
(`sensor.stormin_norman_*`, `sensor.average_*`) are populated and the
Pyscript logs (Settings → System → Logs → filter `pyscript`) for tracebacks.

## Master kill

- `input_boolean.climate_balance_enabled` → off disables the whole automation
  (no-op until Phase 3 wires actuation).
- `input_boolean.climate_balance_vacation` → on does the same and (in Phase 3)
  also clears any active per-device manual overrides.
