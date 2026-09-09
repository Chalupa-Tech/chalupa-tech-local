# 2026-09-08 — TrueNAS OOM-killed; Talos workers cut from 20GB to 12GB

**PR:** #299 (fix applied out-of-band first, then codified here)

## What happened

On 2026-09-07 22:23:59 the Proxmox host's OOM killer terminated the TrueNAS
VM's `kvm` process (pid 1780, anon-rss 33.5GB). Every subsequent `qm start 101`
also died with `QEMU exited with code 1` — each attempt was itself OOM-killed
at ~28GB into its 32GB allocation. With TrueNAS down, all NFS-backed workloads
(media stack, Plex library) were dead until recovery on 2026-09-08.

## Root cause

Memory overcommit that finally caught up:

- Provisioned VM RAM totalled **112GB on a 94GB host**:
  3 workers × 20GB + TrueNAS 32GB + HAOS 8GB + 3 CPs × 4GB.
- Every VM runs `balloon: 0`, so the host can never reclaim guest memory.
- Linux guests only *cost* what they touch, which is why this ran for months.
  The 2026-09-07 update wave (~50 Renovate PRs: mass image pulls, pod
  restarts, the Postgres 18 migration) made each worker's guest page cache
  touch nearly its full 20GB. Host RAM exhausted, swap filled (7/7GB),
  load hit 45, and the OOM killer picked the largest process — TrueNAS.
- TrueNAS could then never restart: its HBA passthrough (VFIO) requires the
  full 32GB pinned up front, and only 27GB was available.

Not related to the pulumi-proxmoxve v8 migration (#297): VM 101's config was
untouched since May, and the first OOM fired 7 minutes before that PR merged.

## Fix

- Workers reduced **20GB → 12GB** (`pulumi-talos/main.go`). Measured active
  pod usage per worker is ~3–4GB (`kubectl top nodes`: 12–22% of 20GB), so
  12GB still leaves ~3x headroom. Fleet total drops 112GB → **88GB**, which
  fits under 94GB physical with room for the host.
- Recovery sequence (manual, 2026-09-08): power-cycled workers one at a time
  (full `qm stop`/`qm start` — an in-guest reboot does **not** release host
  RSS; the QEMU process must restart), applying `qm set --memory 12288`
  while stopped, waiting for the node to rejoin Ready before the next.
  Then started TrueNAS with 68GB available.
- Note: `qm shutdown` / `talosctl shutdown` both hung because kubelet could
  not unmount the dead NFS volumes; hard `qm stop` was required. Talos and
  CNPG Postgres are crash-safe, and a verified `pg_dumpall` backup existed
  (`~/backups/arrs-pg/arrs-pg-dumpall-20260907-2213.sql.gz`).

## Guardrails going forward

- **Do not raise worker memory above 12GB** (or add RAM-hungry VMs) without
  re-summing fleet-provisioned RAM against the 94GB host. With `balloon: 0`
  everywhere, provisioned ≈ eventual real usage; overcommit is a time bomb
  because the TrueNAS VFIO pin makes it the OOM killer's preferred victim.
- Candidate follow-up: vmalert rule on host `node_memory_MemAvailable_bytes`
  dropping below ~40GB (TrueNAS pin + margin), same alerting gap noted for
  sealed OpenBao in `docs/2026-09-07-fix-renovate-never-ran.md`.
