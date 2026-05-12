# Reduce Talos control plane memory: 6 GB → 4 GB

## Summary

Drops `Dedicated` memory on all three Talos control plane VMs (`talos-cp`, `talos-cp-2`, `talos-cp-3`) from 6144 MB to 4096 MB.

## Rationale

Observed steady-state utilization on all three CPs is below 50% of the 6 GB allocation. CPs are tainted and run only the control plane (etcd, kube-apiserver, controller-manager, scheduler, kubelet, Talos services); workloads are pinned to the workers. 4 GB leaves comfortable headroom for etcd and apiserver while returning 6 GB total to the hypervisor for worker / LXC use.

## Rollout sequence

A Pulumi memory change on a VM is a stop / update / start. The three CPs have no Pulumi `DependsOn` between them, so a single PR that resizes all three would resize them in parallel — etcd quorum (2 of 3) cannot survive all three CPs cold-restarting simultaneously. Splitting into three PRs serializes the resizes across separate CI runs and gives a verification gate between each.

1. **PR 1** — Resize `talos-cp` (192.168.1.225, VMID 300) to 4 GB. Etcd quorum maintained by `talos-cp-2` + `talos-cp-3`. Workers and VIP traffic unaffected.
2. **PR 2** — Resize `talos-cp-2` (192.168.1.228, VMID 304) to 4 GB. Etcd quorum maintained by `talos-cp` + `talos-cp-3`.
3. **PR 3** — Resize `talos-cp-3` (192.168.1.229, VMID 305) to 4 GB. Etcd quorum maintained by `talos-cp` + `talos-cp-2`. Also updates `CLAUDE.md` to reflect the final 4 GB allocation across all CPs.

The `BootOrders` (`scsi0`, `ide3`, `net0`) set in `pulumi-talos/main.go` ensures the installed disk boots before the attached Talos ISO on cold restart — so a resize does not wedge the node at the installer prompt (see the comment in `main.go` for the failure mode this prevents).

## Verification (per PR)

After each PR merges and CI completes:

```
kubectl describe node <resized-cp> | grep -A 2 Capacity   # memory: ~4Gi
talosctl --nodes 192.168.1.225 etcd members               # 3 members, all healthy
kubectl get nodes                                         # all 6 Ready
```

Only proceed to the next PR after the previous CP is back to `Ready` and etcd reports 3 healthy members.
