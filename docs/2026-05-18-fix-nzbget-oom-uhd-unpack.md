# 2026-05-18: Fix nzbget OOM Crashloop on UHD BluRay Post-Process

## Overview

The `nzbget` pod in `media` had been in `CrashLoopBackOff` for the
better part of an hour by the time it was looked at — 6 restarts in
58 minutes, each one ending in `OOMKilled` within seconds of the
container starting:

```
$ kubectl -n media describe pod nzbget-bb644d7bd-4t8ll
    State:          Waiting        Reason: CrashLoopBackOff
    Last State:     Terminated     Reason: OOMKilled    Exit Code: 137
      Started:  Mon, 18 May 2026 14:36:00 -0600
      Finished: Mon, 18 May 2026 14:36:24 -0600
    Limits:   memory: 2Gi
    Restart Count: 6
```

24 seconds from container start to kill. Far too fast to be a slow
leak — the workload was breaching 2 Gi essentially on startup.

## Root cause

Logs from the killed container told the whole story:

```
$ kubectl -n media logs nzbget-bb644d7bd-4t8ll --previous --tail=80
  Linuxserver.io version: v26.1-ls241
  [INFO] nzbget 26.1 server-mode
  [INFO] Unpacking Smile.2.2024.2160p.UHD.BluRay.TrueHD.7.1.HDR.DV.x265-SPHD
  [INFO] Unrar: Extracting from xTqRGh9EY9zNRdy04.part001.rar
  …part005.rar
  # OOM
```

Every single restart logged the identical `Unpacking …` line. nzbget
persists its post-process queue to `/config/queue/` on the NFS PVC, so
on every container start it resumed the same job — a 2160p UHD BluRay
rip in the 60–80 GB range. unrar of a multipart UHD archive, layered
on top of nzbget's article cache and write buffers, blew past the 2 Gi
cgroup cap before the unpack even finished. kubelet restarted the
container, nzbget restarted, resumed the same job from disk, OOMed
again. A wedge on one queue item, not a leak.

Three contributing factors made the wedge worse than it had to be:

1. **2 Gi memory limit was undersized for UHD post-processing.** The
   limit had already been bumped once
   (PR [#136](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/136))
   from the chart default. Community guidance for nzbget unpacking
   2160p content lands around 4–8 Gi. Worker nodes have 20 Gi
   allocatable, so headroom was not the problem.

2. **`image: lscr.io/linuxserver/nzbget:latest`** was unpinned. A
   silent upstream rebuild between scrapes can change behaviour with
   no diff in the chart — same class of latent risk we have hit
   before (see the auto-memory entry *verify-image-tag-on-registry*).

3. **Liveness probe was tight** — `tcpSocket :6789, period=30s,
   failure=3` (default `failureThreshold`) → roughly 90 s of API
   silence and the container is killed. During heavy par2 verification
   or large-archive unrar, nzbget's API thread can stall briefly.
   That likely explains the `Liveness probe failed: connection
   refused` event ~20 min into the loop.

## Fix

Single PR, single file change.

`gitops/apps/media/nzbget/values.yaml`:

- `resources.limits.memory`: 2Gi → **4Gi**
- `resources.requests.memory`: 2Gi → **4Gi** (kept equal to the limit
  so the pod stays in **Guaranteed** QoS — eligible last for eviction
  under node memory pressure; worker has 20 Gi allocatable so the
  reservation is not a scheduling concern)
- `image.tag`: `latest` → **v26.1-ls241** (the build the container
  was actually running per the `[ls.io-init]` banner — pinning to
  the known-good current state)
- `probes.liveness.spec`: add `timeoutSeconds: 5` and
  `failureThreshold: 10` so a brief par2/unrar stall does not kill
  the container mid-job (~5 min tolerance instead of ~90 s)

Before deploying, the wedged queue item was deleted from the nzbget
UI manually, so the next pod boot starts clean rather than re-loading
the same OOM trigger.

## Why this is the right size of fix

A second replica is not an option — nzbget keeps its queue and SQLite
state on a single NFS PVC with no `ReadWriteMany`-safe locking, so
adding replicas would corrupt state, not spread load.

Moving `/downloads` to its own PVC was considered and rejected: NFS
isn't where the memory went, unrar buffering is. Splitting the PVC
buys nothing for this failure mode.

## Out of scope (deliberate)

nzbget's own memory-shaping knobs live in `/config/nzbget.conf`
on the NFS PVC, and nzbget rewrites that file itself on every UI
change — templating it from the chart would fight the app. These are
being set in the web UI separately:

| Setting        | Value      | Why                                          |
|----------------|------------|----------------------------------------------|
| `ArticleCache` | `500` (MB) | Cap download cache so it can't fight unpack  |
| `WriteBuffer`  | `1024` (KB)| Per-file write buffer; sane default          |
| `DirectUnpack` | `no`       | **Biggest single win** — no concurrent dl+unrar |
| `ParBuffer`    | `256` (MB) | Cap par2 verification memory                 |
| `PostStrategy` | `Sequential` | One post-process at a time                 |
| `DiskSpace`    | `5000` (MB)| Stop accepting downloads if NFS share runs low |

These are documented here rather than in the chart because they live
outside this repo's source of truth on purpose.

## Verification

After the PR merges and ArgoCD syncs:

- `kubectl -n media get pod -l app.kubernetes.io/name=nzbget` shows
  1/1 Running, no restarts climbing.
- `kubectl -n media describe pod` shows `Limits: memory: 4Gi` and
  image tag `v26.1-ls241`.
- A subsequent UHD post-process completes — queue drains, no OOM
  events under `kubectl -n media get events`.
- Grafana:
  `container_memory_working_set_bytes{namespace="media",pod=~"nzbget-.*"}`
  peak stays under 3.5 Gi.

## PR

[#207](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/207)
