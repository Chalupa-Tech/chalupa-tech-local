# Reduce Talos control plane memory: 6 GB → 4 GB

## Summary

Drops `Dedicated` memory on all three Talos control plane VMs (`talos-cp`, `talos-cp-2`, `talos-cp-3`) from 6144 MB to 4096 MB.

## Rationale

Observed steady-state utilization on all three CPs is below 50% of the 6 GB allocation. CPs are tainted and run only the control plane (etcd, kube-apiserver, controller-manager, scheduler, kubelet, Talos services); workloads are pinned to the workers. 4 GB leaves comfortable headroom for etcd and apiserver while returning 6 GB total to the hypervisor for worker / LXC use.

## Rollout

Pulumi in-place VM update. Each CP cold-restarts in turn. The `BootOrders` (`scsi0`, `ide3`, `net0`) set in `pulumi-talos/main.go` ensures the installed disk boots before the attached Talos ISO on cold restart — so a resize does not wedge the node at the installer prompt (see the comment in `main.go` for the failure mode this prevents).

Etcd quorum (2 of 3) is preserved across each rolling restart, so kube-apiserver stays reachable through the VIP at `192.168.1.231` throughout.

## Verification

```
kubectl describe node talos-cp   | grep -A 2 Capacity   # memory: ~4Gi
kubectl describe node talos-cp-2 | grep -A 2 Capacity   # memory: ~4Gi
kubectl describe node talos-cp-3 | grep -A 2 Capacity   # memory: ~4Gi
talosctl --nodes 192.168.1.225 etcd members             # 3 members healthy
kubectl get nodes                                       # all 6 Ready
```
