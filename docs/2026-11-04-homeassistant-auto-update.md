# Home Assistant auto-update (OS, Core, add-ons)

**Date:** 2026-11-04
**PR:** #TBD (PR 5 of the auto-patching series —
`docs/superpowers/specs/2026-11-04-auto-patching-design.md` ring 5)

## What

`homeassistant/packages/auto_update.yaml` adds automation
`auto_update_nightly`: at **05:30 local** (after HA's own automatic backup,
~11:04 UTC = 04:04 MST / 05:04 MDT, so the pre-update backups never collide
with it), if `input_boolean.auto_update_enabled` is on, the backup manager
is idle and no update is in progress, it

1. posts to Discord what it is about to do,
2. installs pending **add-on** updates one at a time with `backup: true`
   (the Supervisor snapshots first and can roll back) in an explicit order —
   Z-Wave JS, Advanced SSH & Web Terminal, Mosquitto, Xcel iTron MQTT,
   AppDaemon, Whisper — reporting any install that is still pending after
   its 20-minute wait as FAILED,
3. installs a pending **Core** update **last**: a Core update restarts Home
   Assistant, which ends the run (that is why it cannot go first),
4. on a night with **no** Core update pending, installs a pending **OS**
   update (it reboots the VM) if the last automatic backup is younger than
   26 h (the nightly vzdump of VM 250 at 01:00 is the second safety net),
5. posts "finished" when neither Core nor OS ended the run.

So a backlog converges over nights, not in one: today Core 2026.8.0 →
2026.11.0, OS 18.2 → 18.4 and Z-Wave JS 1.6.0 → 1.10.0 are pending — night 1
installs Z-Wave JS then Core (HA restarts), night 2 installs the OS.

Kill switch: Settings → Helpers → "Auto Update Enabled". The helper has no
`initial` value on purpose (it must survive the HA restart every Core update
causes), so **turn it on once after the first deploy**; it then persists.

## Deploy (nothing applies automatically — HAOS keeps /config in the VM)

```bash
cat homeassistant/packages/auto_update.yaml | ssh tayvenbigelow@192.168.1.234 "cat > /tmp/auto_update.yaml"
ssh tayvenbigelow@192.168.1.234 "sudo mv /tmp/auto_update.yaml /config/packages/auto_update.yaml"
TOK=$(cat ~/.config/ha/llat); HA=http://192.168.1.234:8123
curl -s -X POST -H "Authorization: Bearer $TOK" -d '{}' "$HA/api/services/homeassistant/check_config"
# reload_all re-reads packages (creates the helper AND the automation; a plain
# automation reload would leave the helper missing and the automation inert)
curl -s -X POST -H "Authorization: Bearer $TOK" -d '{}' "$HA/api/services/homeassistant/reload_all"
curl -s -H "Authorization: Bearer $TOK" "$HA/api/states/input_boolean.auto_update_enabled" | head -c 120
curl -s -H "Authorization: Bearer $TOK" "$HA/api/states/automation.auto_update_nightly" | head -c 120
# one-time: enable it
curl -s -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"entity_id":"input_boolean.auto_update_enabled"}' "$HA/api/services/input_boolean/turn_on"
```

Verify the morning after: `automation.auto_update_nightly` has a
`last_triggered`, the Discord "starting" (and "finished" or "FAILED")
messages arrived, and the `update.*` entities are `off`. Per-update
Supervisor backups accumulate under Settings → System → Backups; prune
them occasionally (they are not covered by the vzdump retention).

## Verification (local)

`/usr/bin/python3 homeassistant/tests/test_auto_update_package.py` (also
runs under pytest once PyYAML is in the venv): persistent kill switch +
05:30 trigger, explicit order with Core last, OS deferred on Core nights,
exactly one `backup: true` install inside the repeat, the allow-list, the
OS gate, HACS exclusion, in-progress guard, start/failure/finish
notifications, the `reload_all` instruction. `yamllint` clean. The YAML
itself is validated by HA (`check_config` before `reload_all`). Independent
review (2026-11-04) found the ordering/restart and kill-switch issues; fixed.

## TrueNAS

Stays manual by design — `docs/runbooks/truenas-upgrade.md` (backup-gated,
boot-environment rollback). The "update available" signal comes from PR
#309's TrueNAS alert-list exporter once merged (`TrueNASAlert` with the
update class), until then from the TrueNAS UI.
