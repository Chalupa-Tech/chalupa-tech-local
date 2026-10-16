# Add PedanticPeaches as a Valheim server admin

**Date:** 2026-10-16
**PR:** [#PENDING](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/PENDING)

## What

Added a second entry to `valheim_admins` in
`oracle-cloud-server/ansible/group_vars/all.yml`:

```yaml
  - id: "V_76561198040838917"
    name: PedanticPeaches
```

No task or template changes — `admins.yml` renders
`/opt/valheim/data/adminlist.txt` from this list and already handles multiple
entries.

## Why the `V_` prefix was added

The ID was supplied as the bare SteamID64 `76561198040838917`. That is the
pre-crossplay form, which the server accepts into the file and then silently
matches against nothing — the player joins fine and simply has no admin
rights. Valheim 1.0 wants the Platform User ID, `<Platform>_<UserID>`, which
for a Steam player is `V_` followed by the SteamID64. This server runs with
crossplay off (Steam only), so `V_` is the correct platform prefix.

See [2026-09-15-valheim-admin-id-format.md](2026-09-15-valheim-admin-id-format.md)
for the original diagnosis of that failure mode.

## Verification

The role's own assert and template were run locally against the new list
before committing, rather than eyeballing the regex:

- `item.id is match('^(V|Steam)_7656119[0-9]{10}$')` passes —
  `V_76561198040838917` is `7656119` + ten digits (`8040838917`).
- The rendered `adminlist.txt` puts each name on its own `//` comment line
  above its ID. This matters: Valheim only ignores whole lines starting with
  `//`, so a trailing comment on an ID line would invalidate that ID.

## No restart, but it does need PR #395 first

`admins.yml` deliberately carries no restart handler — Valheim re-reads the
permission lists (admin/banned/permitted) from the save directory while
running, so the change applies without kicking anyone off.

However, `admins.yml` is step 5 of 7 in the role, **after** `bepinex.yml`. The
deploy is currently broken at the mod-install task (see
[2026-10-16-valheim-deploy-fixes.md](2026-10-16-valheim-deploy-fixes.md)), so
until [#395](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/395)
merges, a deploy aborts before ever reaching the admin list. Merge order:
#395, then this.
