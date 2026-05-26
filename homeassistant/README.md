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
