# Install Server_devcommands on the Valheim server

**Date:** 2026-09-15
**PR:** TBD

## What

- Added `JereKuusela-Server_devcommands` 1.113.0 to `valheim_mods` in
  `oracle-cloud-server/ansible/roles/valheim/defaults/main.yml`. No new tasks:
  the existing `bepinex.yml` download/unpack/prune loop handles it like every
  other pinned mod, installing it to
  `BepInEx/plugins/Server_devcommands-1.113.0` and notifying `Restart valheim`.
- `oracle-cloud-server/README.md` — noted it under the client-mod section as
  an admin-only install, and extended the "Server admins" operations bullet to
  say `devcommands` is now available.

## Why

Vanilla Valheim hard-disables `devcommands` on dedicated servers: the console
opens for an admin, but the cheat commands behind it (`fly`, `spawn`, `tod`,
`god`, …) are rejected no matter what `adminlist.txt` says. Server_devcommands
is the standard fix — it re-enables them and gates them on the admin list, so
the permission model stays the one we already manage in `valheim_admins`
(see [2026-09-15-valheim-adminlist.md](2026-09-15-valheim-adminlist.md)).

## Why no config or task changes were needed

- The Thunderstore zip is the shape the role already expects: `manifest.json`
  at the root (the `creates:` guard for the unarchive task) and a single
  `ServerDevcommands.dll`. There is no `patchers/` folder, so the
  patcher-staging task correctly picks up nothing from it.
- Its only dependency is `denikson-BepInExPack_Valheim-5.4.2350`, which is
  exactly our `bepinex_version` pin — nothing else to add.
- The mod's own `BepInEx/config` file is left at its defaults, so no entry in
  `valheim_mod_settings`. Defaults already grant admins everything; the
  settings there are for narrowing (e.g. restricting specific commands), which
  we do not want yet.

## Client side

Server side installation is what enforces the admin gate, but the commands are
typed on the client, so an admin also installs the same 1.113.0 build locally.
This is deliberately *not* in the required-mods table: non-admin clients need
nothing and join unaffected, and the mod does not enforce a version handshake.

## Verification

- Package contents and dependency list checked against the Thunderstore API
  before pinning (1.113.0, published 2026-09-12, current for Valheim 1.0).
- `ansible-lint` runs in CI (`.github/workflows/oracle.yml`) on this path.
- Post-merge: `journalctl -u valheim | grep -i 'Loading \['` shows
  `Server devcommands 1.113.0`, then join as an admin, press `F5`, run
  `devcommands` and confirm e.g. `fly` is accepted (and that a non-admin gets
  refused).
