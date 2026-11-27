# Alert on restart-looping pods (KubePodCrashLooping)

**Date:** 2026-11-27
**PR:** _pending_

## What

Added a `KubePodCrashLooping` alert to the `cluster-health` VMRule
(`gitops/apps/observability/vmalert/templates/rules/cluster-health.yaml`).
It is `severity: warning` and goes to Discord through the existing
vmalert → Home Assistant bridge.

```promql
max by (namespace, pod, container) (increase(kube_pod_container_status_restarts_total[30m])) >= 1
  or
max by (namespace, pod, container) (increase(kube_pod_init_container_status_restarts_total[30m])) >= 1
```

with `for: 2h`. In plain terms, the alert fires when a container or init
container restarted at least once in every 30-minute window for 2 hours.

## Why

Sonarr restarted 690 times over 5 days and nothing alerted on it (see
`2026-11-27-sonarr-allowed-hosts.md`, PR #490). Scraparr's `wait-for-sonarr`
init container was stuck in a loop the whole time as well.

## Design choices

- **Restarts, not the `CrashLoopBackOff` reason.** Sonarr was killed by a
  failing startup probe and spent most of each cycle in `Running`. Over 14 days,
  kube-state-metrics never recorded it in `CrashLoopBackOff`, so a rule on
  `kube_pod_container_status_waiting_reason` would have missed it.
- **Sustained, not a count.** A rule like "≥3 restarts in 1h" would have fired
  on node reboots. flannel, kube-proxy, metallb and others each logged bursts of
  up to 4 restarts in the last 14 days. A burst only keeps the 30m window true
  for about 30 minutes, which is not long enough to satisfy `for: 2h`.
- **Init containers included,** so dependency-wait loops like Scraparr's are
  caught too.
- **Limitation:** a container that restarts less often than every 30 minutes
  will not trigger this alert.

## Backtest (14 days, 5-minute steps, all 24 samples in a 2h window true)

| Matches | Notes |
|---|---|
| `media/sonarr-*` `main` (3 pod generations) | the real incident |
| `media/scraparr-*` `wait-for-sonarr` (3 pod generations) | caused by Sonarr |

There were no other matches. All the node-reboot restart bursts were excluded.
