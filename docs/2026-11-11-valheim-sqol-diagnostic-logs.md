# Turn on ServersideQoL diagnostic logs (Valheim)

**Date:** 2026-11-11
**PR:** _TBD_

## What

Added `[General] DiagnosticLogs = true` for `ArgusMagnus.ServersideQoL.cfg` to
`valheim_mod_settings` in `oracle-cloud-server/ansible/roles/valheim/defaults/main.yml`.
The existing "Apply managed mod config settings" task writes it, and its
handler restarts `valheim`.

## Why

Tamed Asksvins are going hungry next to a food chest. Every check so far says
the mod is healthy:

- All six ServersideQoL modules load cleanly, and the BepInEx log has no
  ServersideQoL warnings or errors since the 2026-11-06 start.
- The live `TameAssist.cfg` has `FeedFromContainers = true` and
  `FeedFromContainersRange = 2`.

The likely culprit is the range, not the mod. Reading the v2.3.3 source
(`TameableProcessor.cs`) shows how feeding works:

- Distance is measured from each tame to the chest in 3D, height included
  (upstream #390), so 2 m is very tight.
- A chest that a player has open is skipped.
- `FeedFromContainersLeaveAtLeast = 1` keeps one of each food type in the chest.

The interim fix is a per-chest sign override `🐗16 •`. Stay at 64 or below:
v2.3.3 corrupts sign text above the cap (upstream #387, fixed in v2.4.4).

## What diagnostic logs do (and don't) give us

From the v2.3.3 source, `DiagnosticLogs` enables:

- **A startup config dump.** Each `[Section].[Key] = value` the mod is actually
  running with, with non-default values marked `*`. This confirms the Ansible
  values took effect.
- **The processor order.** This shows whether TameAssist's processor is
  registered and active.
- **A processing-time CSV, plus RPC counters.** The CSV rotates at 10 MB into
  a zip.

It does **not** log individual feed attempts, because `FeedFromContainer`
contains no log calls. So this shows the setup is right, not why a specific
tame didn't eat.

## Where to look

BepInEx output goes to `/opt/valheim/server/BepInEx/LogOutput.log`, which is
root-readable only. It does not go to the journal. The README Operations
section now says so.

## Follow-up

Turn this back off once the feeding question is settled, unless it turns out
to be useful to keep.
