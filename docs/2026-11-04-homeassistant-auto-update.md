# Home Assistant auto-update (OS, Core, add-ons)

**Date:** 2026-11-04
**PR:** #TBD (PR 5 of the auto-patching series —
`docs/superpowers/specs/2026-11-04-auto-patching-design.md` ring 5)

## What

`homeassistant/packages/auto_update.yaml` adds automation
`auto_update_nightly`: at 04:00 local, if `input_boolean.auto_update_enabled`
is on, the backup manager is idle and no update is in progress, it

1. notifies the Discord channel what it is about to do,
2. installs each pending **Core / add-on** update one at a time with
   `backup: true` (the Supervisor snapshots first and can roll back) — the
   allow-list is Core, Z-Wave JS, Advanced SSH & Web Terminal, Mosquitto,
   Xcel iTron MQTT, AppDaemon, Whisper; HACS entities are excluded,
3. installs a pending **OS** update last (it reboots the VM) only if the last
   automatic HA backup is younger than 26 h (they run daily ~11:04 UTC; the
   nightly vzdump of VM 250 at 01:00 is the second safety net).

Kill switch: Settings → Helpers → "Auto Update Enabled" (or
`input_boolean.turn_off`). At the time of writing Core 2026.8.0 → 2026.11.0,
OS 18.2 → 18.4 and Z-Wave JS 1.6.0 → 1.10.0 are pending; the first run
installs all three.

## Deploy (nothing applies automatically — HAOS keeps /config in the VM)

```bash
cat homeassistant/packages/auto_update.yaml | ssh tayvenbigelow@192.168.1.234 "cat > /tmp/auto_update.yaml"
ssh tayvenbigelow@192.168.1.234 "sudo mv /tmp/auto_update.yaml /config/packages/auto_update.yaml"
TOK=$(cat ~/.config/ha/llat); HA=http://192.168.1.234:8123
curl -s -X POST -H "Authorization: Bearer $TOK" -d '{}' "$HA/api/services/homeassistant/reload_all"
curl -s -H "Authorization: Bearer $TOK" "$HA/api/states/automation.auto_update_nightly" | head -c 200
```

Verify the morning after: `automation.auto_update_nightly` has a
`last_triggered`, the Discord message arrived, and the `update.*` entities
are `off`.

## Verification (local)

`/usr/bin/python3 homeassistant/tests/test_auto_update_package.py` (also
runs under pytest once PyYAML is in the venv): kill switch + 04:00 trigger,
exactly one `backup: true` install inside the repeat, the allow-list, the
OS gate, HACS exclusion, in-progress guard, Discord notification. `yamllint`
clean. The YAML itself is validated by HA on reload (watch the Discord
message / automation state).

## TrueNAS

Stays manual by design — `docs/runbooks/truenas-upgrade.md` (backup-gated,
boot-environment rollback). The "update available" signal comes from PR
#309's TrueNAS alert-list exporter once merged (`TrueNASAlert` with the
update class), until then from the TrueNAS UI.
