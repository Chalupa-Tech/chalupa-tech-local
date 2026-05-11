# Whisparr — Design

**Date:** 2026-05-11
**Status:** Draft (pending user approval)
**Sub-project:** Follow-on to #3 (media stack)

## Context

The media tier currently runs Sonarr, Radarr, Seerr, NzbGet, Tdarr, Clonarr, and the shared `arrs-pg` CNPG Postgres cluster under `gitops/apps/media/`. All apps land in the `media` namespace via the `media-apps` ApplicationSet (`gitops/bootstrap/applicationsets/media.yaml`) and are exposed at `<name>.frame.chalupatech.com` over HTTPS through Traefik + the wildcard cert.

This spec adds **[Whisparr](https://github.com/Whisparr/Whisparr)** (v3 / "Eros" branch) as a seventh media app. Whisparr is a Radarr fork tailored for adult scene-based content. Functionally it is the closest sibling to Radarr in the stack — same .NET codebase, same Postgres back end, same Servarr API shape — so the wrapper chart inherits radarr's shape directly.

Because of the private nature of the content, the operator has provisioned a **dedicated TrueNAS NFS share at `PlexMedia/WhispArr`** (exported as `192.168.1.40:/mnt/PlexMedia/WhispArr`). This share is separate from the existing `PlexMedia/frame` share that backs the rest of the media tier. Whisparr's configuration and media library will live exclusively on this private share; the existing `media-plexmedia` PVC is **not** mounted into Whisparr.

## Goals

- Run Whisparr in the existing `media` namespace on the Talos cluster.
- Use bjw-s `app-template` 4.4.0, matching the rest of the media tier.
- Persist `/config` and `/media` on a **new** dedicated `media-whisparr` NFS PVC backed by the private TrueNAS share at `192.168.1.40:/mnt/PlexMedia/WhispArr`. The shared `media-plexmedia` PVC is intentionally not mounted.
- Use the shared `arrs-pg` CNPG Postgres cluster for state — new `whisparr` role + `whisparr_main` and `whisparr_log` databases, credentials sourced from OpenBao via ExternalSecret.
- Expose at `whisparr.frame.chalupatech.com` over HTTPS using the existing wildcard cert, external-dns target annotation, and shared `redirect-to-https` Middleware.

## Non-goals (explicitly out of scope)

- **Download-client wiring.** Whisparr is deployed without a configured download client. NzbGet currently has only `media-plexmedia` mounted; pointing Whisparr at the shared `Downloads/` path inside `media-plexmedia` would defeat the privacy isolation that motivated the dedicated share. The operator will make the download-client decision in a follow-on PR (options: mount `media-whisparr` into NzbGet under a new category-specific path, or deploy a dedicated downloader). Whisparr starts up healthy and reachable without this; only the import pipeline waits.
- **Tagging / quality profiles / indexers / sync from Clonarr.** Operator setup via the Whisparr Settings UI post-deploy. Clonarr does not target Whisparr (it only syncs to Radarr + Sonarr), so no Clonarr changes.
- **ServiceMonitor / Prometheus metrics.** Whisparr exposes basic metrics endpoints, but observability for the arrs is a separate sub-project. No metrics added here.
- **OIDC / SSO.** Whisparr uses its own forms-based auth; operator creates an admin account on first visit.
- **Renovate / image automation.** Manual chart and image bumps via PR, matching the rest of the stack.
- **Dedicated namespace / PSA elevation.** Whisparr is non-root, no privileged capabilities, no hostNetwork. Reuses the `media` namespace and baseline PSA, same as radarr/sonarr.
- **Migration of any existing Whisparr SQLite state.** This is a fresh install. No pgloader (per memory: `feedback_pgloader_servarr_incompatible.md`). The operator starts Whisparr clean and re-adds quality profiles / indexers via the UI.

## Architecture

### Tiering

No new tier. The wrapper chart lands at `gitops/apps/media/whisparr/` and the existing `media-apps` ApplicationSet picks it up automatically via its `directories.path: gitops/apps/media/*` generator. The `arrs-pg` ExternalSecret/role/database additions sit in the existing `arrs-pg` wrapper at `gitops/apps/media/arrs-pg/`.

### Wrapper-chart shape

The chart mirrors `gitops/apps/media/radarr/` — closest sibling because Whisparr is a Radarr fork with the same env-var convention (`Whisparr__Postgres__*` ↔ `Radarr__Postgres__*`), the same `/ping` health endpoint, and the same single-controller / single-Service shape.

```
gitops/apps/media/whisparr/        NEW
├── Chart.yaml          # depends on app-template 4.4.0
├── Chart.lock          # committed (matches convention)
├── .helmignore
├── charts/             # vendored app-template-4.4.0.tgz (matches convention)
├── values.yaml
└── templates/
    ├── pv-whisparr.yaml         # NEW dedicated NFS PV
    ├── pvc-whisparr.yaml        # NEW dedicated NFS PVC
    └── ingressroute.yaml        # web + websecure pair
```

The PV/PVC pair lives **inside the whisparr wrapper chart**, not the nzbget wrapper. Rationale: ownership is 1:1 with the consuming app (no other app needs this private share), so co-locating the storage manifest with the consumer matches the natural blast radius — destroying the whisparr Application also reclaims the PV (Retain policy preserves data; `kubectl delete pv` is still operator-triggered).

### Image and tag

`ghcr.io/hotio/whisparr:v3-v3.3.3` — the `v3-v3.3.3` tag is the current pinned-release flavor of hotio's v3 ("Eros") branch. The floating `:v3` tag would also work but contradicts the project memory `feedback_verify_image_tag_on_registry` (no inferring; pin a verified tag).

**Pre-implementation verification:** the implementer probes the GHCR manifest for `ghcr.io/hotio/whisparr:v3-v3.3.3` (or the current latest pinned `v3-v3.x.y` flavor) and updates the chart with whatever is current at PR time. The hotio image is multi-arch (amd64 + arm64) — only amd64 matters for the Talos workers.

Note: LSIO does not publish a `linuxserver/whisparr` image (request thread on `discourse.linuxserver.io` was never fulfilled). The hotio image is the de-facto stable container for Whisparr and is already a trusted source pattern in the homelab community.

### values.yaml details

```yaml
app-template:
  defaultPodOptions:
    securityContext:
      runAsNonRoot: false
      fsGroup: 568
      fsGroupChangePolicy: OnRootMismatch

  controllers:
    whisparr:
      type: deployment
      replicas: 1
      strategy: Recreate
      containers:
        main:
          image:
            repository: ghcr.io/hotio/whisparr
            tag: v3-v3.3.3            # verify on registry before PR (see Image and tag)
          env:
            TZ: America/Los_Angeles
            PUID: "1000"
            PGID: "1000"
            Whisparr__Postgres__Host: arrs-pg-rw.media.svc.cluster.local
            Whisparr__Postgres__Port: "5432"
            Whisparr__Postgres__User:
              valueFrom:
                secretKeyRef:
                  name: whisparr-pg
                  key: username
            Whisparr__Postgres__Password:
              valueFrom:
                secretKeyRef:
                  name: whisparr-pg
                  key: password
            Whisparr__Postgres__MainDb:
              valueFrom:
                secretKeyRef:
                  name: whisparr-pg
                  key: main_db
            Whisparr__Postgres__LogDb:
              valueFrom:
                secretKeyRef:
                  name: whisparr-pg
                  key: log_db
          probes:
            liveness:
              enabled: true
              custom: true
              spec:
                httpGet:
                  path: /ping
                  port: 6969
                initialDelaySeconds: 30
                periodSeconds: 30
                timeoutSeconds: 10
                failureThreshold: 5
            readiness:
              enabled: true
              custom: true
              spec:
                httpGet:
                  path: /ping
                  port: 6969
                initialDelaySeconds: 5
                periodSeconds: 10
                timeoutSeconds: 5
                failureThreshold: 5
            startup:
              enabled: true
              custom: true
              spec:
                httpGet:
                  path: /ping
                  port: 6969
                initialDelaySeconds: 30
                periodSeconds: 10
                timeoutSeconds: 5
                failureThreshold: 60
          resources:
            requests:
              cpu: 50m
              memory: 256Mi
            limits:
              memory: 2Gi

  service:
    whisparr:
      controller: whisparr
      ports:
        http:
          port: 6969

  persistence:
    config:
      enabled: true
      type: persistentVolumeClaim
      existingClaim: media-whisparr
      globalMounts:
        - path: /config
          subPath: Configs/whisparr
    media:
      enabled: true
      type: persistentVolumeClaim
      existingClaim: media-whisparr
      globalMounts:
        - path: /media
          subPath: Media
    downloads:
      enabled: true
      type: persistentVolumeClaim
      existingClaim: media-whisparr
      globalMounts:
        - path: /downloads
          subPath: Downloads
```

Notes on field choices:

- **`runAsNonRoot: false` + `fsGroup: 568`** matches every other media wrapper. The hotio image uses `gosu` to drop to PUID:PGID after start, so the container needs to begin as root.
- **`PUID/PGID: "1000"`** matches the rest of the media tier. NFS Maproot=root on TrueNAS squashes the in-pod UID anyway; kept for behavioral consistency.
- **`/ping` probe path**, port `6969` — Whisparr's built-in health endpoint (inherited from the Radarr/Servarr lineage), returns `200` when the web UI is up and the SQLite-compat layer has finished initializing against Postgres.
- **`Whisparr__Postgres__*` env var pairs** mirror Radarr's. The Servarr config provider is case-insensitive when binding from env, but we use the existing CamelCase pattern for visual consistency across the tier (`grep -r "Postgres__" gitops/apps/media/` returns a uniform set).
- **Three persistence mounts on the same private PVC, with distinct subPaths.** `Configs/whisparr` keeps state isolated from Whisparr's own `Media/`; `Downloads/` is reserved for the eventual download-client integration (writes nothing until that follow-on lands).
- **No `WHISPARR__SERVER__URLBASE`.** We're using subdomain hosting (`whisparr.frame.chalupatech.com`), not subpath. Default (empty `UrlBase`) is correct.
- **Resource bounds** match radarr/sonarr. Whisparr v3 is roughly the same memory profile as Radarr.

### Storage — new private NFS share

A **new dedicated PV/PVC pair** at `gitops/apps/media/whisparr/templates/pv-whisparr.yaml` and `pvc-whisparr.yaml`, mirroring the static-NFS pattern in `gitops/apps/media/nzbget/templates/pv-plexmedia.yaml`:

```yaml
# pv-whisparr.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media-whisparr
  labels:
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/part-of: media-stack
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  capacity:
    storage: 10Ti                  # advisory only for static NFS; matches sibling pattern
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions:
    - nfsvers=4
    - soft
    - timeo=150
    - retrans=5
  nfs:
    server: 192.168.1.40
    path: /mnt/PlexMedia/WhispArr
  claimRef:
    namespace: media
    name: media-whisparr
```

```yaml
# pvc-whisparr.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media-whisparr
  namespace: media
  labels:
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/part-of: media-stack
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Ti
  storageClassName: ""
  volumeName: media-whisparr
```

NFS mount options, capacity, access mode, reclaim policy, and storage class are all carried over verbatim from the existing pattern. Sync-wave `-2/-1` ensures the PV/PVC bind before the Deployment in wave `0`.

**Subdirectories on the TrueNAS share** must exist before the pod starts (bjw-s `subPath` mounts require the path to exist):
- `/mnt/PlexMedia/WhispArr/Configs/whisparr/`
- `/mnt/PlexMedia/WhispArr/Media/`
- `/mnt/PlexMedia/WhispArr/Downloads/` (placeholder for follow-on; can be empty)

These are created as part of Task 1 (pre-merge operator runbook).

### `arrs-pg` cluster additions

The shared CNPG Postgres cluster gains a `whisparr` role and two databases. Three files change in `gitops/apps/media/arrs-pg/`:

**`templates/cluster.yaml`** — add `CREATE ROLE`/`CREATE DATABASE`/`GRANT` lines to `bootstrap.initdb.postInitApplicationSQL`, and add a `whisparr` entry to `managed.roles`:

```yaml
  bootstrap:
    initdb:
      database: app
      owner: app
      postInitApplicationSQL:
        - CREATE ROLE sonarr WITH LOGIN;
        - CREATE ROLE radarr WITH LOGIN;
        - CREATE ROLE seerr WITH LOGIN;
        - CREATE ROLE whisparr WITH LOGIN;                          # NEW
        - CREATE DATABASE sonarr_main OWNER sonarr;
        - CREATE DATABASE sonarr_log OWNER sonarr;
        - CREATE DATABASE radarr_main OWNER radarr;
        - CREATE DATABASE radarr_log OWNER radarr;
        - CREATE DATABASE seerr OWNER seerr;
        - CREATE DATABASE whisparr_main OWNER whisparr;             # NEW
        - CREATE DATABASE whisparr_log OWNER whisparr;              # NEW
        - GRANT ALL PRIVILEGES ON DATABASE sonarr_main TO sonarr;
        - GRANT ALL PRIVILEGES ON DATABASE sonarr_log TO sonarr;
        - GRANT ALL PRIVILEGES ON DATABASE radarr_main TO radarr;
        - GRANT ALL PRIVILEGES ON DATABASE radarr_log TO radarr;
        - GRANT ALL PRIVILEGES ON DATABASE seerr TO seerr;
        - GRANT ALL PRIVILEGES ON DATABASE whisparr_main TO whisparr;   # NEW
        - GRANT ALL PRIVILEGES ON DATABASE whisparr_log TO whisparr;    # NEW

  managed:
    roles:
      - name: sonarr
        # ... existing ...
      - name: radarr
        # ... existing ...
      - name: seerr
        # ... existing ...
      - name: whisparr                                              # NEW
        ensure: present
        login: true
        passwordSecret:
          name: whisparr-pg
        connectionLimit: 25
```

**Important — the `postInitApplicationSQL` block only runs once at initial bootstrap.** The cluster has long since bootstrapped, so editing those lines is documentation-only (preserves the spec for any future rebuild). The actual role + databases must be created against the live cluster. Two paths:

1. **CNPG-managed role for `whisparr`** — automatic. Adding the new `managed.roles` entry causes CNPG to `CREATE ROLE whisparr` on next reconcile and sync the password from the `whisparr-pg` secret. No operator action needed for the role.
2. **Databases** — CNPG's `managed.roles` does **not** create databases. The operator runs `CREATE DATABASE whisparr_main OWNER whisparr; CREATE DATABASE whisparr_log OWNER whisparr; GRANT ALL PRIVILEGES ON DATABASE whisparr_main TO whisparr; GRANT ALL PRIVILEGES ON DATABASE whisparr_log TO whisparr;` against the cluster primary via `kubectl exec`. This is Task 4 in the implementation plan.

**`templates/whisparr-externalsecret.yaml`** — new file, mirrors `radarr-externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: whisparr-pg-creds
  namespace: media
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: whisparr-pg
    creationPolicy: Owner
    template:
      type: kubernetes.io/basic-auth
      data:
        username: "{{ `{{ .username }}` }}"
        password: "{{ `{{ .password }}` }}"
        main_db: "{{ `{{ .main_db }}` }}"
        log_db: "{{ `{{ .log_db }}` }}"
  data:
    - secretKey: username
      remoteRef:
        key: postgres/whisparr
        property: username
    - secretKey: password
      remoteRef:
        key: postgres/whisparr
        property: password
    - secretKey: main_db
      remoteRef:
        key: postgres/whisparr
        property: main_db
    - secretKey: log_db
      remoteRef:
        key: postgres/whisparr
        property: log_db
```

**`Chart.yaml`** description — update the docstring line that enumerates app users / databases so it stays accurate ("four application users (sonarr, radarr, seerr, whisparr) and seven databases ...").

### OpenBao secret — operator pre-merge step

A new KV-v2 entry at `postgres/whisparr` with four properties:

| Property | Value |
|---|---|
| `username` | `whisparr` |
| `password` | random 32-char passphrase (operator generates) |
| `main_db` | `whisparr_main` |
| `log_db` | `whisparr_log` |

CLI to create (operator runs against the live OpenBao):

```bash
bao kv put postgres/whisparr \
  username=whisparr \
  password="$(openssl rand -base64 24)" \
  main_db=whisparr_main \
  log_db=whisparr_log
```

This must exist **before** ESO reconciles the new ExternalSecret, otherwise the ExternalSecret will sit in `SecretSyncedError` until the Bao path is populated. Documented in Task 1 of the implementation plan.

### Networking

Service `whisparr.media.svc` on port 6969, `ClusterIP`.

IngressRoute pair, both annotated with `external-dns.alpha.kubernetes.io/target: "192.168.1.230"` (Traefik MetalLB IP). Without this annotation external-dns silently skips the record — encoded in project memory and verified across the rest of the media tier.

`whisparr-http`:
- entryPoint `web`
- match: `` Host(`whisparr.frame.chalupatech.com`) ``
- middleware: `name: redirect-to-https, namespace: media` (the shared one owned by NzbGet)
- backend `name: whisparr, port: 6969` (required by IngressRoute schema even though middleware terminates the response)

`whisparr-https`:
- entryPoint `websecure`
- match: `` Host(`whisparr.frame.chalupatech.com`) ``
- `tls: {}` — uses Traefik's default TLSStore for the wildcard `*.frame.chalupatech.com` cert
- backend: `name: whisparr, port: 6969`

LAN resolution: the existing Unifi `*.frame.chalupatech.com → 192.168.1.230` wildcard override. external-dns creates the audit-trail TXT records in Cloudflare; no public A record (per memory: Cloudflare free tier filters RFC 1918 responses).

## Repository layout (additions / edits)

```
gitops/apps/media/whisparr/                                  NEW
├── Chart.yaml
├── Chart.lock
├── .helmignore
├── charts/
│   └── app-template-4.4.0.tgz
├── values.yaml
└── templates/
    ├── pv-whisparr.yaml
    ├── pvc-whisparr.yaml
    └── ingressroute.yaml

gitops/apps/media/arrs-pg/Chart.yaml                         EDITED  (docstring)
gitops/apps/media/arrs-pg/templates/cluster.yaml             EDITED  (role + DB + managed role)
gitops/apps/media/arrs-pg/templates/whisparr-externalsecret.yaml   NEW
```

No changes to:
- `gitops/bootstrap/applicationsets/media.yaml` — ApplicationSet picks up the new directory automatically.
- Any other wrapper in `gitops/apps/media/*`.
- `gitops/apps/platform/*` or `gitops/apps/infra-tools/*`.

## Sync ordering and reconciliation

Within a single ArgoCD sync:

1. **arrs-pg Application** — applies the updated `cluster.yaml` (CNPG reconciles the new `whisparr` managed role) and the new `whisparr-externalsecret.yaml`. ESO writes the `whisparr-pg` K8s Secret once OpenBao serves `postgres/whisparr`.
2. **whisparr Application** — sync-wave `-2` for the PV, `-1` for the PVC + (independently) the deployment's reference to the `whisparr-pg` Secret. Wave `0` is the Deployment + Service + IngressRoute pair.

Cross-Application sequencing is governed by ApplicationSet retry (`limit: 5, backoff: 30s → 5m`) — if the whisparr Deployment lands before `whisparr-pg` is populated by ESO, the pod CrashLoops with "secret not found" and Argo retries. Empirically this self-heals within one or two backoff cycles. No explicit dependency graph between Applications is needed.

Once the operator has manually created the `whisparr_main` and `whisparr_log` databases (Task 4 in the plan), the Deployment starts cleanly. If the operator forgets that step, Whisparr will start but fail at first DB write with a `database "whisparr_main" does not exist` log line — recoverable by running the `CREATE DATABASE` commands and restarting the pod (`kubectl -n media rollout restart deploy/whisparr`).

## Verification

End-of-step checklist (run after the PR merges and Task 4 completes):

1. `kubectl -n argocd get application whisparr arrs-pg` → both `Synced/Healthy`.
2. `kubectl -n media get pv media-whisparr` → `Bound`, capacity `10Ti`, RWX, `Retain`.
3. `kubectl -n media get pvc media-whisparr` → `Bound`.
4. `kubectl -n media get externalsecret whisparr-pg-creds` → `SecretSynced`.
5. `kubectl -n media get secret whisparr-pg` → exists, has keys `username`, `password`, `main_db`, `log_db`.
6. `kubectl -n media exec -it arrs-pg-1 -- psql -U postgres -c '\l' | grep whisparr` → `whisparr_main` and `whisparr_log` both present, owner `whisparr`.
7. `kubectl -n media exec -it arrs-pg-1 -- psql -U postgres -c '\du' | grep whisparr` → role `whisparr` present.
8. `kubectl -n media get pods -l app.kubernetes.io/name=whisparr` → `1/1 Ready`.
9. `kubectl -n media exec deploy/whisparr -- ls /config /media /downloads` → all three directories readable.
10. `kubectl -n media exec deploy/whisparr -- wget -qO- http://localhost:6969/ping` → returns `OK` or `{"status":"OK"}`.
11. `kubectl get ingressroute -n media | grep whisparr` → two routes (`whisparr-http`, `whisparr-https`).
12. From a LAN client:
    - `dig +short whisparr.frame.chalupatech.com` → `192.168.1.230`.
    - `curl -I https://whisparr.frame.chalupatech.com/ping` → `HTTP/2 200`, no `-k` needed.
13. Browser to `https://whisparr.frame.chalupatech.com` → green padlock; Whisparr first-run wizard appears.
14. Step through first-run wizard, set an admin auth method, land in main UI. Settings → General → confirm "PostgreSQL" appears as the active database backend.
15. The `Verify GitOps reconciliation` step in `.github/workflows/deploy.yml` returns clean after merge.

## Risks and mitigations

- **`postInitApplicationSQL` is stale and won't run.** Adding the `CREATE DATABASE whisparr_*` lines to that block is documentation-only for the current cluster. The implementation plan calls out an explicit `kubectl exec` step (Task 4) so the operator doesn't ship the PR thinking GitOps did the database creation. If anyone forgets, the symptom is clear: the Whisparr pod fails at first DB write, and the log line names the missing database.
- **Private share isolation is at the filesystem level, not at NFS export level.** The new TrueNAS share is exported with the same Maproot=root posture as `PlexMedia/frame`. Anyone with `root` on a Talos node can read both shares. This is the same baseline trust model as the rest of the media tier and is acceptable for the homelab threat model. Tightening would require either restricting the export to specific node IPs or running Whisparr in a separate namespace with stricter NetworkPolicy — explicit future work, not in scope here.
- **Download-client wiring is deferred.** Until the operator decides on the download-client strategy (mount `media-whisparr` into NzbGet under a new category, or deploy a dedicated downloader), Whisparr will run but cannot complete imports. Mitigation: the spec is explicit that this is out of scope; Whisparr starts healthy without it, and the only visible symptom is "no download client configured" in Whisparr's status page.
- **`postgres/whisparr` ordering.** If the implementer forgets to populate OpenBao before merging, ESO will not synthesize `whisparr-pg`, the deployment will CrashLoop on missing Secret references, and ApplicationSet retry will keep firing until OpenBao is updated. Mitigation: Task 1 in the implementation plan is **"create the OpenBao secret"**, before any chart commit.
- **NFS soft mount.** Same `soft,timeo=150,retrans=5` as the shared share. For Whisparr's small SQLite-compat writes and JSON config files this is a non-issue. Large `Media/` writes could in theory tear if NFS flaps for >75s, but the Servarr software retries on import.
- **Image tag drift.** `ghcr.io/hotio/whisparr:v3-v3.3.3` is verified at spec time. If hotio retires the `v3.3.x` line before this PR lands, the implementer probes the manifest endpoint (per `feedback_verify_image_tag_on_registry`) and pins whatever the current `v3-v3.x.y` flavor is — bumping the chart accordingly.
- **No `URL_BASE`.** Whisparr is served at the apex of its subdomain, so reverse-proxy URL-base config is unnecessary. If we ever switch to subpath hosting (e.g., `frame.chalupatech.com/whisparr`), the chart needs both a `WHISPARR__SERVER__URLBASE` env var and a Traefik `StripPrefix` middleware. Out of scope today.

## Open questions

None blocking. Resolved at implementation time:

- Exact pinned image tag (current `v3-v3.3.3`; verify on PR day per the registry-probe rule).
- Final probe tuning (initial values mirror radarr; tune if liveness/readiness flap during first 24h).
- Whether to vendor `app-template-4.4.0.tgz` into `charts/` (yes — matches the existing pattern in `radarr/charts/`).

## Implementation PR plan (preview — full plan written by writing-plans)

**One PR** containing:
- new `gitops/apps/media/whisparr/` wrapper (Chart, values, PV, PVC, IngressRoute)
- edits to `gitops/apps/media/arrs-pg/templates/cluster.yaml` (role + DBs + managed role)
- new `gitops/apps/media/arrs-pg/templates/whisparr-externalsecret.yaml`
- updated `gitops/apps/media/arrs-pg/Chart.yaml` docstring

**Pre-merge operator steps (Task 1):**
1. `bao kv put postgres/whisparr ...` (OpenBao secret).
2. SSH to TrueNAS — create `/mnt/PlexMedia/WhispArr/{Configs/whisparr,Media,Downloads}` (empty directories).

**Post-merge operator steps (Task 4):**
3. `kubectl exec` into the `arrs-pg` primary and run the two `CREATE DATABASE` + two `GRANT` statements.
4. `kubectl -n media rollout restart deploy/whisparr` (so the pod re-resolves the now-present databases).
5. Browse to `https://whisparr.frame.chalupatech.com`, complete first-run wizard, set admin auth.

Download-client integration is **not** part of this PR — explicit follow-on.

## References

- Whisparr upstream: https://github.com/Whisparr/Whisparr (v3 / Eros branch).
- hotio/whisparr container: https://github.com/hotio/whisparr/pkgs/container/whisparr.
- bjw-s `app-template` chart: https://github.com/bjw-s-labs/helm-charts/tree/main/charts/other/app-template.
- Closest existing wrapper: `gitops/apps/media/radarr/` (same .NET app + same env-var pattern).
- Sub-project #3 spec: `docs/superpowers/specs/2026-05-07-media-stack-design.md`.
- Clonarr spec (most-recent media-app addition; pattern reference): `docs/superpowers/specs/2026-05-10-clonarr-design.md`.
- Project conventions: `CLAUDE.md`.
- Memory entries that shape this design:
  - `project_argocd_sync_config.md` — sync policy + retry behavior.
  - `project_external_dns_target_annotation.md` — target annotation requirement.
  - `project_cloudflare_rfc1918_filter.md` — public DNS posture.
  - `project_talos_psa_constraint.md` — PSA posture (baseline is fine for Whisparr).
  - `feedback_pgloader_servarr_incompatible.md` — no SQLite→PG migration, fresh start only.
  - `feedback_verify_image_tag_on_registry.md` — registry-probe before pinning.
