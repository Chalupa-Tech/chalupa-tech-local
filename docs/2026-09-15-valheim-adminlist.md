# Manage the Valheim server admin list in Ansible

**Date:** 2026-09-15
**PR:** _TBD_

## What

- Added `valheim_admins` to the Oracle Valheim role, rendering
  `/opt/valheim/data/adminlist.txt` (the save dir passed to the server as
  `-savedir`, which is where Valheim reads its permission lists from):
  - `roles/valheim/defaults/main.yml` — `valheim_admins: []` default.
  - `roles/valheim/templates/adminlist.txt.j2` — one SteamID64 per line, with
    an Ansible-managed header. Optional `name:` on an entry renders as a `//`
    comment line *above* the ID, never trailing it: Valheim only skips whole
    lines beginning with `//`, so an inline comment would corrupt the ID.
  - `roles/valheim/tasks/admins.yml` — asserts each entry is a 17-digit
    SteamID64, then templates the file (owner `valheim`, mode `0644`).
  - `roles/valheim/tasks/main.yml` — imported between the BepInEx and service
    tasks, so the list exists before the unit first starts on a fresh host.
  - `group_vars/all.yml` — the actual admin entries, beside
    `valheim_server_name` / `valheim_world_name`.

## Why

Admin powers (`/kick`, `/ban`, `/save`, the `F5` console, no-cost build/fly
via `devcommands`) were previously unavailable: nothing created an
`adminlist.txt`, and hand-editing one over SSH would be erased by the next
deploy anyway — everything under `/opt/valheim` is Ansible-owned and CI is
the only thing that applies changes. Putting the list in `group_vars`
makes admin membership reviewable in a PR like every other change to this
box, and survives an instance rebuild.

## No restart handler

Unlike the mod/config tasks, templating `adminlist.txt` deliberately does
**not** notify `Restart valheim`. Valheim re-reads the permission lists
(`adminlist.txt`, `bannedlist.txt`, `permittedlist.txt`) from the save dir
while the server is running, so an admin change applies without dropping
everyone mid-session. A restart is only a fallback if a change doesn't take.

## ID format

Crossplay is off on this server (Steam-only), so entries are the 17-digit
SteamID64 (`7656119…`) — the form Valheim matches against a Steam peer's
host name. The `assert` in `admins.yml` rejects anything else, because a
wrong-format ID fails silently: the server starts fine and the player simply
has no admin rights. Note the 10-digit "friend code" / Steam3 account ID
shown in some UIs is *not* accepted; it converts via
`steamID64 = 76561197960265728 + accountID`.

## Verification

- Template rendered offline against sample entries; `//` comment lines land
  above each ID and the file ends with a trailing newline.
- `ansible-lint` runs in CI (`.github/workflows/oracle.yml`) on this path.
- Post-merge: `ssh ubuntu@oracle-server`, confirm
  `sudo cat /opt/valheim/data/adminlist.txt` matches `valheim_admins`, then
  join the server and check `F5` opens the console and `/save` is accepted.
