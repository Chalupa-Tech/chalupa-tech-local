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
# Use python3.13 (matches HAOS Pyscript runtime) or any 3.13+ — 3.14 works too.
# On macOS install with: brew install python@3.13
python3.13 -m venv .venv 2>/dev/null || python3.14 -m venv .venv
source .venv/bin/activate
pip install pytest
pytest
```

## Deploy to HAOS

Manual sync via Samba — see Prerequisites in
`docs/superpowers/plans/2026-05-25-ha-climate-balance-automation-plan.md`.
Later tasks will fill in step-by-step instructions.
