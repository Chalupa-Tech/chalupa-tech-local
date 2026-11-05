"""Structural checks on homeassistant/packages/auto_update.yaml.

Runs under pytest (PyYAML needed: `pip install pyyaml` in the venv) or
standalone: `/usr/bin/python3 homeassistant/tests/test_auto_update_package.py`.
"""
from pathlib import Path

try:
    import pytest
    yaml = pytest.importorskip("yaml")
except ImportError:  # standalone
    import yaml

PACKAGE = Path(__file__).resolve().parent.parent / "packages" / "auto_update.yaml"

# Supervisor-backed entities: `update.install` accepts backup: true.
SUPERVISOR_ENTITIES = {
    "update.home_assistant_core_update",
    "update.z_wave_js_update",
    "update.advanced_ssh_web_terminal_update",
    "update.mosquitto_broker_update",
    "update.xcel_itron_mqtt_update",
    "update.appdaemon_update",
    "update.whisper_update",
}
# OS updates have no per-update backup; gated on a fresh automatic backup instead.
OS_ENTITY = "update.home_assistant_operating_system_update"
# HACS frontend/integration entities: not Supervisor-backed, must never be in the lists.
HACS_ENTITIES = {"update.uptime_card_update", "update.traeger_update", "update.battery_state_card_entity_row_update"}


def _load():
    with PACKAGE.open() as f:
        return yaml.safe_load(f)


def _automation(pkg):
    autos = {a["id"]: a for a in pkg["automation"]}
    assert "auto_update_nightly" in autos, "automation id auto_update_nightly missing"
    return autos["auto_update_nightly"]


def _flatten(seq):
    """Yield every dict in a nested action list (choose/if/sequence/repeat)."""
    for item in seq or []:
        yield item
        for key in ("sequence", "then", "else", "default"):
            if isinstance(item.get(key), list):
                yield from _flatten(item[key])
        for opt in item.get("choose", []) or []:
            yield from _flatten(opt.get("sequence"))
        if isinstance(item.get("repeat"), dict):
            yield from _flatten(item["repeat"].get("sequence"))


def _install_calls(auto):
    return [a for a in _flatten(auto["action"]) if a.get("action") == "update.install" or a.get("service") == "update.install"]


def test_kill_switch_and_trigger():
    pkg = _load()
    assert pkg["input_boolean"]["auto_update_enabled"]["initial"] in (True, "on")
    auto = _automation(pkg)
    triggers = auto.get("trigger") or auto.get("triggers")
    assert any(t.get("at") == "04:00:00" for t in triggers), "must trigger at 04:00:00"
    conds = auto.get("condition") or auto.get("conditions")
    assert any(c.get("entity_id") == "input_boolean.auto_update_enabled" and c.get("state") == "on" for c in conds), "kill switch condition missing"


def _allow_list(auto, var):
    """Entity ids inside the expand(...) of the `supervisor_pending` variable."""
    import re
    for a in _flatten(auto["action"]):
        tpl = (a.get("variables") or {}).get(var)
        if tpl:
            return set(re.findall(r"update\.[a-z0-9_]+", tpl))
    raise AssertionError(f"variable {var} not found")


def test_supervisor_group_installs_with_backup():
    auto = _automation(_load())
    calls = _install_calls(auto)
    with_backup = [c for c in calls if (c.get("data") or {}).get("backup") is True]
    assert len(with_backup) == 1, "exactly one backup:true install call (inside the repeat)"
    assert (with_backup[0].get("target") or {}).get("entity_id") == "{{ repeat.item }}"
    assert _allow_list(auto, "supervisor_pending") == SUPERVISOR_ENTITIES
    # the repeat iterates the pending subset of that allow-list only
    text = yaml.safe_dump(auto)
    assert "for_each: '{{ supervisor_pending }}'" in text or 'for_each: "{{ supervisor_pending }}"' in text or "for_each: '{{ supervisor_pending }}'" in text.replace('"', "'")


def test_os_group_has_no_backup_flag_and_is_gated_on_fresh_backup():
    auto = _automation(_load())
    calls = _install_calls(auto)
    os_calls = [c for c in calls if OS_ENTITY in ((c.get("target") or {}).get("entity_id", []))]
    assert len(os_calls) == 1, "exactly one OS install call"
    assert not (os_calls[0].get("data") or {}).get("backup"), "OS update must not pass backup:true (unsupported)"
    text = PACKAGE.read_text()
    assert "sensor.backup_last_successful_automatic_backup" in text, "OS update must be gated on the last automatic backup age"
    assert "26" in text or "93600" in text, "backup age gate (26 h) missing"


def test_hacs_entities_excluded():
    text = PACKAGE.read_text()
    for e in HACS_ENTITIES:
        assert e not in text, f"{e} must not be auto-updated"


def test_in_progress_guard_and_notification():
    auto = _automation(_load())
    text = yaml.safe_dump(auto)
    assert "in_progress" in text, "must skip while an update is already in progress"
    assert "notify.homeassistant_tejon_frame" in text, "must notify the Discord notify service"


def test_mode_single():
    auto = _automation(_load())
    assert auto.get("mode", "single") == "single"


if __name__ == "__main__":
    import sys
    failed = 0
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn(); print(f"ok {name}")
            except AssertionError as e:
                failed += 1; print(f"FAIL: {name}: {e}")
            except Exception as e:  # noqa: BLE001
                failed += 1; print(f"FAIL: {name}: {type(e).__name__}: {e}")
    print("PASS" if failed == 0 else f"{failed} failed"); sys.exit(1 if failed else 0)
