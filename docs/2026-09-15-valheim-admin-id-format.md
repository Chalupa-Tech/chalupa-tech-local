# Fix Valheim admin IDs: Platform User ID, not bare SteamID64

**Date:** 2026-09-15
**PR:** [#336](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/336)

## Symptom

After [#335](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/335)
installed `Server_devcommands`, an admin still could not use dev commands:

```
devcommands
Dev commands: False
Devcommands: True
spawn Boar_piggy 1 4
'spawn' is not valid in the current context.
fly
'fly' is not valid in the current context.
```

## Root cause

The admin list was never matching anyone. [#334](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/334)
wrote `adminlist.txt` entries as the bare 17-digit SteamID64 and added an
`assert` enforcing exactly that shape. That is the **pre-crossplay** form.
Since crossplay, Valheim matches these lists against the *Platform User ID*
— the [official dedicated server guide](https://www.valheimgame.com/support/a-guide-to-dedicated-servers/)
says to "add one Platform User ID per line… follows the format
`[Platform]_[User ID]` (case sensitive)". On Valheim 1.0 a Steam player's ID
is `V_` + SteamID64, as shown in the in-game **F2** player panel.

So the server accepted the file, matched nobody, and granted no rights —
silently, which is exactly the failure mode #334's assert was meant to
prevent but instead guaranteed.

`Server_devcommands` then behaves correctly on top of that: it gates
`devcommands` on server-side admin status (`Admin.Check()` probes it with a
dummy `Unban("admintest_<playerID>")` and reads the reply), so no admin means
no cheats, hence `'spawn' is not valid in the current context.`

## What changed

- `roles/valheim/tasks/admins.yml` — the assert now requires
  `<Platform>_<UserID>` (`^[A-Za-z][A-Za-z0-9]*_[0-9]{5,}$`) and its
  `fail_msg` explains where to read the ID. Deliberately not Steam-specific:
  it validates the *shape*, so a future PlayFab/Xbox entry passes.
- `group_vars/all.yml` — `76561197989755338` → `V_76561197989755338`.
- `roles/valheim/templates/adminlist.txt.j2` and
  `oracle-cloud-server/README.md` — corrected format guidance.
- `docs/2026-09-15-valheim-adminlist.md` — its "ID format" section is marked
  corrected and points here, rather than being left to mislead.

## What did not change

The template's `//` comment lines stay. Valheim generates these files with a
`// List admin players ID ONE per line` header of its own, so whole-line `//`
comments are ignored by the parser. The warnings in hosting docs are about
comments *trailing* an ID on the same line, which the template already avoids
by putting names on their own line above.

## Verification

- ID confirmed against the in-game F2 player panel (`V_76561197989755338`),
  not inferred — it is case-sensitive and matched verbatim.
- Post-merge: `ssh ubuntu@oracle-server`, `sudo cat /opt/valheim/data/adminlist.txt`
  shows the `V_`-prefixed ID; then rejoin, press `F5`, and run `devcommands`.
  Expect the mod's `Authorized to use devcommands.` line, after which `fly`
  and `spawn` are accepted.
