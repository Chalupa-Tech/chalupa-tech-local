# Talos HA control plane + VIP migration

## Summary

Converts the single-CP Talos cluster into a 3-node HA control plane sharing a Talos built-in VIP at `192.168.1.231`. Resizes the original CP from 4c/20GB to 2c/6GB. Adds `talos-worker-3` for capacity.

## Rationale

The original CP was a SPOF and oversized (tainted, runs no workloads). Three 2c/6GB CPs give etcd quorum, survive a node loss, and free hypervisor resources for actual workloads.

## Rollout sequence

1. **PR 1** — Refactor talosNode for per-node CPU/memory (no functional change).
2. **PR 2** — Add talos-cp-2 and talos-cp-3 at 2c/6GB joining the existing single-CP cluster via the .225 endpoint. Lifts cluster to 3-CP HA etcd. No disruption.
3. **PR 3** — Introduce VIP (`192.168.1.231`) on all CPs; switch `clusterEndpoint`, kubeconfig, and talosconfig endpoints to VIP. Triggers config re-apply on every node. With 3-CP etcd HA, kube-apiserver stays up. Workers reboot, ~30–90 s of pod-level downtime per worker.
4. **PR 4** — Resize original `talos-cp` from 4c/20GB to 2c/6GB. Pulumi in-place VM update. Etcd quorum (2 of 3) preserved during reboot.
5. **PR 5** — Add `talos-worker-3` at 192.168.1.232 / VMID 303. Pure addition.

## Verification (per PR)

After PR 2:
```
kubectl get nodes  # 5 Ready
talosctl --nodes 192.168.1.225 etcd members  # 3 members
```

After PR 3:
```
kubectl cluster-info  # endpoint = https://192.168.1.231:6443
ip neigh show 192.168.1.231  # MAC matches one of the 3 CPs
# Failure test (optional): talosctl reboot the VIP holder; kubectl access should reconnect within seconds.
```

After PR 4:
```
kubectl describe node talos-cp | grep -A 5 Capacity  # cpu: 2, memory: ~6Gi
```

After PR 5:
```
kubectl get nodes  # 6 Ready, including talos-worker-3
```
