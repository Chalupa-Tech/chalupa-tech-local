# AutoFeed — Server-Side Rewrite as a ServersideQoL Plugin

**Date:** 2026-09-13
**Status:** Approved design, pre-implementation

## Goal

Tamed animals on the Oracle Valheim dedicated server automatically eat from
nearby chests, with **no client-side mod required** — vanilla/console clients
included. Delivered as a new repo,
[tayvenb13/serverside_qol-autofeed](https://github.com/tayvenb13/serverside_qol-autofeed),
implementing the idea of
[Stephen-Cherry/AutoFeed](https://github.com/Stephen-Cherry/AutoFeed) (credited
in the README) as a plugin built on the
[ArgusMagnus ServersideQoL](https://github.com/ArgusMagnus/ValheimServersideQoL)
framework already running on the server.

## Why a rewrite, not a port

The original AutoFeed is client-side by construction:

- Its single Harmony patch hooks `MonsterAI.UpdateConsumeItem`, which runs on
  the **client that owns the animal's zone**, never on a dedicated server.
- The patch early-returns when `Player.m_localPlayer is null` — on a dedicated
  server it is a no-op.
- It declares Jotunn `NetworkCompatibility(EveryoneMustHaveMod)`, forcing every
  client to install it.

ServersideQoL modules take the opposite approach: server-side "Processors"
iterate world ZDOs, take ownership, and mutate data directly; clients simply
observe replicated state. The core framework already ships (unused)
`ServersideQoLZDO.Vars.SetTameLastFeeding()`, a `TameableRegistryProcessor`
that classifies tameable ZDOs, and container-inventory manipulation used by
AutoStore/AutoProcess. Feeding = remove one matching item from a chest ZDO +
stamp `s_tameLastFeeding`. Vanilla `Tameable.IsHungry()` on clients reads that
ZDO var, so the animal is fed as far as every client is concerned.

## Decisions (settled with owner)

| Decision | Choice |
|---|---|
| Repo | New repo `tayvenb13/serverside_qol-autofeed` (no forked history); AutoFeed credited as the idea's origin |
| Feed scope | **Tamed animals only** — no feeding during taming |
| Chest eligibility | **Fixed configurable radius** around the animal (default 10 m); no ContainerSigns feed-range integration |
| Distribution | GitHub Actions in the mod repo builds and attaches a Thunderstore-layout zip to a tagged GitHub Release; ansible pins the release URL |

## Architecture

### Repo layout (`tayvenb13/serverside_qol-autofeed`)

Fresh repo — no code is taken from AutoFeed (its client-side Harmony patch,
`Extensions/`, and Jotunn dependency are all unusable server-side). Structure
mirrors its core/tests split: a Unity-free logic project for unit-testable
pieces plus the plugin project, with a README crediting AutoFeed for the idea
and ServersideQoL for the framework, and noting that upstream ServersideQoL
carries no license file (this plugin exists for personal-server use). Mod
name follows the family convention: **`ServersideQoL_AutoFeed`**, author
`tayvenb13` (exact plugin GUID/config filename pinned during implementation to
whatever `ServersideQoLPluginBase` expects).

### Plugin: `AutoFeedPlugin`

- Hand-written `[BepInPlugin(PluginGuid, PluginName, PluginVersion)]`
  (upstream generates this boilerplate in MSBuild; we write it explicitly).
- `[BepInDependency("ArgusMagnus.ServersideQoL")]`.
- Subclasses public `ServersideQoLPluginBase<AutoFeedPlugin, Config>`;
  registers one processor via `RegisterProcessors(IProcessorCollection)`,
  mirroring `TameAssistPlugin`.

### Processor: `AutoFeedProcessor`

`Processor<TameableRegistryProcessor.PrefabInfo>` with
`[RunAfter<TameableRegistryProcessor>]` (`TameableRegistryProcessor` lives in
SSQoL **core**, not TameAssist). Per processed ZDO:

1. Skip unless registry state is `Tamed`.
2. Hungry check, identical to TameAssist's:
   `(ZNet.instance.GetTime() − zdo.Vars.GetTameLastFeeding()).TotalSeconds >
   m_fedDuration` (field read via `zdo.Fields<Tameable>()`, so it respects any
   TameAssist fed-duration multiplier if that module is ever installed).
3. Find a container within `ContainerRange` of the animal holding any of the
   prefab's `MonsterAI.m_consumeItems`, using the same core proximity/container
   APIs `SmelterProcessor` and AutoStore use (exact helper calls pinned down
   during implementation — the pattern is proven in-repo).
4. Remove one matching item from the container's ZDO inventory;
   `zdo.Vars.SetTameLastFeeding(now)`.
5. Log one line per feed event (creature prefab, item, chest position) so the
   behavior is verifiable from `journalctl`.

### Config (`Author.AutoFeed.cfg`)

| Key | Default | Notes |
|---|---|---|
| `Enabled` | `false` | SSQoL convention: features ship off; the server enables via ansible |
| `ContainerRange` | `10` | Metres searched around each hungry animal |

Nothing else. No taming support, no per-chest opt-in, no feed throttle beyond
the framework's own processing cadence and the hunger timer itself (a fed
animal is not hungry again until `m_fedDuration` lapses, which is the natural
rate limit).

## Version pinning

The plugin builds against the **exact SSQoL core version deployed on the
server** (currently `2.0.6` in
`oracle-cloud-server/ansible/roles/valheim/defaults/main.yml`). If the needed
core APIs require a newer core, the server pin is bumped in the same deploy
PR. SSQoL's public API is not a stability contract; both sides stay pinned and
move together deliberately.

## Build & release (mod repo CI)

- **PR workflow:** restore + `dotnet build` + unit tests. References come from
  BepInEx NuGet packages, Valheim reference assemblies (`Valheim.GameLibs`
  NuGet if current for the server's Valheim version, else vendored stripped
  DLLs), and the SSQoL core DLL extracted from its Thunderstore package at the
  pinned version.
- **Tag workflow:** same build, then assemble a Thunderstore-layout zip
  (`manifest.json`, `icon.png`, `README.md`, plugin DLL) and attach it to a
  GitHub Release for the tag.

## Deployment (this repo, separate PR)

- Add to `valheim_mods` with an explicit GitHub-release `url` (the role
  already supports arbitrary `url` + `manifest.json`-gated unarchive).
- Enable via `valheim_mod_settings` (`ini_file`), same as other SSQoL modules.
- `docs/` entry with rationale and PR links.

## Testing & verification

- **Unit (CI):** pure-logic pieces — hunger math, consume-item matching —
  live in `AutoFeed.Core` free of Unity types and are tested in
  `AutoFeed.Tests`.
- **Live smoke test (post-merge):** pen a tamed animal next to a stocked
  chest with no client mods installed; confirm feed log lines in
  `journalctl -u valheim` and the animal shows fed/happy on a vanilla client,
  and chest stock decrements.

## Risks

- **SSQoL API churn:** a core bump can break the plugin. Mitigated by pinning
  both sides and treating upgrades as coordinated changes.
- **External consumability:** if `ServersideQoLPluginBase` or the container
  helpers prove less usable outside the upstream solution than they appear,
  fallback is registering the processor with the same core plumbing the
  first-party modules use — same design, more glue code.
- **License provenance:** neither upstream repo has a license. No upstream
  code is copied — AutoFeed contributes only the idea, and the plugin links
  against the ServersideQoL DLL the server already runs. The README credits
  both projects; the artifact is only consumed by this personal server.
