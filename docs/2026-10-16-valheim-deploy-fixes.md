# Two deploy bugs found by the 1.0.20 update: unzip rc=1 and broken update detection

**Date:** 2026-10-16
**PR:** [#395](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/395)
**Follows:** [2026-10-16-valheim-1.0.20-server-update.md](2026-10-16-valheim-1.0.20-server-update.md) ([#394](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/394))

## What happened

The deploy from #394 ([run 38965705132](https://github.com/Chalupa-Tech/chalupa-tech-local/actions/runs/38965705132))
failed partway through the `valheim` role, leaving the server half-updated.
Two independent bugs, one of which had been silently active for a month.

## Bug 1 — `unarchive` fails on a zip that extracted fine

`Install mods into BepInEx plugins dir` failed on Jotunn 2.30.2:

```
failed to unpack /opt/valheim/dist/Jotunn-2.30.2.zip to .../plugins/Jotunn-2.30.2
"err": "warning: ... appears to use backslashes as path separators"
"rc": 1
```

Jotunn's zip stores its paths with **backslash** separators
(`plugins\Jotunn.dll`). `unzip` resolves those correctly — the module's own
`out` shows all eight files inflated, including `plugins/Jotunn.dll` as a real
directory — but it exits **1** to flag the warning. `unzip` uses 1 for
"completed with warnings"; only `>1` is a hard error.
`ansible.builtin.unarchive` treats any non-zero rc as failure, so the task
failed despite having done its job correctly.

Fixed by calling `unzip` directly and accepting exactly the two codes that
mean success: `failed_when: rc not in [0, 1]`.

Note this is deliberately **not** `failed_when: rc > 1`, which looks
equivalent and is not. `not (rc > 1)` tolerates everything `<= 1`, and Ansible
reports a **negative** rc for a signal-killed process (`rc=-9` for SIGKILL,
confirmed against ansible-core 2.21.5). So `rc > 1` would read an
OOM-killed or timed-out `unzip` as success and then — via `changed_when:
true` — notify a restart on a half-extracted mod. Worse, if `manifest.json`
happened to land before the kill, the `stat` guard would treat that mod as
installed and never retry it. The two predicates agree on every code `unzip`
actually emits (0, 1, 2, 9, 50, ...) and diverge only on negatives, which is
exactly the case that matters.

### The trap in the obvious version of that fix

The first attempt kept `unarchive`'s `creates:` guard and derived changed-ness
from the return code:

```yaml
creates: ".../manifest.json"
changed_when: unzip_result.rc is defined and unzip_result.rc <= 1
```

That is wrong. When `creates:` short-circuits, `ansible.builtin.command`
still returns **`rc: 0`** with `msg: "Did not run command since ... exists"`.
So `changed_when` fires on a no-op run, every mod reports `changed`, and
`notify: Restart valheim` restarts the server **on every deploy**. Verified
locally against ansible-core 2.21.5 before it shipped.

The committed version drops `creates:` and gates on an explicit `stat`
instead, so skipped items are genuinely skipped and carry no `rc` at all.
Verified: a fresh run installs all mods (Jotunn included) and fires the
handler once; a second run skips everything with `changed=0` and the handler
does not fire.

## Bug 2 — update detection watched a file that never changes

`Detect server update` compared sha256 of
`{{ valheim_server_dir }}/valheim_server.x86_64` before and after
DepotDownloader, and notified `Restart valheim` on a difference.

That file is a **Unity bootstrap stub of about 15 KB**. It does not change
when Iron Gate patches the game. Game code lives in
`valheim_server_Data/Managed/assembly_valheim.dll`.

Proof from a client install that took the 1.0.20 patch on 2026-10-15:

```
2026-09-10 14:47   valheim.x86_64                              15072
2026-09-10 14:48   UnityPlayer.so                           39513144
2026-10-15 17:36   valheim_Data/Managed/assembly_valheim.dll  2575360
```

The patch rewrote the assembly and left the stub — and even `UnityPlayer.so` —
untouched from five weeks earlier.

So in the #394 deploy, DepotDownloader pulled 1.0.20 successfully and
`Detect server update` still reported **ok, not changed**. The handler was
never notified by that task. The practical effect, in place since the role was
written: **a game-only update never restarts the service.** The server keeps
running old code indefinitely, while the files on disk are current.

This corrects the account given in the #394 writeup, which blamed the
month-old binary purely on `detect-changes` skipping the Ansible job. That was
only half of it. Even the deploys that *did* run would not have restarted into
a new build unless a mod or BepInEx pin changed in the same commit — which is
exactly why the drift went unnoticed for a month.

Fixed by checksumming `valheim_server_assembly` as well, with an `assert` that
the file exists after the update. Without that assert, a renamed path would
make both checksums empty, compare equal, and silently never restart again —
the same failure in a new costume.

Verified locally across four cases: no-change (no restart), assembly changes
while stub does not (**restart fires**), re-run after patch (no restart),
assembly missing (fails loudly).

## State this left the server in

The play aborted inside `bepinex.yml`, so everything after the failing task
never ran, and **handlers do not run when a play fails**. Therefore:

- Game files updated to 1.0.20; the running process is still the old build.
- BepInEx 5.4.2351 and all new mod versions installed.
- Old versioned plugin directories **not** pruned → duplicate plugin versions
  on disk (e.g. `ServersideQoL-2.0.6` beside `ServersideQoL-2.3.3`).
- The ServersideQoL 2.3.3 preloader patcher **not** copied into
  `BepInEx/patchers`; the 2.0.6 patcher is still there.
- `ServersideQoL_AutoFeed` **not** removed.
- TameAssist config **not** applied.
- `admins.yml`, `service.yml` and `backup.yml` never ran.
- Service **not** restarted.

A manual `systemctl restart valheim` in this state would load duplicate
plugin versions against a mismatched patcher. One clean deploy repairs it:
pruning happens before handlers, so the duplicates are gone by the time the
service restarts.

## Follow-ups

- Nothing in CI exercises this role. `ansible-lint` is a syntax/style gate and
  the PR workflow runs `--check` only against the real host, which cannot
  catch an `unarchive` rc bug. A molecule scenario, or even a localhost smoke
  play over the mod-install tasks with a backslash zip fixture, would have
  caught both of these.
- `Detect server update` uses `command: /bin/true` purely to carry a
  `changed_when`. It works, but a cleaner shape would be to compute the
  comparison into a fact and notify from the stat tasks themselves.
