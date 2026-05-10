# Disable Talos 1.12.0 Userspace OOM Controller

## Summary

Append an `OOMConfig` document to the per-node Talos machine config patch in `pulumi-talos/main.go` that sets `triggerExpression: "false"`, disabling the buggy v1.12.0 userspace OOM controller. The kernel OOM killer remains in effect as the proper backstop.

## Rationale

Talos v1.12 introduced a userspace OOM controller (`runtime.OOMController`) that uses Pressure Stall Information (PSI) to kill cgroups before the kernel OOM killer trips. In v1.12.0 it is buggy: under transient memory pressure (heavy I/O, sandbox creation churn, or a single nested cgroup hitting its own `memory.max`), the global PSI rises and the controller SIGKILLs random burstable pods even when the node has plenty of free RAM. Tracked upstream as [siderolabs/talos#12526](https://github.com/siderolabs/talos/issues/12526) (closed COMPLETED 2026-01-20, fix shipped in v1.12.2).

### Symptoms observed

- `openbao-0` stuck in `CrashLoopBackOff` with exit code 137 and "Pod sandbox changed" events.
- `talosctl dmesg` showed `runtime.OOMController` repeatedly sending SIGKILL to `/sys/fs/cgroup/kubepods/burstable/podc46982bc-…` (openbao-0's cgroup), targeting the `/pause` sandbox process.
- `OOMActions` resource on `talos-worker-1` showed `memory_full_avg10` at 22–31% with a positive derivative, tripping the default trigger `memory_full_avg10 > 12.0 && d_memory_full_avg10 > 0.0`.
- No corresponding kernel OOM events — the node had ample free memory.

### Why this fix

The Talos maintainer ([@laurazard](https://github.com/siderolabs/talos/issues/12526#issuecomment)) confirmed the default trigger expression is "more aggressive than expected" in some workloads and recommended adjusting it. Setting `triggerExpression: "false"` is the cleanest mitigation: it disables the misbehaving userspace early-trigger and falls back to the kernel OOM killer (the pre-1.12 behavior, which has been stable for years on this cluster).

`cgroupRankingExpression` is intentionally left at the default — the maintainer explicitly warned that overriding it to `"0.0"` (a workaround circulating in the community) disables ranking and is unsafe.

This is a temporary workaround. The proper fix is upgrading to Talos v1.12.2+ (latest 1.12.7), which requires updating the Ansible-managed Talos ISO and running `talosctl upgrade` per node. That is a separate, larger change and will land in a follow-up PR. After upgrade, this `OOMConfig` document can be removed.

## Changes

### `pulumi-talos/main.go`
- `buildMachineConfigPatch()` now appends a third YAML document to the per-node config patch:
  ```yaml
  ---
  apiVersion: v1alpha1
  kind: OOMConfig
  triggerExpression: "false"
  ```
- Added an inline comment explaining the workaround, the upstream issue, and that the patch should be removed once Talos is upgraded past v1.12.2.

## Rollout

The change applies via the existing `machine.NewConfigurationApply` resource (`ApplyMode: "reboot"`) for every node. After merge to `main`, the deploy pipeline rolls each node sequentially. Each node reboots once.

## Verification

After rollout:
- `talosctl -n <node> get oomconfig -o yaml` should show `triggerExpression: "false"`.
- `talosctl -n <node> dmesg | grep OOMController` should stop producing events.
- `kubectl get pods -n openbao` should show `openbao-0` Running and Ready.

## References

- [siderolabs/talos#12526](https://github.com/siderolabs/talos/issues/12526) — bug report
- [Talos OOM Handler docs](https://docs.siderolabs.com/talos/v1.12/configure-your-talos-cluster/system-configuration/oom)
