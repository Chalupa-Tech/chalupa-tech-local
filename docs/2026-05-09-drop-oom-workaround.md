# Drop OOMConfig Workaround

## Summary

Remove the `OOMConfig: triggerExpression: "false"` document from the per-node Talos machine config patch in `pulumi-talos/main.go`. The cluster is now on Talos v1.12.7 (rolling upgrade completed today), which contains the upstream fix for the userspace OOM controller bug.

## Rationale

PR #151 added the workaround as an emergency mitigation for [siderolabs/talos#12526](https://github.com/siderolabs/talos/issues/12526), where Talos v1.12.0's default OOM trigger expression was tripping on transient PSI memory pressure and SIGKILLing random burstable pods (specifically `openbao-0`'s sandbox in a tight loop). The fix shipped upstream in v1.12.2.

The cluster has now been rolled to v1.12.7 (PR #152). With the upstream fix in place, the userspace OOM controller's tuned default trigger expression is appropriate again, and disabling it removes a safety net we'd want enabled. The kernel OOM killer remained the backstop in either case, but with the userspace controller restored we get the *intended* behavior — early intervention based on PSI before the kernel-OOM thrashing state.

Verified post-upgrade on every worker:
```
$ talosctl -n <worker> dmesg | grep -c "OOM controller triggered"
0
```

`openbao-0` has been stable on worker-1 since the upgrade completed.

## Changes

### `pulumi-talos/main.go`
- Removed the third YAML document (`apiVersion: v1alpha1` / `kind: OOMConfig` / `triggerExpression: "false"`) from `buildMachineConfigPatch()`.
- Removed the inline comment block about the workaround.

## Rollout

Pulumi runs in CI on merge will regenerate the per-node machine config without the `OOMConfig` document. `machine.NewConfigurationApply` (`ApplyMode: "reboot"`) will reapply each node's config and reboot it once. The default OOM trigger expression takes effect on next boot.
