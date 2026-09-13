# Add ServersideQoL_AutoFeed: auto-feed tamed animals from chests

**Date:** 2026-09-13
**PR:** [#323](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/323)
**Design:** docs/superpowers/specs/2026-09-13-autofeed-serverside-design.md

## What

- Installed `ServersideQoL_AutoFeed` 0.1.0 on the Oracle Valheim server via
  `oracle-cloud-server/ansible/roles/valheim/defaults/main.yml`:
  - Appended to `valheim_mods`, pinned to the tagged GitHub Release asset
    (`https://github.com/tayvenb13/serverside_qol-autofeed/releases/download/v0.1.0/ServersideQoL_AutoFeed-0.1.0.zip`)
    — the role's existing `url` + `manifest.json`-gated unarchive support
    handles a non-Thunderstore-hosted mod the same as any other.
  - Enabled it via `valheim_mod_settings` (`ini_file`): `Enabled = true` in
    `tayvenb13.ServersideQoL.AutoFeed.cfg` under `[AutoFeed]`.
    `ContainerRange` is left at its shipped default of 10 (metres searched
    around each hungry animal).
- This is our own mod, built in
  [tayvenb13/serverside_qol-autofeed](https://github.com/tayvenb13/serverside_qol-autofeed)
  as a plugin on the [ArgusMagnus ServersideQoL](https://github.com/ArgusMagnus/ValheimServersideQoL)
  framework already running on the server (see the design spec above for the
  full architecture).

## Why

Tamed animals should eat from nearby chests automatically, with no
client-side mod required — vanilla and console clients included. The
existing [Stephen-Cherry/AutoFeed](https://github.com/Stephen-Cherry/AutoFeed)
mod (credited as the idea's origin) can't do this on a dedicated server: its
single Harmony patch hooks `MonsterAI.UpdateConsumeItem`, which only runs on
the client that owns the animal's zone, early-returns when
`Player.m_localPlayer is null`, and requires every client to install it via
Jotunn `NetworkCompatibility(EveryoneMustHaveMod)`. ServersideQoL modules
instead run entirely server-side — a processor iterates world ZDOs, removes a
matching item from a nearby container, and stamps the tame's last-feeding
var, so vanilla `Tameable.IsHungry()` reads the fed state on every client
with zero client install.

## Version-coupling rule

`ServersideQoL_AutoFeed` is compiled against **ServersideQoL core 2.0.6**
(the `ServersideQoL` entry's `version:` in this same `main.yml`). The two
pins move together: bumping the SSQoL core version without also rebuilding
and re-pinning AutoFeed (or vice versa) risks the plugin calling core APIs
that moved or disappeared. SSQoL's public API is not a stability contract,
so any future core bump must land in the same PR as an AutoFeed rebuild/pin
bump (or a verification that the existing AutoFeed build still loads against
the new core).

## Verification

- `ansible-lint` clean against `oracle-cloud-server/ansible`.
- Post-merge live smoke test (per the spec): pen a tamed animal next to a
  stocked chest with no client mods installed, confirm feed log lines in
  `journalctl -u valheim`, and check the animal shows fed/happy on a vanilla
  client with chest stock decrementing.

## Follow-ups

- None planned; `ContainerRange` can be tuned later via
  `valheim_mod_settings` if 10 m proves too small/large in practice.
