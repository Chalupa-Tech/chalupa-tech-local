# 2026-06-21: Add Prowlarr (indexer manager)

## Overview

Deploy Prowlarr to the Talos cluster as `prowlarr.frame.chalupatech.com`.
Prowlarr is the *arr-family **indexer manager**: it centralizes Torznab/Newznab
indexer definitions and syncs them (and indexer/app pairings) to Sonarr and
Radarr over their APIs, so indexers are configured once instead of per-app. It
completes the existing Sonarr/Radarr/Seerr media stack.

Prowlarr runs against the shared **CloudNativePG `arrs-pg`** Postgres cluster
(same backend as Sonarr/Radarr/Seerr), not SQLite — keeping the *arr apps
uniform. Per the [Roxedus Postgres-for-arr guide][roxedus], Prowlarr uses two
databases (`prowlarr_main` + `prowlarr_log`) under a single `prowlarr` role.

[roxedus]: https://gist.github.com/Roxedus/fb04446c96f38d77a066b9a9a4911b48

## What changed

- **`gitops/apps/media/prowlarr/`** — new bjw-s `app-template` 4.4.0 wrapper,
  identical in shape to `radarr/`:
  - Image `lscr.io/linuxserver/prowlarr:2.4.0.5397-ls150` (pinned; never
    `:latest`; Renovate tracks `lscr.io/linuxserver/*` automatically).
  - Web port **9696** (service, probes on `/ping`, both IngressRoutes).
  - `Prowlarr__Postgres__*` env wired from the `prowlarr-pg` secret
    (host `arrs-pg-rw.media.svc.cluster.local`).
  - **Config-only** persistence on the shared `media-plexmedia` NFS PVC at
    `/config` (subPath `Configs/prowlarr`). Prowlarr is an indexer manager —
    it does not touch the movie/TV library or downloads, so no media mounts.
  - Two Traefik IngressRoutes (`prowlarr-http` → redirect, `prowlarr-https`)
    for `prowlarr.frame.chalupatech.com`, external-dns target `192.168.1.230`,
    referencing the shared `redirect-to-https` middleware in `media`.
- **`gitops/apps/media/arrs-pg/templates/cluster.yaml`** —
  - `managed.roles`: added the `prowlarr` role (passwordSecret `prowlarr-pg`).
    This is reconciled on the **live** cluster, so it creates the role.
  - `postInitApplicationSQL`: added the `prowlarr` role + `prowlarr_main` /
    `prowlarr_log` databases + grants. This only runs on a **future clean
    cluster rebuild** (CNPG runs it once at initdb); it does nothing to the
    already-running cluster — see the runbook for the one-time live step.
- **`gitops/apps/media/arrs-pg/templates/prowlarr-externalsecret.yaml`** — new
  ExternalSecret materializing `prowlarr-pg` (username/password/main_db/log_db)
  from OpenBao `postgres/prowlarr` via the `openbao` ClusterSecretStore,
  `sync-wave: "-1"` so creds exist before the role/workload.

The `media-apps` ApplicationSet (`gitops/bootstrap/applicationsets/media.yaml`,
`directories.path: gitops/apps/media/*`) auto-discovers the new directory — no
registration change. The `media-read` OpenBao policy already grants
`secret/data/postgres/*`, so no policy edit is needed. Renovate already covers
the image and the `app-template` dependency.

## Why a one-time manual DB step is needed

`arrs-pg` is already bootstrapped. CNPG runs `postInitApplicationSQL` **only at
the cluster's original initdb**, so adding lines there does not create databases
on the live cluster — it only matters for a future rebuild. `managed.roles` is
reconciled continuously and *does* create the `prowlarr` role live, but the two
databases must be created once by hand (runbook step 4). This matches the repo's
established "post-merge operator runbook" pattern (cf. OpenBao init, Tautulli
API key).

## Operator runbook (post-merge — order matters)

1. **Seed OpenBao** (generate a strong password):
   ```bash
   OPENBAO_TOKEN=$(jq -r '.root_token' ~/secure/openbao-init.json) \
     ./scripts/openbao/kv-put.sh postgres/prowlarr \
       username=prowlarr password="$(openssl rand -base64 24)" \
       main_db=prowlarr_main log_db=prowlarr_log
   ```
2. **Merge the PR.** ArgoCD creates the `prowlarr` Application; ESO syncs
   `prowlarr-pg`; CNPG `managed.roles` creates the `prowlarr` role with that
   password. (The pod will fail to connect until step 4 creates the DBs.)
3. **Force the ExternalSecret** to sync now instead of waiting up to 1h:
   ```bash
   kubectl -n media annotate externalsecret prowlarr-pg-creds \
     force-sync=$(date +%s) --overwrite
   ```
4. **Create the two databases on the live cluster** (one-time; the role already
   exists via `managed.roles`):
   ```bash
   PRIMARY=$(kubectl -n media get pods \
     -l cnpg.io/cluster=arrs-pg,cnpg.io/instanceRole=primary -o name)
   kubectl -n media exec -it "$PRIMARY" -- psql -U postgres -c \
     "CREATE DATABASE prowlarr_main OWNER prowlarr;"
   kubectl -n media exec -it "$PRIMARY" -- psql -U postgres -c \
     "CREATE DATABASE prowlarr_log OWNER prowlarr;"
   ```
5. **Restart Prowlarr** so it retries the DB connection:
   ```bash
   kubectl -n media rollout restart deploy/prowlarr
   ```
6. **First-run UI config** at `https://prowlarr.frame.chalupatech.com`: set
   admin auth, add Indexers, then **Settings → Apps** → add Sonarr & Radarr
   (URL `http://sonarr:8989` / `http://radarr:7878`, paste each app's API key)
   so Prowlarr syncs indexers to them.

## Verification

- `kubectl -n argocd get application prowlarr` → `Synced/Healthy`.
- `kubectl -n media get pods -l app.kubernetes.io/name=prowlarr` → `1/1 Ready`.
- `kubectl -n media get externalsecret prowlarr-pg-creds` → `SecretSynced`.
- DBs exist:
  `kubectl -n media exec -it "$PRIMARY" -- psql -U postgres -c "\l" | grep prowlarr`.
- `kubectl -n media logs deploy/prowlarr | grep -i postgres` → connects to
  Postgres (no SQLite fallback, no auth error).
- `curl -I https://prowlarr.frame.chalupatech.com/ping` → `HTTP/2 200` from LAN.
- Prowlarr UI **System → Status** → Database type **PostgreSQL**.

## Risks / known limitations

- The live-cluster `CREATE DATABASE` step (runbook step 4) is manual and easy to
  forget; until it runs, the Prowlarr pod CrashLoops/!Ready with a Postgres
  connection error. By design — the alternative (placeholder DBs in Git) is
  worse.
- Prowlarr's config (config.xml, backups) lives on NFS; the DB lives in
  Postgres, so the SQLite-over-NFS concern that applies to Tautulli does not
  apply here.

## Links

- PR: #239 (<https://github.com/Chalupa-Tech/chalupa-tech-local/pull/239>)
- Postgres-for-arr reference: <https://gist.github.com/Roxedus/fb04446c96f38d77a066b9a9a4911b48>
- Sibling app precedent: `docs/2026-05-18-add-tautulli.md`
