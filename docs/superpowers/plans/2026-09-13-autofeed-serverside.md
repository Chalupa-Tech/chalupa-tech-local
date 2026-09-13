# ServersideQoL_AutoFeed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A server-side-only BepInEx plugin (`ServersideQoL_AutoFeed`) that feeds tamed Valheim animals from nearby chests, released from a new GitHub repo and deployed to the Oracle Valheim server via ansible.

**Architecture:** A ServersideQoL framework module: one `Processor` iterates tamed-creature ZDOs on the dedicated server, and when a creature is hungry removes one matching consume item from a container ZDO within range and stamps `tameLastFeeding`. Vanilla clients need nothing. Built in `tayvenb13/serverside_qol-autofeed`, packaged as a Thunderstore-layout zip on GitHub Releases, pinned in this repo's ansible.

**Tech Stack:** C# / .NET SDK 9 (`netstandard2.1` plugin), BepInEx 5, ServersideQoL core 2.0.6 (referenced DLL), xunit, GitHub Actions, Ansible.

**Spec:** `docs/superpowers/specs/2026-09-13-autofeed-serverside-design.md`

## Global Constraints

- ServersideQoL core version: **2.0.6** exactly (matches server pin in `oracle-cloud-server/ansible/roles/valheim/defaults/main.yml`).
- BepInEx pack: `denikson/BepInExPack_Valheim` **5.4.2350** (server pin).
- YamlDotNet: `ValheimModding/YamlDotNet` **16.3.1** (server pin; compile-time reference only).
- Feed scope: **tamed creatures only** — never wild or mid-taming.
- Config: exactly two keys, section `AutoFeed`: `Enabled` (default `false`) and `ContainerRange` (default `10`).
- Plugin GUID `tayvenb13.ServersideQoL.AutoFeed`, plugin name `ServersideQoL.AutoFeed`, Thunderstore-style package name `ServersideQoL_AutoFeed` (dots→underscores, matching upstream convention).
- Mod repo: `https://github.com/tayvenb13/serverside_qol-autofeed` (already created, empty). Direct pushes to its `main` are fine — it is a fresh personal repo with no protections. First release tag: `v0.1.0`.
- This repo (chalupa-tech-local): **all changes via PR** on branch `feat/oracle-autofeed`; never push `main`; no local `pulumi up`/unchecked `ansible-playbook`.
- Local mod-repo checkout lives at `~/Documents/code/serverside_qol-autofeed` (sibling of this repo, durable across sessions — NOT the scratchpad).
- No code copied from `Stephen-Cherry/AutoFeed` (it is unlicensed and client-side); it is credited in the README as the idea's origin.

## Verified upstream API reference (read from SSQoL sources at the 2.0.6 commit, `b3429ed`)

The plan's code below was written against these confirmed APIs — implementers don't need to re-derive them:

- `ServersideQoLPluginBase<TSelf, TConfig>` (public): requires `[BepInPlugin]` on `TSelf` (read via reflection), `TConfig : ConfigBase<TConfig>`, overrides `CreateConfigSingleton(ConfigFile, Logger)` and `RegisterProcessors(IProcessorCollection)`; `IProcessorCollection.Add<T>()`.
- Module plugins declare `[BepInDependency(ServersideQoLPlugin.PluginGuid, ServersideQoLPlugin.PluginVersion)]` (see upstream `AutoStorePlugin.cs`). `ServersideQoLPlugin.PluginGuid` = `"ArgusMagnus.ServersideQoL"`, `PluginVersion` = `"2.0.6"` (consts baked into the referenced DLL).
- `ConfigBase<TSelf>`: abstract `ConfigEntry<bool> Enabled`; `BindEx(cfg, section, default, description)` binds using `[CallerMemberName]` as the key; static `Config.Instance`.
- `Processor<TPrefabInfo>`: `[Processor("<guid>")]` required; `[RunAfter<T>]` declares a required dependency and activates `OnlyWhenDependedOn` registry processors; a prefab qualifies when `TPrefabInfo`'s constructor parameters (component types) match; override `Initialize()` and `ProcessResult Process(ServersideQoLZDO zdo, IReadOnlyList<Peer> peers, TPrefabInfo prefabInfo)`; helpers `Instance<T>()`, `ScheduleReprocessing(float)`, `Logger`.
- `TameableRegistryProcessor` (core, `OnlyWhenDependedOn`): `PrefabInfo(Tameable Tameable, MonsterAI MonsterAI, Humanoid Humanoid)`; `GetState(zdo)` → `TameableState` with `State ∈ {Wild, Taming, Tamed}`.
- `ContainerRegistryProcessor` (core, `OnlyWhenDependedOn`): `GetContainersByItemName(sectorWidth)` → `SectorDictionary<SharedItemDataKey, HashSet<ServersideQoLZDO>>` with `EnumerateAdjacent((Vector3, SharedItemDataKey))`; `GetState(zdo)` → `ContainerState` with `GetInventory()` (→ `Items`, `Save()`); `RequestOwnership(zdo, playerID, state)` returns a retry delay for `ScheduleReprocessing`.
- `ServersideQoLZDO`: `.ZDO`, `.Vars.GetTameLastFeeding()/SetTameLastFeeding(DateTime)`, `.Vars.GetInUse()`, `.Fields<Tameable>().GetFloat(static () => x => x.m_fedDuration)`, `.IsOwnerOrUnassigned()`, `.ReleaseOwnership()`.
- Hungry check (mirrors upstream TameAssist and vanilla `Tameable.IsHungry`): `(ZNet.instance.GetTime() − Vars.GetTameLastFeeding()).TotalSeconds > m_fedDuration`.
- Writing vars to a moving, client-owned ZDO (pattern from core `ContainerRegistryProcessor` inventory `Save()` + `SmelterProcessor`): `ReleaseOwnership()`, set the var, then `zdo.ZDO.DataRevision += 120; ZDOMan.instance.ForceSendZDO(zdo.ZDO.m_uid);` so the change outruns the previous owner's revisions.
- `SharedItemDataKey` has implicit conversions from `ItemDrop.ItemData` / `SharedData`; `Utils.DistanceSqr` is Valheim's global helper.

---

### Task 1: Mod repo scaffold + dependency fetch

**Files (all in `~/Documents/code/serverside_qol-autofeed`):**
- Create: `.gitignore`, `Directory.Build.props`, `serverside_qol-autofeed.sln`
- Create: `scripts/fetch-deps.sh`
- Create: `src/AutoFeed.Core/AutoFeed.Core.csproj`
- Create: `src/ServersideQoL.AutoFeed/ServersideQoL.AutoFeed.csproj`
- Create: `src/ServersideQoL.AutoFeed/Placeholder.cs` (deleted in Task 3)

**Interfaces:**
- Consumes: nothing (fresh repo).
- Produces: `deps/` directory populated by `./scripts/fetch-deps.sh`; two buildable projects; `$(DepsDir)` MSBuild property. Task 2 adds code to `AutoFeed.Core`; Task 3 adds code to `ServersideQoL.AutoFeed`.

- [ ] **Step 1: Clone the empty repo and verify prerequisites**

```bash
cd ~/Documents/code
gh repo clone tayvenb13/serverside_qol-autofeed
cd serverside_qol-autofeed
dotnet --list-sdks   # need a 9.x SDK; if missing: brew install --cask dotnet-sdk
```

- [ ] **Step 2: Write the scaffold files**

`.gitignore`:
```
bin/
obj/
deps/
.cache/
*.zip
```

`Directory.Build.props`:
```xml
<Project>
  <PropertyGroup>
    <TargetFramework>netstandard2.1</TargetFramework>
    <LangVersion>latest</LangVersion>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <Version Condition="'$(Version)' == ''">0.1.0</Version>
    <DepsDir>$(MSBuildThisFileDirectory)deps/</DepsDir>
  </PropertyGroup>
</Project>
```

`src/AutoFeed.Core/AutoFeed.Core.csproj`:
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <RootNamespace>ServersideQoL.AutoFeed</RootNamespace>
  </PropertyGroup>
</Project>
```

`src/ServersideQoL.AutoFeed/ServersideQoL.AutoFeed.csproj`:
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <RootNamespace>ServersideQoL.AutoFeed</RootNamespace>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="../AutoFeed.Core/AutoFeed.Core.csproj" />
  </ItemGroup>
  <ItemGroup>
    <Reference Include="ServersideQoL" HintPath="$(DepsDir)ServersideQoL.dll" Private="false" />
    <Reference Include="BepInEx" HintPath="$(DepsDir)BepInEx.dll" Private="false" />
    <Reference Include="0Harmony" HintPath="$(DepsDir)0Harmony.dll" Private="false" />
    <Reference Include="YamlDotNet" HintPath="$(DepsDir)YamlDotNet.dll" Private="false" />
    <Reference Include="assembly_valheim" HintPath="$(DepsDir)assembly_valheim.dll" Private="false" />
    <Reference Include="assembly_utils" HintPath="$(DepsDir)assembly_utils.dll" Private="false" />
    <Reference Include="SoftReferenceableAssets" HintPath="$(DepsDir)SoftReferenceableAssets.dll" Private="false" />
    <Reference Include="UnityEngine" HintPath="$(DepsDir)UnityEngine.dll" Private="false" />
    <Reference Include="UnityEngine.CoreModule" HintPath="$(DepsDir)UnityEngine.CoreModule.dll" Private="false" />
  </ItemGroup>
  <Target Name="GenerateBuildInfo" BeforeTargets="CoreCompile">
    <PropertyGroup>
      <BuildInfoFile>$(IntermediateOutputPath)BuildInfo.cs</BuildInfoFile>
    </PropertyGroup>
    <WriteLinesToFile File="$(BuildInfoFile)" Overwrite="true" Lines="namespace ServersideQoL.AutoFeed%3B%0Apartial class AutoFeedPlugin%0A{%0A  public const string PluginVersion = &quot;$(Version)&quot;%3B%0A}" />
    <ItemGroup>
      <Compile Include="$(BuildInfoFile)" />
    </ItemGroup>
  </Target>
</Project>
```

`src/ServersideQoL.AutoFeed/Placeholder.cs` (keeps the project buildable until Task 3; note the partial-class stub so the generated `BuildInfo.cs` compiles):
```csharp
namespace ServersideQoL.AutoFeed;

partial class AutoFeedPlugin;
```

Create the solution and add projects:
```bash
dotnet new sln -n serverside_qol-autofeed
dotnet sln add src/AutoFeed.Core src/ServersideQoL.AutoFeed
```

- [ ] **Step 3: Write `scripts/fetch-deps.sh`** (and `chmod +x` it)

```bash
#!/usr/bin/env bash
# Populates deps/ with the reference assemblies the plugin compiles against:
# Valheim dedicated-server managed DLLs (anonymous Steam download), the
# BepInEx core DLLs, ServersideQoL core, and YamlDotNet — all at the exact
# versions pinned on the game server.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p deps .cache

if [ ! -f deps/assembly_valheim.dll ]; then
  if [ ! -x .cache/tools/DepotDownloader ]; then
    dotnet tool install --tool-path .cache/tools DepotDownloader
  fi
  printf 'regex:valheim_server_Data/Managed/.*\\.dll\n' > .cache/filelist.txt
  .cache/tools/DepotDownloader -app 896660 -filelist .cache/filelist.txt -dir .cache/valheim
  cp .cache/valheim/valheim_server_Data/Managed/*.dll deps/
fi

fetch_thunderstore() { # <url> <dllname> <marker-file>
  local url="$1" dll="$2" zip=".cache/$2.zip" extract=".cache/extract-$2"
  [ -f "deps/$dll" ] && return 0
  curl -fsSL -o "$zip" "$url"
  rm -rf "$extract" && mkdir -p "$extract"
  unzip -oq "$zip" -d "$extract"
  find "$extract" -name "$dll" -exec cp {} deps/ \;
  [ -f "deps/$dll" ] || { echo "ERROR: $dll not found in $url" >&2; exit 1; }
}

# BepInEx pack ships several core DLLs; extract them all from core/
if [ ! -f deps/BepInEx.dll ]; then
  curl -fsSL -o .cache/bepinex.zip "https://thunderstore.io/package/download/denikson/BepInExPack_Valheim/5.4.2350/"
  rm -rf .cache/extract-bepinex && mkdir -p .cache/extract-bepinex
  unzip -oq .cache/bepinex.zip -d .cache/extract-bepinex
  find .cache/extract-bepinex -path '*/BepInEx/core/*.dll' -exec cp {} deps/ \;
  [ -f deps/BepInEx.dll ] || { echo "ERROR: BepInEx.dll not extracted" >&2; exit 1; }
fi

fetch_thunderstore "https://thunderstore.io/package/download/ArgusMagnus/ServersideQoL/2.0.6/" ServersideQoL.dll
fetch_thunderstore "https://thunderstore.io/package/download/ValheimModding/YamlDotNet/16.3.1/" YamlDotNet.dll

echo "deps/ ready:"
ls deps/ | head -30
```

- [ ] **Step 4: Run the fetch and build**

```bash
./scripts/fetch-deps.sh
dotnet build -c Release serverside_qol-autofeed.sln
```
Expected: fetch populates `deps/` (Valheim Managed DLLs incl. `assembly_valheim.dll`, `BepInEx.dll`, `ServersideQoL.dll`, `YamlDotNet.dll`); build succeeds for both projects. If the Steam depot download stalls or a DLL name differs, fix the script now — this script is also what CI runs.

- [ ] **Step 5: Commit and push**

```bash
git add -A
git commit -m "chore: scaffold projects and dependency fetch script"
git push origin main
```

---

### Task 2: FeedingLogic (pure logic, TDD)

**Files:**
- Create: `src/AutoFeed.Core/FeedingLogic.cs`
- Create: `tests/AutoFeed.Core.Tests/AutoFeed.Core.Tests.csproj`
- Test: `tests/AutoFeed.Core.Tests/FeedingLogicTests.cs`

**Interfaces:**
- Consumes: nothing.
- Produces (used verbatim by Task 3's processor):
  - `public static double FeedingLogic.SecondsUntilHungry(DateTime now, DateTime lastFeeding, float fedDuration)` — `<= 0` means hungry now.
  - `public static int FeedingLogic.SelectSlot<T>(IReadOnlyList<T> slots, Func<T, string> name, Func<T, int> stack, string consumeName)` — index of the matching slot with the smallest positive stack, or `-1`.

- [ ] **Step 1: Create the test project**

`tests/AutoFeed.Core.Tests/AutoFeed.Core.Tests.csproj`:
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <IsPackable>false</IsPackable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.11.1" />
    <PackageReference Include="xunit" Version="2.9.2" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.8.2" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="../../src/AutoFeed.Core/AutoFeed.Core.csproj" />
  </ItemGroup>
</Project>
```
```bash
dotnet sln add tests/AutoFeed.Core.Tests
```

- [ ] **Step 2: Write the failing tests**

`tests/AutoFeed.Core.Tests/FeedingLogicTests.cs`:
```csharp
using ServersideQoL.AutoFeed;
using Xunit;

namespace AutoFeed.Core.Tests;

public class FeedingLogicTests
{
    static readonly DateTime Now = new(2026, 9, 13, 12, 0, 0);

    [Fact]
    public void SecondsUntilHungry_JustFed_ReturnsFullDuration()
        => Assert.Equal(600d, FeedingLogic.SecondsUntilHungry(Now, Now, 600f), 3);

    [Fact]
    public void SecondsUntilHungry_HalfElapsed_ReturnsRemainder()
        => Assert.Equal(300d, FeedingLogic.SecondsUntilHungry(Now, Now.AddSeconds(-300), 600f), 3);

    [Fact]
    public void SecondsUntilHungry_Elapsed_IsNonPositive()
        => Assert.True(FeedingLogic.SecondsUntilHungry(Now, Now.AddSeconds(-601), 600f) <= 0);

    [Fact]
    public void SecondsUntilHungry_NeverFed_DefaultTimestamp_IsHungry()
        => Assert.True(FeedingLogic.SecondsUntilHungry(Now, default, 600f) <= 0);

    static readonly (string Name, int Stack)[] Slots =
    [
        ("$item_carrot", 20),
        ("$item_turnip", 5),
        ("$item_carrot", 3),
        ("$item_carrot", 0),
    ];

    static int Select(string consumeName)
        => FeedingLogic.SelectSlot(Slots, static s => s.Name, static s => s.Stack, consumeName);

    [Fact]
    public void SelectSlot_PicksSmallestPositiveStack()
        => Assert.Equal(2, Select("$item_carrot"));

    [Fact]
    public void SelectSlot_MatchesExactNameOnly()
        => Assert.Equal(1, Select("$item_turnip"));

    [Fact]
    public void SelectSlot_NoMatch_ReturnsMinusOne()
        => Assert.Equal(-1, Select("$item_barley"));

    [Fact]
    public void SelectSlot_IgnoresEmptyStacks()
        => Assert.Equal(-1, FeedingLogic.SelectSlot(
            new[] { ("$item_carrot", 0) }, static s => s.Item1, static s => s.Item2, "$item_carrot"));
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
dotnet test tests/AutoFeed.Core.Tests
```
Expected: FAIL — compile error, `FeedingLogic` does not exist.

- [ ] **Step 4: Implement `FeedingLogic`**

`src/AutoFeed.Core/FeedingLogic.cs`:
```csharp
namespace ServersideQoL.AutoFeed;

public static class FeedingLogic
{
    /// <summary>Seconds until the creature becomes hungry; &lt;= 0 means hungry now.</summary>
    public static double SecondsUntilHungry(DateTime now, DateTime lastFeeding, float fedDuration)
        => fedDuration - (now - lastFeeding).TotalSeconds;

    /// <summary>
    /// Index of the slot to consume from: the slot matching <paramref name="consumeName"/>
    /// with the smallest positive stack (frees container slots fastest), or -1 if none.
    /// </summary>
    public static int SelectSlot<T>(IReadOnlyList<T> slots, Func<T, string> name, Func<T, int> stack, string consumeName)
    {
        var best = -1;
        for (var i = 0; i < slots.Count; i++)
        {
            var s = stack(slots[i]);
            if (s <= 0 || name(slots[i]) != consumeName)
                continue;
            if (best < 0 || s < stack(slots[best]))
                best = i;
        }
        return best;
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
dotnet test tests/AutoFeed.Core.Tests
```
Expected: PASS, 8/8.

- [ ] **Step 6: Commit and push**

```bash
git add -A
git commit -m "feat: hunger timing and slot-selection logic with tests"
git push origin main
```

---

### Task 3: Config, plugin, and AutoFeedProcessor

**Files:**
- Create: `src/ServersideQoL.AutoFeed/Config.cs`
- Create: `src/ServersideQoL.AutoFeed/AutoFeedPlugin.cs`
- Create: `src/ServersideQoL.AutoFeed/AutoFeedProcessor.cs`
- Delete: `src/ServersideQoL.AutoFeed/Placeholder.cs`

**Interfaces:**
- Consumes: `FeedingLogic.SecondsUntilHungry` / `FeedingLogic.SelectSlot` from Task 2 (signatures above); SSQoL core APIs from the "Verified upstream API reference" section.
- Produces: BepInEx plugin `tayvenb13.ServersideQoL.AutoFeed` whose config file is `BepInEx/config/tayvenb13.ServersideQoL.AutoFeed.cfg` with section `AutoFeed`, keys `Enabled` and `ContainerRange` (Task 5's ansible manages exactly these).

No unit tests here — everything touches game/framework types. Verification is compile (this task), package smoke (Task 4), and live behavior (Task 6).

- [ ] **Step 1: Write `Config.cs`**

```csharp
using BepInEx.Configuration;

namespace ServersideQoL.AutoFeed;

public sealed class Config(ConfigFile cfg, Logger logger) : ConfigBase<Config>(cfg, logger)
{
    const string Section = "AutoFeed";

    public override ConfigEntry<bool> Enabled { get; } = BindEx(cfg, Section, false,
        "Enables/disables the entire mod");
    public ConfigEntry<float> ContainerRange { get; } = BindEx(cfg, Section, 10f,
        "Radius in meters around a hungry tamed creature in which containers are searched for its food");
}
```

- [ ] **Step 2: Write `AutoFeedPlugin.cs`**

(`PluginVersion` comes from the `BuildInfo.cs` the csproj target generates, so the version has a single source: MSBuild `$(Version)`.)

```csharp
using BepInEx;
using BepInEx.Configuration;

namespace ServersideQoL.AutoFeed;

[BepInPlugin(PluginGuid, PluginName, PluginVersion)]
[BepInDependency(ServersideQoLPlugin.PluginGuid, ServersideQoLPlugin.PluginVersion)]
public sealed partial class AutoFeedPlugin : ServersideQoLPluginBase<AutoFeedPlugin, Config>
{
    public const string Author = "tayvenb13";
    public const string PluginName = "ServersideQoL.AutoFeed";
    public const string PluginGuid = $"{Author}.{PluginName}";

    protected override Config CreateConfigSingleton(ConfigFile configFile, Logger logger) => new(configFile, logger);

    protected override void RegisterProcessors(IProcessorCollection processors) => processors
        .Add<AutoFeedProcessor>();
}
```
Also delete `Placeholder.cs` (its partial-class stub is superseded by the real class).

- [ ] **Step 3: Write `AutoFeedProcessor.cs`**

```csharp
using ServersideQoL.Processors;
using ServersideQoL.Utilities;

namespace ServersideQoL.AutoFeed;

[Processor(Id)]
[RunAfter<TameableRegistryProcessor>]
[RunAfter<ContainerRegistryProcessor>]
public sealed class AutoFeedProcessor : Processor<TameableRegistryProcessor.PrefabInfo>
{
    public const string Id = "18fb793d-319a-4792-a924-157f4dc3ebb7";

    const float NoFoodRetrySeconds = 10f;

    SectorDictionary<SharedItemDataKey, HashSet<ServersideQoLZDO>>? _containersByItemName;
    List<ServersideQoLZDO>? _staleContainers;

    protected override void Initialize()
    {
        _containersByItemName = Instance<ContainerRegistryProcessor>()
            .GetContainersByItemName(Math.Max(Config.Instance.ContainerRange.Value, 1f));
    }

    protected override ProcessResult Process(ServersideQoLZDO zdo, IReadOnlyList<Peer> peers, TameableRegistryProcessor.PrefabInfo prefabInfo)
    {
        if (_containersByItemName is null)
            return ProcessResult.UnregisterProcessor;

        // Tamed creatures only; wild/taming ones are reprocessed whenever their ZDO changes,
        // so a fresh tame is picked up as soon as its 'tamed' var flips.
        if (Instance<TameableRegistryProcessor>().GetState(zdo) is not { State: TameableState.States.Tamed })
            return default;

        /// <see cref="Tameable.IsHungry()"/>
        var fedDuration = zdo.Fields<Tameable>().GetFloat(static () => x => x.m_fedDuration);
        var untilHungry = FeedingLogic.SecondsUntilHungry(ZNet.instance.GetTime(), zdo.Vars.GetTameLastFeeding(), fedDuration);
        if (untilHungry > 0)
            return ScheduleReprocessing((float)untilHungry + 1f);

        var result = ProcessResult.Default;
        var pos = zdo.ZDO.GetPosition();
        var rangeSqr = Config.Instance.ContainerRange.Value * Config.Instance.ContainerRange.Value;

        foreach (var consumeItem in prefabInfo.MonsterAI.m_consumeItems)
        {
            var consumeName = consumeItem.m_itemData.m_shared.m_name;
            foreach (var containers in _containersByItemName.EnumerateAdjacent((pos, (SharedItemDataKey)consumeItem.m_itemData)))
            {
                var fed = false;
                foreach (var containerZdo in containers)
                {
                    if (Instance<ContainerRegistryProcessor>().GetState(containerZdo) is not { } containerState)
                    {
                        (_staleContainers ??= []).Add(containerZdo);
                        continue;
                    }

                    if (containerZdo.Vars.GetInUse())
                        continue; // a player has the chest open

                    if (Utils.DistanceSqr(pos, containerZdo.ZDO.GetPosition()) > rangeSqr)
                        continue;

                    var inventory = containerState.GetInventory();
                    var slotIdx = FeedingLogic.SelectSlot(inventory.Items,
                        static x => x.m_shared.m_name, static x => x.m_stack, consumeName);
                    if (slotIdx < 0)
                    {
                        // no (more) matching food in this container: drop it from this item's index
                        (_staleContainers ??= []).Add(containerZdo);
                        continue;
                    }

                    if (!containerZdo.IsOwnerOrUnassigned())
                    {
                        // chest is owned by a client; request ownership and retry shortly
                        result |= ScheduleReprocessing(
                            Instance<ContainerRegistryProcessor>().RequestOwnership(containerZdo, default, containerState));
                        continue;
                    }

                    var slot = inventory.Items[slotIdx];
                    slot.m_stack -= 1;
                    if (slot.m_stack is 0)
                        inventory.Items.Remove(slot);
                    inventory.Save();

                    /// <see cref="Tameable.OnConsumedItem"/> — reset the hunger timer.
                    // The creature is a moving ZDO owned by a nearby client: release ownership
                    // and get ahead of the owner's data revisions so the change sticks (same
                    // pattern the core uses when saving inventories of moving ZDOs).
                    zdo.ReleaseOwnership();
                    zdo.Vars.SetTameLastFeeding(ZNet.instance.GetTime());
                    zdo.ZDO.DataRevision += 120;
                    ZDOMan.instance.ForceSendZDO(zdo.ZDO.m_uid);

                    Logger.LogInfo($"AutoFeed: fed {prefabInfo.PrefabInfo.PrefabName} at {pos} with {consumeName} from container at {containerZdo.ZDO.GetPosition()}");
                    fed = true;
                    break;
                }

                RemoveStale(containers);
                if (fed)
                    return result | ScheduleReprocessing(Math.Max(fedDuration, 1f));
            }
        }

        // hungry, but nothing edible in range — retry soon
        return result | ScheduleReprocessing(NoFoodRetrySeconds);
    }

    void RemoveStale(HashSet<ServersideQoLZDO> containers)
    {
        if (_staleContainers is not { Count: > 0 })
            return;
        foreach (var containerZdo in _staleContainers)
            containers.Remove(containerZdo);
        _staleContainers.Clear();
    }
}
```

- [ ] **Step 4: Build and run all tests**

```bash
dotnet build -c Release serverside_qol-autofeed.sln
dotnet test tests/AutoFeed.Core.Tests
```
Expected: clean build, tests still pass. Compile errors here most likely mean an API drifted from the reference section — check the SSQoL 2.0.6 sources (commit `b3429ed` of `ArgusMagnus/ValheimServersideQoL`) before improvising.

- [ ] **Step 5: Commit and push**

```bash
git add -A
git commit -m "feat: server-side auto-feeding processor, plugin, and config"
git push origin main
```

---

### Task 4: Packaging, CI, README, and the v0.1.0 release

**Files:**
- Create: `scripts/package.sh`
- Create: `.github/workflows/build.yml`
- Create: `.github/workflows/release.yml`
- Create: `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: build outputs `ServersideQoL.AutoFeed.dll` + `AutoFeed.Core.dll` from `src/ServersideQoL.AutoFeed/bin/Release/netstandard2.1/`.
- Produces: GitHub Release asset `https://github.com/tayvenb13/serverside_qol-autofeed/releases/download/v0.1.0/ServersideQoL_AutoFeed-0.1.0.zip` with `manifest.json` at zip root (Task 5's ansible pins this URL; the role's unarchive `creates:` gate requires root-level `manifest.json`).

- [ ] **Step 1: Write `scripts/package.sh`** (and `chmod +x`)

```bash
#!/usr/bin/env bash
# Builds the plugin at the given version and produces a Thunderstore-layout
# zip (manifest.json at root) that the server's ansible role can install.
set -euo pipefail
VERSION="${1:?usage: package.sh <version>}"
cd "$(dirname "$0")/.."

dotnet build -c Release -p:Version="$VERSION" src/ServersideQoL.AutoFeed/ServersideQoL.AutoFeed.csproj

STAGE="$(mktemp -d)"
BIN=src/ServersideQoL.AutoFeed/bin/Release/netstandard2.1
cp "$BIN/ServersideQoL.AutoFeed.dll" "$BIN/AutoFeed.Core.dll" README.md CHANGELOG.md "$STAGE/"

cat > "$STAGE/manifest.json" <<EOF
{
  "name": "ServersideQoL_AutoFeed",
  "version_number": "$VERSION",
  "website_url": "https://github.com/tayvenb13/serverside_qol-autofeed",
  "description": "Feeds tamed animals from nearby chests. Server-side only (ServersideQoL module).",
  "dependencies": ["ArgusMagnus-ServersideQoL-2.0.6"]
}
EOF

OUT="$PWD/ServersideQoL_AutoFeed-$VERSION.zip"
rm -f "$OUT"
(cd "$STAGE" && zip -r "$OUT" .)
echo "Wrote $OUT"
unzip -l "$OUT"
```

- [ ] **Step 2: Write the CI workflows**

`.github/workflows/build.yml`:
```yaml
name: build
on:
  pull_request:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: "9.0.x"
      - uses: actions/cache@v4
        with:
          path: deps
          key: deps-${{ hashFiles('scripts/fetch-deps.sh') }}
      - run: ./scripts/fetch-deps.sh
      - run: dotnet build -c Release serverside_qol-autofeed.sln
      - run: dotnet test -c Release tests/AutoFeed.Core.Tests
```

`.github/workflows/release.yml`:
```yaml
name: release
on:
  push:
    tags: ["v*"]
permissions:
  contents: write
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: "9.0.x"
      - uses: actions/cache@v4
        with:
          path: deps
          key: deps-${{ hashFiles('scripts/fetch-deps.sh') }}
      - run: ./scripts/fetch-deps.sh
      - run: dotnet test -c Release tests/AutoFeed.Core.Tests
      - run: ./scripts/package.sh "${GITHUB_REF_NAME#v}"
      - uses: softprops/action-gh-release@v2
        with:
          files: ServersideQoL_AutoFeed-*.zip
```

- [ ] **Step 3: Write `README.md` and `CHANGELOG.md`**

`README.md` must contain (prose can vary, content must not):
- What it does: feeds **tamed** animals from containers within `ContainerRange` meters, entirely server-side; vanilla/console clients need nothing.
- Requirements: dedicated server with BepInEx and `ArgusMagnus-ServersideQoL` **2.0.6**.
- Config: file `tayvenb13.ServersideQoL.AutoFeed.cfg`, section `[AutoFeed]`, `Enabled` (default false) and `ContainerRange` (default 10).
- Credits & provenance: idea from [Stephen-Cherry/AutoFeed](https://github.com/Stephen-Cherry/AutoFeed) (no code reused — it is client-side and unlicensed); built on [ArgusMagnus/ValheimServersideQoL](https://github.com/ArgusMagnus/ValheimServersideQoL) (no license file upstream; this module links against its released DLL and exists for personal-server use).

`CHANGELOG.md`:
```markdown
### v0.1.0
- Initial release: server-side auto-feeding of tamed animals from nearby containers.
```

- [ ] **Step 4: Verify packaging locally**

```bash
./scripts/package.sh 0.0.0-local
```
Expected: zip listing shows `manifest.json`, `README.md`, `CHANGELOG.md`, `ServersideQoL.AutoFeed.dll`, `AutoFeed.Core.dll` all at the zip root. Delete the local zip afterwards.

- [ ] **Step 5: Push, watch CI, then tag the release**

```bash
git add -A
git commit -m "feat: packaging script, CI workflows, README"
git push origin main
gh run watch --exit-status   # build workflow on main must pass first
git tag v0.1.0
git push origin v0.1.0
gh run watch --exit-status   # release workflow
```

- [ ] **Step 6: Verify the release asset**

```bash
curl -fsSL -o /tmp/autofeed-check.zip \
  "https://github.com/tayvenb13/serverside_qol-autofeed/releases/download/v0.1.0/ServersideQoL_AutoFeed-0.1.0.zip"
unzip -l /tmp/autofeed-check.zip
```
Expected: HTTP 200 and `manifest.json` at the zip root. This exact URL goes into ansible next.

---

### Task 5: Deploy via ansible (this repo, PR)

**Files (in the chalupa-tech-local worktree, branch `feat/oracle-autofeed`):**
- Modify: `oracle-cloud-server/ansible/roles/valheim/defaults/main.yml` (mods list ~line 70, settings list ~line 114)
- Create: `docs/2026-09-13-oracle-autofeed.md`

**Interfaces:**
- Consumes: the release URL verified in Task 4 Step 6; config file/section/keys produced by Task 3.
- Produces: merged PR → `oracle-deploy.yml` applies the role, installing and enabling the mod on the server.

- [ ] **Step 1: Add the mod to `valheim_mods`**

Append after the `ServersideQoL_MultiplayerTweaks` entry, keeping the existing comment style:
```yaml
  # Our own ServersideQoL module (github.com/tayvenb13/serverside_qol-autofeed):
  # feeds tamed animals from nearby chests, server-side only.
  - name: ServersideQoL_AutoFeed
    team: tayvenb13
    version: "0.1.0"
    url: "https://github.com/tayvenb13/serverside_qol-autofeed/releases/download/v0.1.0/ServersideQoL_AutoFeed-0.1.0.zip"
```

- [ ] **Step 2: Enable it in `valheim_mod_settings`**

Append:
```yaml
  - file: tayvenb13.ServersideQoL.AutoFeed.cfg
    section: AutoFeed
    option: Enabled
    value: "true"
```
(`ContainerRange` stays at its shipped default of 10.)

- [ ] **Step 3: Write `docs/2026-09-13-oracle-autofeed.md`**

Content: what was added (ServersideQoL_AutoFeed 0.1.0, GitHub-release install), why (auto-feed tames from chests with vanilla clients; original AutoFeed mod is client-side and cannot work on a dedicated server), pointer to the spec (`docs/superpowers/specs/2026-09-13-autofeed-serverside-design.md`) and the mod repo, the version-coupling rule (mod is built against SSQoL core 2.0.6 — bump both together), and the PR link (fill in after opening the PR).

- [ ] **Step 4: Lint**

```bash
cd oracle-cloud-server/ansible && ansible-lint
```
Expected: no new findings.

- [ ] **Step 5: Commit, push, open PR**

```bash
git add oracle-cloud-server/ansible/roles/valheim/defaults/main.yml docs/2026-09-13-oracle-autofeed.md
git commit -m "feat(oracle): add ServersideQoL_AutoFeed 0.1.0 (auto-feed tames from chests)"
git push -u origin feat/oracle-autofeed
gh pr create --title "feat(oracle): auto-feed tamed animals from chests (ServersideQoL_AutoFeed)" \
  --body "Adds our own ServersideQoL module built for this: https://github.com/tayvenb13/serverside_qol-autofeed — see docs/2026-09-13-oracle-autofeed.md and the spec/plan in docs/superpowers/."
```
Then backfill the PR link into the docs entry (amend or follow-up commit). Wait for PR checks (oracle.yml lint/plan) to pass. **Merge only with the user's go-ahead.**

---

### Task 6: Live verification (after the PR merges and deploys)

**Files:** none (operational verification).

**Interfaces:**
- Consumes: deployed server over Tailscale (`ssh ubuntu@oracle-server`).

- [ ] **Step 1: Confirm the deploy installed and loaded the plugin**

```bash
ssh ubuntu@oracle-server 'ls /opt/valheim/server/BepInEx/plugins/ | grep -i autofeed'
ssh ubuntu@oracle-server 'grep -i "Enabled = true" /opt/valheim/server/BepInEx/config/tayvenb13.ServersideQoL.AutoFeed.cfg'
ssh ubuntu@oracle-server 'journalctl -u valheim --since "-15 min" | grep -i "ServersideQoL.AutoFeed\|AutoFeed"' 
```
Expected: plugin dir `ServersideQoL_AutoFeed-0.1.0` present; config Enabled true; BepInEx load line for `ServersideQoL.AutoFeed` with no errors. If the config file did not exist before the deploy, ini_file created it pre-start — verify BepInEx kept the `Enabled = true` value after first boot rather than resetting it.

- [ ] **Step 2: In-game behavior test (needs the user or a player online)**

Ask the user to: pen a tamed animal (boar/wolf), place a chest with its food (e.g. carrots for boars) within 10 m, wait for the animal to be hungry, and confirm — with **no client mods** — that (a) the yellow "hungry" status clears, (b) the chest stock decrements, (c) breeding works if two tames are penned.

- [ ] **Step 3: Watch the feed log lines**

```bash
ssh ubuntu@oracle-server 'journalctl -u valheim -f | grep "AutoFeed: fed"'
```
Expected: one line per feeding, roughly once per creature per fed-duration. If lines appear but the animal stays hungry on the client, the ZDO revision trick needs tuning (see spec risk: verify `DataRevision += 120` + `ForceSendZDO` behavior) — debug via superpowers:systematic-debugging, don't guess.

- [ ] **Step 4: Record the outcome**

Add a short "Verified live" note (date + what was observed) to `docs/2026-09-13-oracle-autofeed.md` via a small follow-up PR, or include it in the PR if verification happens pre-merge on a manual deploy.
