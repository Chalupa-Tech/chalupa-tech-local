# Whisparr — Design

**Date:** 2026-05-11
**Status:** Draft (pending user approval)
**Sub-project:** Follow-on to #3 (media stack)

## Context

The media tier currently runs Sonarr, Radarr, Seerr, NzbGet, Tdarr, Clonarr, and the shared `arrs-pg` CNPG Postgres cluster under `gitops/apps/media/`. All apps land in the `media` namespace via the `media-apps` ApplicationSet (`gitops/bootstrap/applicationsets/media.yaml`) and are exposed at `<name>.frame.chalupatech.com` over HTTPS through Traefik + the wildcard cert.

This spec adds **[Whisparr](https://github.com/Whisparr/Whisparr)** (v3 / "Eros" branch) as the seventh media app, plus a **dedicated NzbGet instance** as its sole download client. Whisparr is a Radarr fork tailored for adult scene-based content; functionally it is the closest sibling to Radarr in the stack — same .NET codebase, same Postgres back end, same Servarr API shape — so the wrapper chart inherits radarr's shape directly.

Because of the private nature of the content, the operator has provisioned a **dedicated TrueNAS NFS share at `PlexMedia/WhispArr`** (exported as `192.168.1.40:/mnt/PlexMedia/WhispArr`), separate from the existing `PlexMedia/frame` share that backs the rest of the media tier. Whisparr and its dedicated NzbGet share **only** the Postgres back end with the rest of the stack — everything else (NFS storage, downloads, configuration, Usenet provider credentials) is isolated.

## Goals

- Run Whisparr in the existing `media` namespace on the Talos cluster, alongside a **dedicated `whisparr-nzbget` NzbGet** instance that downloads exclusively to the private share.
- Use bjw-s `app-template` 4.4.0, with **both** controllers (`whisparr` and `whisparr-nzbget`) defined inside a single wrapper chart so ownership is atomic — destroying the Whisparr Application reclaims both.
- Persist all state on the **new dedicated `media-whisparr` NFS PVC** backed by the private TrueNAS share at `192.168.1.40:/mnt/PlexMedia/WhispArr`. The shared `media-plexmedia` PVC is intentionally not mounted by either controller.
- Use the shared `arrs-pg` CNPG Postgres cluster for Whisparr state — new `whisparr` role + `whisparr_main` and `whisparr_log` databases, credentials sourced from OpenBao via ExternalSecret. (NzbGet itself does not use Postgres.)
- Expose both at `whisparr.frame.chalupatech.com` and `whisparr-nzbget.frame.chalupatech.com` over HTTPS using the existing wildcard cert, external-dns target annotation, and shared `redirect-to-https` Middleware.
- Whisparr is configured to talk to `http://whisparr-nzbget.media.svc:6789` as its only download client (operator pastes the control password from the new OpenBao secret via the Whisparr Settings UI on first run).

## Non-goals (explicitly out of scope)

- **Tagging / quality profiles / indexers / sync from Clonarr.** Operator setup via the Whisparr Settings UI post-deploy. Clonarr does not target Whisparr (it only syncs to Radarr + Sonarr), so no Clonarr changes.
- **ServiceMonitor / Prometheus metrics.** Whisparr exposes basic metrics endpoints, but observability for the arrs is a separate sub-project. No metrics added here.
- **OIDC / SSO.** Whisparr uses its own forms-based auth; operator creates an admin account on first visit.
- **Renovate / image automation.** Manual chart and image bumps via PR, matching the rest of the stack.
- **Dedicated namespace / PSA elevation.** Whisparr is non-root, no privileged capabilities, no hostNetwork. Reuses the `media` namespace and baseline PSA, same as radarr/sonarr.
- **Migration of any existing Whisparr SQLite state.** This is a fresh install. No pgloader (per memory: `feedback_pgloader_servarr_incompatible.md`). The operator starts Whisparr clean and re-adds quality profiles / indexers via the UI.
- **Reusing the existing `nzbget-credentials` ExternalSecret.** A separate OpenBao path (`whisparr-nzbget/credentials`) backs the new instance, so the operator can rotate the Whisparr-side control password and (optionally) point it at a different Usenet provider account without disturbing the main NzbGet. Strict isolation, per the user requirement.
- **Modifying the existing main `nzbget` wrapper.** It keeps its current shape, mounts, secret, and ingress. The new instance lives entirely in the new whisparr wrapper.

## Architecture

### Tiering

No new tier. The wrapper chart lands at `gitops/apps/media/whisparr/` and the existing `media-apps` ApplicationSet picks it up automatically via its `directories.path: gitops/apps/media/*` generator. The `arrs-pg` ExternalSecret/role/database additions sit in the existing `arrs-pg` wrapper at `gitops/apps/media/arrs-pg/`.

### Wrapper-chart shape

A single bjw-s `app-template` 4.4.0 chart with **two controllers** under one Helm release. The base chart's `controllers` map supports multiple keys, each producing its own Deployment/Service; this is the same mechanism every existing wrapper uses to declare a single controller and is fully supported for N>1.

```
gitops/apps/media/whisparr/                                  NEW
├── Chart.yaml          # depends on app-template 4.4.0
├── Chart.lock          # committed (matches convention)
├── .helmignore
├── charts/
│   └── app-template-4.4.0.tgz                               # vendored
├── values.yaml         # two controllers, two services, one PVC, mixed mounts
└── templates/
    ├── pv-whisparr.yaml                                     # dedicated NFS PV
    ├── pvc-whisparr.yaml                                    # dedicated NFS PVC
    ├── whisparr-nzbget-externalsecret.yaml                  # Usenet creds + control pw
    └── ingressroute.yaml                                    # 4 routes: web+websecure × whisparr+nzbget
```

The PV/PVC pair lives **inside the whisparr wrapper chart**, not the nzbget wrapper. Rationale: ownership is 1:1 with the consuming app (no other app needs this private share), so co-locating the storage manifest with the consumer matches the natural blast radius — destroying the whisparr Application also reclaims the PV (Retain policy preserves data; `kubectl delete pv` is still operator-triggered).

The new ExternalSecret lives inside the whisparr wrapper as well — same reason; it is consumed only by the `whisparr-nzbget` controller and never referenced outside this chart.

### Images and tags

| Controller | Image | Tag |
|---|---|---|
| `whisparr` | `ghcr.io/hotio/whisparr` | `v3-v3.3.3` |
| `whisparr-nzbget` | `lscr.io/linuxserver/nzbget` | `latest` |

**Whisparr image:** the `v3-v3.3.3` tag is the current pinned-release flavor of hotio's v3 ("Eros") branch. The floating `:v3` tag would also work but contradicts the project memory `feedback_verify_image_tag_on_registry` (no inferring; pin a verified tag). LSIO does not publish a `linuxserver/whisparr` image.

**NzbGet image:** matches the tag (`latest`) used by the existing `gitops/apps/media/nzbget/values.yaml`. Keeping both NzbGet instances on the same image stream avoids divergent behavior and makes it trivial to keep them in sync — and operator practice here has been `:latest`. This is intentional consistency with the existing wrapper, not a separate choice.

**Pre-implementation verification:** the implementer probes the GHCR manifest for `ghcr.io/hotio/whisparr:v3-v3.3.3` (or the current latest pinned `v3-v3.x.y` flavor) and updates the chart with whatever is current at PR time. The hotio image is multi-arch (amd64 + arm64) — only amd64 matters for the Talos workers.

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
            tag: v3-v3.3.3
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
            liveness: { enabled: true, custom: true, spec: { httpGet: { path: /ping, port: 6969 }, initialDelaySeconds: 30, periodSeconds: 30, timeoutSeconds: 10, failureThreshold: 5 } }
            readiness: { enabled: true, custom: true, spec: { httpGet: { path: /ping, port: 6969 }, initialDelaySeconds: 5, periodSeconds: 10, timeoutSeconds: 5, failureThreshold: 5 } }
            startup: { enabled: true, custom: true, spec: { httpGet: { path: /ping, port: 6969 }, initialDelaySeconds: 30, periodSeconds: 10, timeoutSeconds: 5, failureThreshold: 60 } }
          resources:
            requests: { cpu: 50m, memory: 256Mi }
            limits: { memory: 2Gi }

    whisparr-nzbget:
      type: deployment
      replicas: 1
      strategy: Recreate
      containers:
        main:
          image:
            repository: lscr.io/linuxserver/nzbget
            tag: latest
          env:
            TZ: America/Los_Angeles
            PUID: "1000"
            PGID: "1000"
            NZBGET_USER: nzbget
            NZBGET_PASS:
              valueFrom:
                secretKeyRef:
                  name: whisparr-nzbget-credentials
                  key: control-password
          probes:
            liveness: { enabled: true, custom: true, spec: { tcpSocket: { port: 6789 }, initialDelaySeconds: 30, periodSeconds: 30 } }
            readiness: { enabled: true, custom: true, spec: { tcpSocket: { port: 6789 }, initialDelaySeconds: 5, periodSeconds: 10 } }
            startup: { enabled: false }
          resources:
            requests: { cpu: 50m, memory: 256Mi }
            limits: { memory: 2Gi }

  service:
    whisparr:
      controller: whisparr
      ports:
        http:
          port: 6969
    whisparr-nzbget:
      controller: whisparr-nzbget
      ports:
        http:
          port: 6789

  persistence:
    whisparr-config:
      enabled: true
      type: persistentVolumeClaim
      existingClaim: media-whisparr
      advancedMounts:
        whisparr:
          main:
            - path: /config
              subPath: Configs/whisparr
    whisparr-media:
      enabled: true
      type: persistentVolumeClaim
      existingClaim: media-whisparr
      advancedMounts:
        whisparr:
          main:
            - path: /media
              subPath: Media
    shared-downloads:
      enabled: true
      type: persistentVolumeClaim
      existingClaim: media-whisparr
      advancedMounts:
        whisparr:
          main:
            - path: /downloads
              subPath: Downloads
        whisparr-nzbget:
          main:
            - path: /downloads
              subPath: Downloads
    nzbget-config:
      enabled: true
      type: persistentVolumeClaim
      existingClaim: media-whisparr
      advancedMounts:
        whisparr-nzbget:
          main:
            - path: /config
              subPath: Configs/nzbget
```

Key choices in this `values.yaml`:

- **One PVC, multiple subPaths, multiple targets per persistence key via `advancedMounts`.** bjw-s `app-template` 4.x supports the `advancedMounts: {controller: {container: [...]}}` form, which lets a single persistence entry mount into more than one controller (or just one specific controller) without re-declaring the PVC. The shared `Downloads/` subPath is mounted into **both** controllers at `/downloads` — NzbGet writes there, Whisparr reads from there to import into `/media`. The other three keys each target exactly one controller. This is functionally equivalent to declaring three single-mount entries plus a two-target entry; the `advancedMounts` form keeps the PVC reference DRY.
- **`runAsNonRoot: false` + `fsGroup: 568`** matches every other media wrapper. Both images use `gosu`/`su-exec` to drop to PUID:PGID after start.
- **PUID/PGID 1000** matches the rest of the media tier (NFS Maproot=root squashes the in-pod UID anyway; kept for behavioral consistency).
- **Whisparr probe path `/ping` on port 6969** — Servarr's built-in health endpoint.
- **NzbGet probes use TCP-socket on 6789** — identical to the existing main NzbGet wrapper; HTTP probes require Basic Auth which the secret-resolution timing doesn't guarantee.
- **`Whisparr__Postgres__*` env vars** mirror Radarr's; the Servarr config provider is case-insensitive when binding from env, but we keep the existing CamelCase pattern for visual consistency across the tier.
- **`NZBGET_USER: nzbget`** and `NZBGET_PASS` from the new `whisparr-nzbget-credentials` Secret's `control-password` key — exactly matches the existing nzbget wrapper's shape, just with a different Secret name.
- **No `WHISPARR__SERVER__URLBASE`** and no NzbGet URL-base config — both apps are served at the apex of their subdomains.
- **Resource bounds** match radarr / main nzbget. Both apps are small unless actively transcoding (they don't) or downloading at line rate (NzbGet may briefly spike I/O but stays under 2 GiB resident).

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

NFS mount options, capacity, access mode, reclaim policy, and storage class are all carried over verbatim from the existing pattern. Sync-wave `-2/-1` ensures the PV/PVC bind before the Deployments in wave `0`.

**Subdirectories on the TrueNAS share** must exist before the pods start (bjw-s `subPath` mounts require the path to exist):

- `/mnt/PlexMedia/WhispArr/Configs/whisparr/`
- `/mnt/PlexMedia/WhispArr/Configs/nzbget/`
- `/mnt/PlexMedia/WhispArr/Media/`
- `/mnt/PlexMedia/WhispArr/Downloads/`

These are created as part of Task 1 (pre-merge operator runbook).

### `arrs-pg` cluster additions

The shared CNPG Postgres cluster gains a `whisparr` role and two databases. Three files change in `gitops/apps/media/arrs-pg/`.

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

**Important — `postInitApplicationSQL` only runs once at initial bootstrap.** The cluster has long since bootstrapped, so editing those lines is documentation-only (preserves the spec for any future rebuild). Two paths handle the live cluster:

1. **Role `whisparr`** — created automatically by CNPG once the new `managed.roles` entry reconciles; the password is synced from the `whisparr-pg` secret. No operator action needed.
2. **Databases `whisparr_main` / `whisparr_log`** — CNPG's `managed.roles` does **not** create databases. The operator runs `CREATE DATABASE whisparr_main OWNER whisparr; CREATE DATABASE whisparr_log OWNER whisparr; GRANT ALL PRIVILEGES ON DATABASE whisparr_main TO whisparr; GRANT ALL PRIVILEGES ON DATABASE whisparr_log TO whisparr;` against the cluster primary via `kubectl exec`. This is Task 4 in the implementation plan.

**`templates/whisparr-externalsecret.yaml`** — new file, mirrors `radarr-externalsecret.yaml`, reading from OpenBao path `postgres/whisparr` and synthesizing a `whisparr-pg` Secret with `username`/`password`/`main_db`/`log_db` keys.

**`Chart.yaml`** description — update the docstring line that enumerates app users / databases so it stays accurate ("four application users (sonarr, radarr, seerr, whisparr) and seven databases ...").

### NzbGet ExternalSecret (in the whisparr wrapper)

`gitops/apps/media/whisparr/templates/whisparr-nzbget-externalsecret.yaml` — new file, mirrors the existing `gitops/apps/media/nzbget/templates/nzbget-credentials-externalsecret.yaml` but reads from OpenBao path `whisparr-nzbget/credentials` and produces a `whisparr-nzbget-credentials` Secret in the `media` namespace. Same four keys (`provider-host`, `provider-username`, `provider-password`, `control-password`). Only `control-password` is consumed by the container env directly; the three `provider-*` keys are read by the operator to seed the NzbGet UI's News Server config on first run (NzbGet does not accept Usenet provider config via env vars).

### OpenBao secrets — operator pre-merge step

Two new KV-v2 entries.

**`postgres/whisparr`** (Whisparr Postgres credentials):

| Property | Value |
|---|---|
| `username` | `whisparr` |
| `password` | random 32-char passphrase |
| `main_db` | `whisparr_main` |
| `log_db` | `whisparr_log` |

**`whisparr-nzbget/credentials`** (Usenet provider + NzbGet control auth):

| Property | Value |
|---|---|
| `provider-host` | operator's Usenet provider host (e.g. `news.eweka.nl`) |
| `provider-username` | provider account username |
| `provider-password` | provider account password |
| `control-password` | random 32-char passphrase (NzbGet web UI auth) |

CLI to create (operator runs against the live OpenBao):

```bash
bao kv put postgres/whisparr \
  username=whisparr \
  password="$(openssl rand -base64 24)" \
  main_db=whisparr_main \
  log_db=whisparr_log

bao kv put whisparr-nzbget/credentials \
  provider-host="news.example.com" \
  provider-username="$(read -r u; echo "$u")" \
  provider-password="$(read -rs p; echo "$p")" \
  control-password="$(openssl rand -base64 24)"
```

Both must exist **before** ESO reconciles the new ExternalSecrets, otherwise the ExternalSecrets sit in `SecretSyncedError` until the Bao paths are populated. Documented in Task 1 of the implementation plan.

### Networking

| Service | Type | Port |
|---|---|---|
| `whisparr.media.svc` | ClusterIP | 6969 |
| `whisparr-nzbget.media.svc` | ClusterIP | 6789 |

**Four IngressRoute entries** in a single `templates/ingressroute.yaml`, all annotated with `external-dns.alpha.kubernetes.io/target: "192.168.1.230"`.

| Route name | Host | EntryPoint | Backend |
|---|---|---|---|
| `whisparr-http` | `whisparr.frame.chalupatech.com` | `web` (redirects to https via shared `redirect-to-https` middleware) | `whisparr:6969` |
| `whisparr-https` | `whisparr.frame.chalupatech.com` | `websecure` (TLS via default TLSStore wildcard) | `whisparr:6969` |
| `whisparr-nzbget-http` | `whisparr-nzbget.frame.chalupatech.com` | `web` (redirect) | `whisparr-nzbget:6789` |
| `whisparr-nzbget-https` | `whisparr-nzbget.frame.chalupatech.com` | `websecure` | `whisparr-nzbget:6789` |

LAN resolution: the existing Unifi `*.frame.chalupatech.com → 192.168.1.230` wildcard override. external-dns creates the audit-trail TXT records in Cloudflare; no public A record (per memory: Cloudflare free tier filters RFC 1918 responses).

**Whisparr→NzbGet wiring (operator post-deploy):** in the Whisparr UI under Settings → Download Clients → Add → NzbGet:

| Field | Value |
|---|---|
| Host | `whisparr-nzbget.media.svc` |
| Port | `6789` |
| Username | `nzbget` |
| Password | the `control-password` from OpenBao `whisparr-nzbget/credentials` |
| Category | `whisparr` (operator-created inside NzbGet) |

This path stays inside the cluster; no Traefik traversal, no external DNS.

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
    ├── whisparr-nzbget-externalsecret.yaml
    └── ingressroute.yaml

gitops/apps/media/arrs-pg/Chart.yaml                         EDITED  (docstring)
gitops/apps/media/arrs-pg/templates/cluster.yaml             EDITED  (role + DB + managed role)
gitops/apps/media/arrs-pg/templates/whisparr-externalsecret.yaml   NEW
```

No changes to:
- `gitops/bootstrap/applicationsets/media.yaml` — ApplicationSet picks up the new directory automatically.
- `gitops/apps/media/nzbget/*` — the main NzbGet wrapper stays untouched; its mounts, secret, ingress, and shared resources are unaffected.
- Any other wrapper in `gitops/apps/media/*`.
- `gitops/apps/platform/*` or `gitops/apps/infra-tools/*`.

## Sync ordering and reconciliation

Within a single ArgoCD sync of the new `whisparr` Application:

1. Sync-wave `-2` — `PersistentVolume media-whisparr` (static NFS).
2. Sync-wave `-1` — `PersistentVolumeClaim media-whisparr` (binds to the PV via `claimRef`), `ExternalSecret whisparr-nzbget-credentials` (ESO writes the `whisparr-nzbget-credentials` Secret once OpenBao serves `whisparr-nzbget/credentials`).
3. Sync-wave `0` (default) — both Deployments + both Services + four IngressRoutes.

Separately, the `arrs-pg` Application's sync applies:

- `Cluster arrs-pg` updates (CNPG reconciles the new `whisparr` managed role on next reconcile, ~minutes).
- `ExternalSecret whisparr-pg-creds` — ESO writes the `whisparr-pg` Secret once OpenBao serves `postgres/whisparr`.

If the Whisparr Deployment lands before `whisparr-pg` is populated by ESO, the pod CrashLoops with "secret not found" and Argo retries (`limit: 5, backoff: 30s → 5m`). Empirically this self-heals within one or two backoff cycles.

After the operator runs the manual `CREATE DATABASE whisparr_main / whisparr_log` (Task 4) and rolls the Deployment, Whisparr starts cleanly. If the operator forgets, Whisparr fails at first DB write with `database "whisparr_main" does not exist`, recoverable by running the SQL and `kubectl -n media rollout restart deploy/whisparr`.

## Verification

End-of-step checklist (run after the PR merges and Task 4 completes):

1. `kubectl -n argocd get application whisparr arrs-pg` → both `Synced/Healthy`.
2. `kubectl -n media get pv media-whisparr` → `Bound`, capacity `10Ti`, RWX, `Retain`.
3. `kubectl -n media get pvc media-whisparr` → `Bound`.
4. `kubectl -n media get externalsecret whisparr-pg-creds whisparr-nzbget-credentials` → both `SecretSynced`.
5. `kubectl -n media get secret whisparr-pg whisparr-nzbget-credentials` → both exist with the documented keys.
6. `kubectl -n media exec -it arrs-pg-1 -- psql -U postgres -c '\l' | grep whisparr` → `whisparr_main` and `whisparr_log` present, owner `whisparr`.
7. `kubectl -n media exec -it arrs-pg-1 -- psql -U postgres -c '\du' | grep whisparr` → role `whisparr` present.
8. `kubectl -n media get pods -l app.kubernetes.io/instance=whisparr` → 2 pods, both `1/1 Ready`.
9. `kubectl -n media exec deploy/whisparr -- ls /config /media /downloads` → all three directories readable.
10. `kubectl -n media exec deploy/whisparr-nzbget -- ls /config /downloads` → both readable, `/downloads` is the SAME inode as Whisparr's `/downloads` (same NFS subPath).
11. `kubectl -n media exec deploy/whisparr -- wget -qO- http://localhost:6969/ping` → returns OK.
12. `kubectl -n media exec deploy/whisparr-nzbget -- nc -zv localhost 6789` → connection succeeds.
13. `kubectl get ingressroute -n media | grep whisparr` → four routes (`whisparr-http`, `whisparr-https`, `whisparr-nzbget-http`, `whisparr-nzbget-https`).
14. From a LAN client:
    - `dig +short whisparr.frame.chalupatech.com whisparr-nzbget.frame.chalupatech.com` → both resolve to `192.168.1.230`.
    - `curl -I https://whisparr.frame.chalupatech.com/ping` → `HTTP/2 200`, no `-k` needed.
    - `curl -I https://whisparr-nzbget.frame.chalupatech.com/` → `HTTP/2 401` (Basic Auth challenge; means NzbGet is up).
15. Browser to `https://whisparr-nzbget.frame.chalupatech.com` → log in with `nzbget` / `<control-password from Bao>`. Settings → News Servers → paste `provider-host`/`provider-username`/`provider-password` from Bao → test → success.
16. Browser to `https://whisparr.frame.chalupatech.com` → step through first-run wizard, set admin auth. Settings → General → confirm "PostgreSQL" is the active backend. Settings → Download Clients → Add → NzbGet → host `whisparr-nzbget.media.svc`, port 6789, username `nzbget`, password from Bao → Test passes.
17. Add an indexer (operator's Usenet indexer of choice) under Settings → Indexers, save.
18. Drop one test scene into Whisparr's search; verify it enqueues into `whisparr-nzbget`, downloads to `/mnt/PlexMedia/WhispArr/Downloads/`, and Whisparr imports it to `/mnt/PlexMedia/WhispArr/Media/`.
19. The `Verify GitOps reconciliation` step in `.github/workflows/deploy.yml` returns clean after merge.

## Risks and mitigations

- **`postInitApplicationSQL` is stale and won't run.** Editing the lines is documentation-only for the current cluster. The implementation plan calls out an explicit `kubectl exec` step (Task 4) so the operator doesn't ship the PR thinking GitOps did the database creation. If anyone forgets, the symptom is clear: the Whisparr pod fails at first DB write naming the missing database.
- **Two-controller chart is a new shape in this repo.** Every existing wrapper has exactly one controller. The bjw-s `app-template` 4.x docs explicitly support N>1 controllers under a single Helm release (controllers is a map, services and persistence reference controllers by key), and `kubectl explain` of the rendered template will show standard Deployment / Service objects. Mitigation: pre-flight `helm template ./` locally during implementation and inspect the rendered output — easy to spot any unexpected combinator before commit.
- **Shared `Downloads/` subPath between two controllers in the same chart.** With NFS RWX both pods can read/write the same path; this is the explicit design (NzbGet writes, Whisparr reads/moves). The only failure mode would be a partial-rename race during import, which Whisparr's import logic already handles with retries.
- **NzbGet `:latest` tag drift.** Both the new and the existing nzbget wrappers use `:latest`. A future LSIO release could break either or both at the same time. This is the existing project posture and is intentionally unchanged here — bumping to a pinned tag is a separate, broader decision that should cover both instances at once.
- **`whisparr-nzbget` UI exposed on the LAN.** Anyone with a LAN client can reach `https://whisparr-nzbget.frame.chalupatech.com` and is met with HTTP Basic Auth (NzbGet's built-in). The `control-password` is operator-generated and long; brute force is impractical. If the homelab threat model later treats LAN clients as untrusted, the route can be removed (NzbGet would still be reachable in-cluster) — easy follow-on, one IngressRoute pair deletion.
- **Two Usenet account credentials live in OpenBao now.** The new and existing NzbGet instances are on separate OpenBao paths; rotating one will not touch the other. The operator may choose to reuse the same provider account between the two — fine, just paste the same values into both `bao kv put`s.
- **Private share isolation is filesystem-level, not export-level.** Same Maproot=root posture as `PlexMedia/frame`; any node with root can read both shares. Acceptable per the homelab threat model, identical to today's posture for the rest of the media tier.
- **Image tag drift for Whisparr.** `ghcr.io/hotio/whisparr:v3-v3.3.3` is verified at spec time. If hotio retires the `v3.3.x` line before this PR lands, the implementer probes the manifest endpoint (per `feedback_verify_image_tag_on_registry`) and pins whatever the current `v3-v3.x.y` flavor is — bumping the chart accordingly.
- **NFS soft mount.** Same `soft,timeo=150,retrans=5` as the shared share. Whisparr's small SQLite-compat writes and NzbGet's queue file writes are durable across reboots; large `Media/` writes could in theory tear if NFS flaps for >75s, but both Servarr and NzbGet retry.

## Open questions

None blocking. Resolved at implementation time:

- Exact pinned Whisparr image tag (current `v3-v3.3.3`; verify on PR day per the registry-probe rule).
- NzbGet tag — `:latest` as a deliberate match to the existing wrapper. Operator can decide later whether to pin both NzbGet instances simultaneously to a specific version.
- Final probe tuning (initial values mirror radarr / existing nzbget; tune if liveness/readiness flap during first 24h).
- Whether the implementer wants to vendor `app-template-4.4.0.tgz` into `charts/` (yes — matches the existing pattern in `radarr/charts/`, `sonarr/charts/`, `nzbget/charts/`).

## Implementation PR plan (preview — full plan written by writing-plans)

**One PR** containing:

- new `gitops/apps/media/whisparr/` wrapper (Chart, values, PV, PVC, NzbGet ExternalSecret, IngressRoute pair for each controller).
- edits to `gitops/apps/media/arrs-pg/templates/cluster.yaml` (role + DBs + managed role).
- new `gitops/apps/media/arrs-pg/templates/whisparr-externalsecret.yaml`.
- updated `gitops/apps/media/arrs-pg/Chart.yaml` docstring.

**Pre-merge operator steps (Task 1):**

1. `bao kv put postgres/whisparr ...` (Whisparr Postgres credentials).
2. `bao kv put whisparr-nzbget/credentials ...` (Usenet + NzbGet control password).
3. SSH to TrueNAS — create `/mnt/PlexMedia/WhispArr/{Configs/whisparr,Configs/nzbget,Media,Downloads}` (empty directories).

**Post-merge operator steps (Task 4):**

4. `kubectl exec` into the `arrs-pg` primary and run the two `CREATE DATABASE` + two `GRANT` statements.
5. `kubectl -n media rollout restart deploy/whisparr` (so the pod re-resolves the now-present databases).
6. Browse to `https://whisparr-nzbget.frame.chalupatech.com`, log in with `nzbget` / `<control-password>`, paste Usenet provider config from Bao under Settings → News Servers.
7. Browse to `https://whisparr.frame.chalupatech.com`, complete first-run wizard, configure download client (Settings → Download Clients → NzbGet → `whisparr-nzbget.media.svc:6789`).

## References

- Whisparr upstream: https://github.com/Whisparr/Whisparr (v3 / Eros branch).
- hotio/whisparr container: https://github.com/hotio/whisparr/pkgs/container/whisparr.
- bjw-s `app-template` chart: https://github.com/bjw-s-labs/helm-charts/tree/main/charts/other/app-template.
- bjw-s `app-template` multi-controller / `advancedMounts` reference: same repo, `values.schema.json` in the chart root.
- Closest existing wrappers: `gitops/apps/media/radarr/` (Whisparr's app shape) and `gitops/apps/media/nzbget/` (the second controller's shape).
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
