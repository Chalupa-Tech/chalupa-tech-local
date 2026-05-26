# Home Assistant — agent notes

Scope: this file augments the top-level `CLAUDE.md` whenever you're working in
`homeassistant/` or anywhere that touches HAOS. Read it before doing anything
against the live system.

## The system

- **HAOS VM 250** on `pve1`, IP `192.168.1.234`, managed by `pulumi/homeassistant.go`.
- **Climate-balance automation** is the only Pyscript-driven workflow in this
  repo today (spec/plan in `docs/superpowers/specs/` and `docs/superpowers/plans/`,
  dated 2026-05-25).
- HAOS keeps `/config/` *inside the VM*; nothing in this repo's working tree is
  a live representation of what HA is running. Sync changes via SSH (below).

## SSH

```bash
ssh tayvenbigelow@192.168.1.234 -i ~/.ssh/pulumi_proxmox_runner
```

- Root login is rejected. `tayvenbigelow` has `(ALL) NOPASSWD: ALL`, so prefix
  any write to `/config/` (owned by root) with `sudo`.
- The SSH & Web Terminal add-on **does not expose SFTP**, so `scp` and `rsync -e ssh`
  fail with "subsystem request failed". Transfer files via pipe + tee + sudo-mv:
  ```bash
  cat local_file.py | ssh tayvenbigelow@192.168.1.234 "cat > /tmp/x.py"
  ssh tayvenbigelow@192.168.1.234 "sudo mv /tmp/x.py /config/pyscript/x.py"
  ```
- Pyscript auto-reloads on file mtime change in `/config/pyscript/` — no
  manual reload is needed for `.py` updates. For YAML reloads (helpers, packages),
  use the REST API (below) to call the appropriate `*.reload` service.
- The HAOS supervisor's `ha` CLI is **not usable** from the SSH session:
  `SUPERVISOR_TOKEN` is not in the env even via sudo (the SSH add-on runs in
  an isolated container). Use the REST API for service calls and reloads.

## REST API

```bash
# Auth token. Two locations; whichever is set wins:
#   - $HOMEASSISTANT_TOKEN env var (exported from ~/.zshrc — only available to
#     interactive shells; move to ~/.zshenv if you want agent tool calls to see it)
#   - ~/.config/ha/llat (chmod 600 file, always readable)
TOK="${HOMEASSISTANT_TOKEN:-$(cat ~/.config/ha/llat)}"
HA=http://192.168.1.234:8123

# Read a single entity state
curl -s -H "Authorization: Bearer $TOK" "$HA/api/states/sensor.climate_balance_mode"

# Tail the live error log (this is the ONLY way to see current HA logs —
# /config/home-assistant.log is rotated; the active log lives inside the
# supervisor container, not on disk)
curl -s -H "Authorization: Bearer $TOK" "$HA/api/error_log" | tail -50

# Reload Pyscript (rarely needed; auto-reload handles .py file changes)
curl -s -X POST -H "Authorization: Bearer $TOK" -d '{}' "$HA/api/services/pyscript/reload"

# Set an input_number helper
curl -s -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"entity_id":"input_number.climate_balance_target_temp","value":72}' \
  "$HA/api/services/input_number/set_value"
```

The token expires 2095-09-13; treat as semi-permanent. If revoked, the user
creates a new one at Profile → Security → Long-Lived Access Tokens.

## Notifications (Discord)

The Discord integration on this instance exposes its notify service as
`notify.homeassistant_tejon_frame` (auto-named after the HA instance), **not**
`notify.discord`. The original `notify.discord(...)` attribute call hit no
service and silently dropped messages — verified by inspection.

```bash
curl -s -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"message":"hello","target":["1508674689256652850"]}' \
  "$HA/api/services/notify/homeassistant_tejon_frame"
```

Channel ID `1508674689256652850` is the climate-balance channel.

## Recorder DB (SQLite, read-only via SSH)

Modern HA schema splits entity IDs into `states_meta` (one row per entity)
and state values into `states` (keyed on `metadata_id`). Useful for replay /
backtest queries — see `scripts/backtest.py` for a worked example.

```bash
ssh tayvenbigelow@192.168.1.234 "sudo sqlite3 -readonly /config/home-assistant_v2.db \
  \"SELECT m.entity_id, datetime(s.last_updated_ts,'unixepoch','localtime'), s.state \
   FROM states s JOIN states_meta m ON s.metadata_id=m.metadata_id \
   WHERE m.entity_id='sensor.climate_balance_mode' \
   ORDER BY s.last_updated_ts DESC LIMIT 10;\""
```

`last_updated_ts` is epoch seconds. The DB is large (~450 MB) — query in place
rather than copying locally.

## Pyscript layout

(HACS-installed add-on at `/config/custom_components/pyscript/`.)

- `/config/pyscript/*.py` — **trigger scripts**: files decorated with
  `@state_trigger` / `@time_trigger` / `@service`. Pyscript loads each as a
  separate global context.
- `/config/pyscript/modules/*.py` — **importable libraries**. Trigger scripts
  can `from foo import bar` only if `foo.py` lives here; top-level `pyscript/`
  is NOT on `sys.path` for imports.
- `/config/packages/*.yaml` — packaged YAML (input_boolean, input_number,
  input_datetime helpers). Requires:
  ```yaml
  # configuration.yaml
  homeassistant:
    packages: !include_dir_named packages
  ```

## Pyscript runtime quirks

Verified in production during Phases 1-3. Each one has a deeper memory note
under `feedback_pyscript_*.md`.

- **No lambda closures over enclosing-function args.**
  `min(items, key=lambda k: abs(k - target))` raises `NameError: name 'target'
  is not defined` at runtime. Use a named helper that takes `target` as a
  positional arg.
- **No `@property` descriptor protocol.** Accessing a `@property` attribute
  returns the bare `EvalFunc` wrapper, then `if not s.prop:` raises
  `TypeError: 'EvalFunc' object is not callable`. Use a module-level function
  that takes the instance: `def is_ready(s): ...`.
- **No generator expressions.** `all(v is not None for v in (...))` raises
  `NotImplementedError: not implemented ast ast_generatorexp`. Use explicit
  `and` chains or list comprehensions (the latter DO work).
- **Use `service.call(...)` for dynamic service names.** Attribute-style
  `notify.discord(...)` only resolves at parse time; service.call lets the
  name be a string variable. This also dodges the implicit-import problem
  with custom service names like `homeassistant_tejon_frame`.

Plain `pytest` will not catch any of these — they only surface inside the
Pyscript interpreter. AST parse is the only static check that works locally.

## Deploy + verify loop

```bash
# 1. Edit code locally; run unit tests
cd homeassistant && source .venv/bin/activate && pytest -v

# 2. Deploy each touched file (cat-pipe-tee + sudo mv — SFTP is blocked)
for f in pyscript/climate_balance.py pyscript/modules/*.py packages/*.yaml; do
  name=$(basename "$f")
  cat "$f" | ssh tayvenbigelow@192.168.1.234 "cat > /tmp/$name"
done
ssh tayvenbigelow@192.168.1.234 "
  sudo mv /tmp/climate_balance.py /config/pyscript/
  sudo mv /tmp/{dew_point,cooler_chart,fan_speed,decision_engine}.py /config/pyscript/modules/
  sudo mv /tmp/climate_balance.yaml /config/packages/
"

# 3. Verify via API (no user round-trip needed)
TOK="${HOMEASSISTANT_TOKEN:-$(cat ~/.config/ha/llat)}"
curl -s -H "Authorization: Bearer $TOK" http://192.168.1.234:8123/api/error_log \
  | grep -i climate_balance | tail -10
curl -s -H "Authorization: Bearer $TOK" \
  http://192.168.1.234:8123/api/states/sensor.climate_balance_mode \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['state'])"
```

If `/api/error_log` is clean and `sensor.climate_balance_mode` updated, the
deploy is healthy.

## What lives in this directory

| Path | Purpose | Synced to HAOS |
|---|---|---|
| `pyscript/climate_balance.py` | Trigger script (state_triggers, actuators, notifier) | yes → `/config/pyscript/` |
| `pyscript/modules/dew_point.py` | Magnus formula | yes → `/config/pyscript/modules/` |
| `pyscript/modules/cooler_chart.py` | Phillips chart + nearest-cell lookup | yes → `/config/pyscript/modules/` |
| `pyscript/modules/fan_speed.py` | Headroom → fan speed mapping | yes → `/config/pyscript/modules/` |
| `pyscript/modules/decision_engine.py` | All 6 rules + asymmetric hysteresis | yes → `/config/pyscript/modules/` |
| `packages/climate_balance.yaml` | HA helpers | yes → `/config/packages/` |
| `scripts/backtest.py` | Historical replay tool (matplotlib chart) | **no** — local dev only |
| `tests/` | pytest unit tests for pure-logic modules | **no** — never copy to HAOS |
| `pyproject.toml` | pytest config | **no** |
