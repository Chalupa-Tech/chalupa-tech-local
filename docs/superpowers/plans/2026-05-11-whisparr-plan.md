# Whisparr Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Whisparr (v3 "Eros") plus a dedicated `whisparr-nzbget` downloader to the media tier on the Talos cluster. After this plan: `whisparr.frame.chalupatech.com` and `whisparr-nzbget.frame.chalupatech.com` serve over HTTPS, Argo shows a `whisparr` Application Synced/Healthy with two pods 1/1 Ready, Whisparr persists state in the shared `arrs-pg` Postgres cluster, and all on-disk state lives on the new private NFS share at `192.168.1.40:/mnt/PlexMedia/WhispArr`.

**Architecture:** One wrapper chart at `gitops/apps/media/whisparr/` consuming bjw-s `app-template` 4.4.0 with **two controllers** under one Helm release (`whisparr` + `whisparr-nzbget`). The chart owns a dedicated `media-whisparr` static NFS PV/PVC backed by the private share. Postgres state is provisioned by adding a `whisparr` role and `whisparr_main` / `whisparr_log` databases to the existing `arrs-pg` CNPG cluster, with credentials sourced from OpenBao via a new ExternalSecret. The existing `media-apps` ApplicationSet picks up the new directory automatically — no ApplicationSet changes.

**Tech Stack:** Helm 3, kubeconform 0.6.x, yamllint 1.35.x, ArgoCD ApplicationSet (existing), bjw-s `app-template` 4.4.0, Traefik 3.x IngressRoute CRDs (existing), CloudNativePG (existing), External Secrets Operator (existing), OpenBao (existing), Whisparr `ghcr.io/hotio/whisparr:v3-v3.3.3` (verify-on-PR-day), NzbGet `lscr.io/linuxserver/nzbget:latest`.

**Reference spec:** `docs/superpowers/specs/2026-05-11-whisparr-design.md`.

**Branching strategy:** One feature branch (`feat/whisparr`), one PR. Tasks 1 and 2 are manual operator runbooks (no PR). Task 3 is the PR. Tasks 4–6 are post-merge verification + post-deploy operator setup (no PRs).

**Pre-existing prerequisites (already satisfied):**

- All seven media Applications Synced/Healthy: `arrs-pg`, `nzbget`, `sonarr`, `radarr`, `seerr`, `tdarr`, `clonarr`.
- TrueNAS NFS export `PlexMedia/WhispArr` exists and is reachable from cluster nodes at `192.168.1.40:/mnt/PlexMedia/WhispArr`. (The user has created this share.)
- `media-apps` ApplicationSet exists at `gitops/bootstrap/applicationsets/media.yaml` and is configured to pick up new directories under `gitops/apps/media/`.
- Middleware `redirect-to-https` exists in the `media` namespace (owned by the nzbget wrapper).
- Traefik default TLSStore covers `*.frame.chalupatech.com`.
- Unifi DNS override resolves `*.frame.chalupatech.com → 192.168.1.230` on LAN.
- external-dns + Cloudflare provider operating; TXT records visible in Cloudflare for existing media hosts.
- ESO `ClusterSecretStore openbao` reconciling against the live OpenBao.
- SSH access to TrueNAS at `192.168.1.40` and to the live OpenBao (operator has credentials).

---

## Pre-Flight: Local Tooling

The implementer must have these CLIs and a working `KUBECONFIG` before starting any task.

- [ ] **Step P-1: Verify local CLIs**

```bash
helm version --short                    # expect: v3.x
kubeconform -v                          # expect: v0.6+
yamllint --version                      # expect: any
gh --version                            # expect: gh version 2.x
kubectl version --client                # expect: v1.30+ (Homebrew-signed)
ssh -V                                  # expect: any OpenSSH
bao --version                           # expect: any
```

If any are missing: `brew install <tool>`. kubectl must be the Homebrew-signed binary (per `project_tailscale_kubectl_ehostunreach` memory).

- [ ] **Step P-2: Set KUBECONFIG**

```bash
cd pulumi-talos && pulumi stack output kubeconfig --show-secrets > ~/.kube/chalupa-cluster.yaml && cd -
chmod 600 ~/.kube/chalupa-cluster.yaml
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
kubectl get nodes
```

Expected: 6 nodes Ready (3 CPs + 3 workers). If `no route to host`, prefix every kubectl below with `sudo` (Tailscale macOS Network Extension interception per memory).

- [ ] **Step P-3: Sanity-check prerequisites**

```bash
# Argo + ApplicationSet alive
kubectl -n argocd get applicationset media-apps
kubectl -n argocd get application | grep -E 'arrs-pg|nzbget|sonarr|radarr|seerr|tdarr|clonarr'
# Expected: all show Synced + Healthy

# ESO and ClusterSecretStore alive
kubectl get clustersecretstore openbao
# Expected: STATUS=Valid, READY=True

# Existing shared resources
kubectl -n media get middleware redirect-to-https
kubectl -n media get pvc media-plexmedia
# Expected: middleware exists; PVC Bound

# arrs-pg primary reachable
kubectl -n media get cluster.postgresql.cnpg.io arrs-pg
# Expected: Cluster in Healthy phase, 3 instances Ready

# Verify the new TrueNAS share is reachable from the cluster (sanity, not destructive)
kubectl -n default run nfs-probe --rm -i --restart=Never --image=alpine:3.20 \
  --overrides='{"spec":{"hostNetwork":false}}' -- \
  sh -c 'apk add --no-cache nfs-utils >/dev/null 2>&1; showmount -e 192.168.1.40 2>/dev/null | grep -i whisparr || echo "share not visible from probe"'
```

Expected last command: a line containing `/mnt/PlexMedia/WhispArr`. If you see `share not visible from probe`, **stop** — confirm with the operator that the export is in place and visible to the cluster subnet before continuing.

- [ ] **Step P-4: Verify the Whisparr image tag exists on GHCR**

Per memory `feedback_verify_image_tag_on_registry`, probe the registry before committing a pin.

```bash
# Anonymous manifest probe via skopeo (preferred) — or use Docker locally:
docker manifest inspect ghcr.io/hotio/whisparr:v3-v3.3.3 > /dev/null && echo "OK: tag exists" || echo "MISSING"
```

Expected: `OK: tag exists`. If `MISSING`, browse https://github.com/hotio/whisparr/pkgs/container/whisparr, identify the current pinned `v3-v3.x.y` flavor, and update **every occurrence** of `v3-v3.3.3` in this plan (Steps 3-10 and 3-13) to the verified tag before writing the chart files.

- [ ] **Step P-5: Refresh the bjw-s helm repo**

```bash
helm repo add bjw-s https://bjw-s-labs.github.io/helm-charts/ || true
helm repo update bjw-s
helm search repo bjw-s/app-template --versions | head -5
```

Expected: `bjw-s/app-template` version `4.4.0` (or newer 4.x) shows up. If 4.4.0 is no longer in the index, pick the latest stable 4.x and update the Chart.yaml dependency version accordingly in Step 3-9.

---

## Task 1: Populate OpenBao with the two new secrets *(manual operator runbook — no PR)*

The new `arrs-pg` ExternalSecret and the new whisparr-nzbget ExternalSecret will sit in `SecretSyncedError` until the OpenBao KV-v2 paths are populated. Populate them first, before opening the PR — that way ESO converges cleanly on the first reconcile after merge.

**Files:** none. Manual operator action against the live OpenBao.

- [ ] **Step 1-1: Authenticate to OpenBao**

```bash
export BAO_ADDR="https://openbao.frame.chalupatech.com"   # or whatever the operator's bao URL is
bao login                                                  # interactive
bao token lookup | head -5                                 # confirm token is valid
```

- [ ] **Step 1-2: Create the `postgres/whisparr` KV-v2 entry**

```bash
WHISPARR_PG_PW="$(openssl rand -base64 24)"
bao kv put postgres/whisparr \
  username=whisparr \
  password="${WHISPARR_PG_PW}" \
  main_db=whisparr_main \
  log_db=whisparr_log
bao kv get postgres/whisparr
```

Expected: the four keys readable. The generated password will be reused by CNPG (which reads it via the synthesized `whisparr-pg` K8s Secret).

- [ ] **Step 1-3: Create the `whisparr-nzbget/credentials` KV-v2 entry**

The operator must decide: reuse the same Usenet provider account as the main NzbGet, or use a different one. This plan assumes the operator already has the provider host/username/password in hand.

```bash
NZBGET_CONTROL_PW="$(openssl rand -base64 24)"
bao kv put whisparr-nzbget/credentials \
  provider-host="<usenet provider host>" \
  provider-username="<usenet username>" \
  provider-password="<usenet password>" \
  control-password="${NZBGET_CONTROL_PW}"
bao kv get whisparr-nzbget/credentials
```

Expected: the four keys readable. **Save the generated `control-password` somewhere accessible** — the operator needs to paste it into Whisparr's download-client UI in Task 6.

- [ ] **Step 1-4: Confirm both paths exist**

```bash
bao kv list postgres/    | grep -w whisparr
bao kv list whisparr-nzbget/ | grep -w credentials
```

Expected: both `grep`s return a hit.

---

## Task 2: Create subdirectories on the private NFS share *(manual operator runbook — no PR)*

bjw-s `subPath` mounts require the directory to exist before pod start, otherwise the pod fails with `MountVolume.SetUp failed for volume ... no such file or directory`.

**Files:** none. Manual TrueNAS-side action.

- [ ] **Step 2-1: SSH to TrueNAS and create the four subdirectories**

```bash
ssh root@192.168.1.40 'mkdir -p \
  /mnt/PlexMedia/WhispArr/Configs/whisparr \
  /mnt/PlexMedia/WhispArr/Configs/nzbget \
  /mnt/PlexMedia/WhispArr/Media \
  /mnt/PlexMedia/WhispArr/Downloads \
  && ls -la /mnt/PlexMedia/WhispArr/'
```

Expected: directory listing shows `Configs/`, `Media/`, `Downloads/`. Ownership is irrelevant — Maproot=root on the NFS export squashes the in-pod UID to root on the wire.

- [ ] **Step 2-2: Verify Configs subtree**

```bash
ssh root@192.168.1.40 'ls -la /mnt/PlexMedia/WhispArr/Configs/'
```

Expected: contains `whisparr/` and `nzbget/`. If either is missing, re-run Step 2-1.

---

## Task 3: Implementation PR — `feat/whisparr`

Single feature branch lands all chart code: arrs-pg additions (role + DB statements + new ExternalSecret + docstring) and the new `gitops/apps/media/whisparr/` wrapper (Chart, values, PV, PVC, NzbGet ExternalSecret, IngressRoute).

**Files:**

- Modify: `gitops/apps/media/arrs-pg/Chart.yaml`
- Modify: `gitops/apps/media/arrs-pg/templates/cluster.yaml`
- Create: `gitops/apps/media/arrs-pg/templates/whisparr-externalsecret.yaml`
- Create: `gitops/apps/media/whisparr/Chart.yaml`
- Create: `gitops/apps/media/whisparr/Chart.lock` *(generated by `helm dependency update`)*
- Create: `gitops/apps/media/whisparr/.helmignore`
- Create: `gitops/apps/media/whisparr/values.yaml`
- Create: `gitops/apps/media/whisparr/templates/pv-whisparr.yaml`
- Create: `gitops/apps/media/whisparr/templates/pvc-whisparr.yaml`
- Create: `gitops/apps/media/whisparr/templates/whisparr-nzbget-externalsecret.yaml`
- Create: `gitops/apps/media/whisparr/templates/ingressroute.yaml`

- [ ] **Step 3-1: Cut a feature branch off latest main**

```bash
git fetch origin
git checkout -b feat/whisparr origin/main
git status
```

Expected: branch `feat/whisparr` based on the latest `origin/main`, working tree clean.

- [ ] **Step 3-2: Edit `gitops/apps/media/arrs-pg/Chart.yaml`**

Update the description docstring so it accurately enumerates the new role + databases. Replace the existing description block with:

```yaml
apiVersion: v2
name: arrs-pg-wrapper
description: |
  Wrapper chart for the shared arr-stack PostgreSQL Cluster (CNPG).
  Owns the Cluster CRD instance plus 5 ExternalSecrets that pull the
  superuser + per-app credentials from OpenBao. Four application
  users (sonarr, radarr, seerr, whisparr) and seven databases
  (sonarr_main, sonarr_log, radarr_main, radarr_log, seerr,
  whisparr_main, whisparr_log) are provisioned by the Cluster
  bootstrap (postInitApplicationSQL runs only on initial bootstrap;
  whisparr_main and whisparr_log are created manually against the
  live cluster — see Task 4 of the implementation plan).
type: application
version: 0.1.0
appVersion: "16"
```

Diff to confirm:

```bash
git diff gitops/apps/media/arrs-pg/Chart.yaml
```

Expected: only the `description` block lines change; `version` is unchanged (no bump needed since templates aren't structurally new).

- [ ] **Step 3-3: Edit `gitops/apps/media/arrs-pg/templates/cluster.yaml` — add whisparr role and databases to `postInitApplicationSQL`**

Find the existing `postInitApplicationSQL:` block and add the three new lines for the role, the two new DATABASE lines, and the two new GRANT lines. The block should end up reading:

```yaml
      postInitApplicationSQL:
        - CREATE ROLE sonarr WITH LOGIN;
        - CREATE ROLE radarr WITH LOGIN;
        - CREATE ROLE seerr WITH LOGIN;
        - CREATE ROLE whisparr WITH LOGIN;
        - CREATE DATABASE sonarr_main OWNER sonarr;
        - CREATE DATABASE sonarr_log OWNER sonarr;
        - CREATE DATABASE radarr_main OWNER radarr;
        - CREATE DATABASE radarr_log OWNER radarr;
        - CREATE DATABASE seerr OWNER seerr;
        - CREATE DATABASE whisparr_main OWNER whisparr;
        - CREATE DATABASE whisparr_log OWNER whisparr;
        - GRANT ALL PRIVILEGES ON DATABASE sonarr_main TO sonarr;
        - GRANT ALL PRIVILEGES ON DATABASE sonarr_log TO sonarr;
        - GRANT ALL PRIVILEGES ON DATABASE radarr_main TO radarr;
        - GRANT ALL PRIVILEGES ON DATABASE radarr_log TO radarr;
        - GRANT ALL PRIVILEGES ON DATABASE seerr TO seerr;
        - GRANT ALL PRIVILEGES ON DATABASE whisparr_main TO whisparr;
        - GRANT ALL PRIVILEGES ON DATABASE whisparr_log TO whisparr;
```

These lines are no-ops on the live cluster (postInitApplicationSQL only runs at initdb); they exist so a future rebuild has the full spec. Task 4 below issues the same statements against the live cluster.

- [ ] **Step 3-4: Edit `gitops/apps/media/arrs-pg/templates/cluster.yaml` — add `whisparr` to `managed.roles`**

Find the existing `managed.roles:` block at the bottom of the cluster spec. Append a fourth role entry after `seerr`:

```yaml
  managed:
    roles:
      - name: sonarr
        ensure: present
        login: true
        passwordSecret:
          name: sonarr-pg
        connectionLimit: 25
      - name: radarr
        ensure: present
        login: true
        passwordSecret:
          name: radarr-pg
        connectionLimit: 25
      - name: seerr
        ensure: present
        login: true
        passwordSecret:
          name: seerr-pg
        connectionLimit: 25
      - name: whisparr
        ensure: present
        login: true
        passwordSecret:
          name: whisparr-pg
        connectionLimit: 25
```

CNPG will reconcile this on next loop and create the `whisparr` role with the password from the `whisparr-pg` Secret that the new ExternalSecret synthesizes in the next step.

Diff to confirm:

```bash
git diff gitops/apps/media/arrs-pg/templates/cluster.yaml
```

Expected: only added lines (3 in postInitApplicationSQL block, 6 in managed.roles).

- [ ] **Step 3-5: Create `gitops/apps/media/arrs-pg/templates/whisparr-externalsecret.yaml`**

Mirror `radarr-externalsecret.yaml` exactly, just changing every `radarr` → `whisparr`:

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

The double-templated `{{ `{{ .username }}` }}` syntax is required because Helm processes this file first; the inner `{{ .username }}` must reach ESO unevaluated.

Verify byte-for-byte parity with the radarr template (ignoring `s/radarr/whisparr/`):

```bash
diff <(sed 's/radarr/whisparr/g' gitops/apps/media/arrs-pg/templates/radarr-externalsecret.yaml) \
     gitops/apps/media/arrs-pg/templates/whisparr-externalsecret.yaml
```

Expected: no output (only the substitution differs).

- [ ] **Step 3-6: Create the whisparr wrapper directory**

```bash
mkdir -p gitops/apps/media/whisparr/templates
```

- [ ] **Step 3-7: Create `gitops/apps/media/whisparr/Chart.yaml`**

```yaml
apiVersion: v2
name: whisparr-wrapper
description: |
  Wrapper chart for Whisparr (v3 "Eros") plus a dedicated NzbGet
  download client. Both controllers live under one Helm release and
  share only the private NFS PVC (media-whisparr) backed by the
  TrueNAS export at /mnt/PlexMedia/WhispArr. Whisparr stores Postgres
  state in the shared arrs-pg cluster; NzbGet has no DB.
type: application
version: 0.1.0
appVersion: "3.3.3"
dependencies:
  - name: app-template
    version: 4.4.0
    repository: https://bjw-s-labs.github.io/helm-charts/
```

If Step P-5 surfaced a newer 4.x release, bump `version: 4.4.0` here to match (stay within 4.x).

- [ ] **Step 3-8: Generate Chart.lock + vendor app-template tarball**

```bash
helm dependency update gitops/apps/media/whisparr/
ls gitops/apps/media/whisparr/
cat gitops/apps/media/whisparr/Chart.lock
```

Expected: `Chart.lock` file present; `charts/` directory present with `app-template-4.4.0.tgz`. The `charts/` directory is gitignored (`.gitignore` line `gitops/apps/*/*/charts/`).

- [ ] **Step 3-9: Create `gitops/apps/media/whisparr/.helmignore`**

```
.git/
.gitignore
.DS_Store
*.swp
*.swo
```

Verify byte-for-byte parity with the existing wrapper:

```bash
diff gitops/apps/media/radarr/.helmignore gitops/apps/media/whisparr/.helmignore
```

Expected: no output.

- [ ] **Step 3-10: Create `gitops/apps/media/whisparr/values.yaml`**

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
            liveness:
              enabled: true
              custom: true
              spec:
                tcpSocket:
                  port: 6789
                initialDelaySeconds: 30
                periodSeconds: 30
            readiness:
              enabled: true
              custom: true
              spec:
                tcpSocket:
                  port: 6789
                initialDelaySeconds: 5
                periodSeconds: 10
            startup:
              enabled: false
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

If Step P-4 surfaced a different verified Whisparr tag, replace `tag: v3-v3.3.3` with the verified tag and update `appVersion` in Step 3-7 to match.

- [ ] **Step 3-11: Create `gitops/apps/media/whisparr/templates/pv-whisparr.yaml`**

```yaml
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
    storage: 10Ti
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

- [ ] **Step 3-12: Create `gitops/apps/media/whisparr/templates/pvc-whisparr.yaml`**

```yaml
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

- [ ] **Step 3-13: Create `gitops/apps/media/whisparr/templates/whisparr-nzbget-externalsecret.yaml`**

Mirrors `gitops/apps/media/nzbget/templates/nzbget-credentials-externalsecret.yaml`, swapped over to the new Bao path + Secret name:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: whisparr-nzbget-credentials
  namespace: media
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: whisparr-nzbget-credentials
    creationPolicy: Owner
  data:
    - secretKey: provider-host
      remoteRef:
        key: whisparr-nzbget/credentials
        property: provider-host
    - secretKey: provider-username
      remoteRef:
        key: whisparr-nzbget/credentials
        property: provider-username
    - secretKey: provider-password
      remoteRef:
        key: whisparr-nzbget/credentials
        property: provider-password
    - secretKey: control-password
      remoteRef:
        key: whisparr-nzbget/credentials
        property: control-password
```

- [ ] **Step 3-14: Create `gitops/apps/media/whisparr/templates/ingressroute.yaml`**

Four routes: web + websecure × whisparr + whisparr-nzbget. Each web route uses the shared `redirect-to-https` Middleware (in the media namespace, owned by the nzbget wrapper). Each websecure route uses `tls: {}` to pick up Traefik's default TLSStore.

```yaml
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: whisparr-http
  namespace: media
  annotations:
    external-dns.alpha.kubernetes.io/target: "192.168.1.230"
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`whisparr.frame.chalupatech.com`)
      kind: Rule
      services:
        - name: whisparr
          port: 6969
      middlewares:
        - name: redirect-to-https
          namespace: media
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: whisparr-https
  namespace: media
  annotations:
    external-dns.alpha.kubernetes.io/target: "192.168.1.230"
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`whisparr.frame.chalupatech.com`)
      kind: Rule
      services:
        - name: whisparr
          port: 6969
  tls: {}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: whisparr-nzbget-http
  namespace: media
  annotations:
    external-dns.alpha.kubernetes.io/target: "192.168.1.230"
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`whisparr-nzbget.frame.chalupatech.com`)
      kind: Rule
      services:
        - name: whisparr-nzbget
          port: 6789
      middlewares:
        - name: redirect-to-https
          namespace: media
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: whisparr-nzbget-https
  namespace: media
  annotations:
    external-dns.alpha.kubernetes.io/target: "192.168.1.230"
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`whisparr-nzbget.frame.chalupatech.com`)
      kind: Rule
      services:
        - name: whisparr-nzbget
          port: 6789
  tls: {}
```

The `external-dns.alpha.kubernetes.io/target: "192.168.1.230"` annotation on **all four** routes is load-bearing — external-dns silently skips records without it (memory: `project_external_dns_target_annotation`).

- [ ] **Step 3-15: yamllint locally**

```bash
yamllint gitops/
```

Expected: no output (clean). If a warning fires, fix in place — CI's `yamllint gitops/` step (`.github/workflows/gitops.yml`) runs the same lint with the same `.yamllint.yml` config and will fail on warnings.

- [ ] **Step 3-16: Local helm template + kubeconform for the whisparr wrapper**

This replicates CI's lint job (`.github/workflows/gitops.yml`). If it passes here, the PR check will pass.

```bash
helm template whisparr gitops/apps/media/whisparr/ \
  --api-versions monitoring.coreos.com/v1 \
  --api-versions monitoring.coreos.com/v1/ServiceMonitor \
  --api-versions monitoring.coreos.com/v1/PodMonitor \
  --api-versions monitoring.coreos.com/v1/PrometheusRule \
  --api-versions external-secrets.io/v1 \
  --api-versions traefik.io/v1alpha1 \
  | tee /tmp/whisparr-rendered.yaml \
  | kubeconform -strict -ignore-missing-schemas -summary \
      -skip 'VMSingle,VMAgent,VMServiceScrape,VMPodScrape,VMNodeScrape,VMRule,VMUser,VMAlertmanager,VMAlert,VMCluster,VMAuth' \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected from kubeconform: `Summary: N resources found ... 0 invalid, 0 errors`.

Inspect the rendered manifest:

```bash
grep -E '^kind:|^  name:|image:|hostPath|hostNetwork|privileged' /tmp/whisparr-rendered.yaml
```

Expected resource kinds in this order: `PersistentVolume`, `PersistentVolumeClaim`, `ExternalSecret` (whisparr-nzbget-credentials), `Service` (×2: whisparr, whisparr-nzbget), `Deployment` (×2), `IngressRoute` (×4). No `hostPath`, no `hostNetwork`, no `privileged: true`. Images: `ghcr.io/hotio/whisparr:v3-v3.3.3` and `lscr.io/linuxserver/nzbget:latest`.

```bash
# Confirm both controllers, both services, both ingress route pairs are present
grep -c '^kind: Deployment' /tmp/whisparr-rendered.yaml       # expect: 2
grep -c '^kind: Service' /tmp/whisparr-rendered.yaml          # expect: 2
grep -c '^kind: IngressRoute' /tmp/whisparr-rendered.yaml     # expect: 4
grep -c '^kind: PersistentVolume$' /tmp/whisparr-rendered.yaml # expect: 1
grep -c '^kind: PersistentVolumeClaim' /tmp/whisparr-rendered.yaml # expect: 1
grep -c '^kind: ExternalSecret' /tmp/whisparr-rendered.yaml   # expect: 1
```

- [ ] **Step 3-17: Local helm template + kubeconform for the modified arrs-pg wrapper**

```bash
helm dependency update gitops/apps/media/arrs-pg/
helm template arrs-pg gitops/apps/media/arrs-pg/ \
  --api-versions monitoring.coreos.com/v1 \
  --api-versions monitoring.coreos.com/v1/ServiceMonitor \
  --api-versions external-secrets.io/v1 \
  --api-versions postgresql.cnpg.io/v1 \
  | tee /tmp/arrs-pg-rendered.yaml \
  | kubeconform -strict -ignore-missing-schemas -summary \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: `0 invalid, 0 errors`.

Inspect:

```bash
grep -E 'CREATE ROLE whisparr|CREATE DATABASE whisparr_|GRANT.*whisparr' /tmp/arrs-pg-rendered.yaml
# Expected: at least 5 hits (1 CREATE ROLE + 2 CREATE DATABASE + 2 GRANT)

grep -A 6 'name: whisparr$' /tmp/arrs-pg-rendered.yaml | head -10
# Expected: the managed.roles entry with `passwordSecret: name: whisparr-pg`

grep -A 2 'name: whisparr-pg-creds' /tmp/arrs-pg-rendered.yaml | head -10
# Expected: the new ExternalSecret manifest
```

- [ ] **Step 3-18: Stage and commit**

```bash
git add gitops/apps/media/arrs-pg/Chart.yaml \
        gitops/apps/media/arrs-pg/templates/cluster.yaml \
        gitops/apps/media/arrs-pg/templates/whisparr-externalsecret.yaml \
        gitops/apps/media/whisparr/Chart.yaml \
        gitops/apps/media/whisparr/Chart.lock \
        gitops/apps/media/whisparr/.helmignore \
        gitops/apps/media/whisparr/values.yaml \
        gitops/apps/media/whisparr/templates/pv-whisparr.yaml \
        gitops/apps/media/whisparr/templates/pvc-whisparr.yaml \
        gitops/apps/media/whisparr/templates/whisparr-nzbget-externalsecret.yaml \
        gitops/apps/media/whisparr/templates/ingressroute.yaml
git status
```

Expected: 11 files staged (3 under arrs-pg, 8 under whisparr). No `charts/` directories should appear under either path — both are gitignored.

```bash
git commit -m "$(cat <<'EOF'
feat(media): add whisparr — Whisparr v3 + dedicated NzbGet on a private NFS share

New wrapper chart at gitops/apps/media/whisparr/ consuming bjw-s
app-template 4.4.0 with two controllers (whisparr + whisparr-nzbget)
in one Helm release. Picked up automatically by the existing
media-apps ApplicationSet. Storage is a brand-new static NFS PV/PVC
(media-whisparr) backed by the operator-provisioned private share
at 192.168.1.40:/mnt/PlexMedia/WhispArr — no overlap with the
existing media-plexmedia PVC.

Whisparr stores state in the shared arrs-pg CNPG Postgres cluster via
a new whisparr role + whisparr_main / whisparr_log databases.
Credentials are sourced from OpenBao via two new ExternalSecrets:
postgres/whisparr (Postgres creds, in the arrs-pg chart) and
whisparr-nzbget/credentials (Usenet provider + NzbGet control
password, in the whisparr chart).

Exposes whisparr.frame.chalupatech.com and
whisparr-nzbget.frame.chalupatech.com over HTTPS via Traefik's
wildcard cert.

Post-merge operator steps: kubectl exec into the arrs-pg primary to
manually CREATE DATABASE whisparr_main and whisparr_log (CNPG's
postInitApplicationSQL only runs at initial bootstrap), then complete
first-run UI setup in both Whisparr and the dedicated NzbGet.

Spec: docs/superpowers/specs/2026-05-11-whisparr-design.md
Plan: docs/superpowers/plans/2026-05-11-whisparr-plan.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3-19: Push branch and open PR**

```bash
git push -u origin feat/whisparr
gh pr create \
  --title "feat(media): add whisparr — v3 + dedicated NzbGet on private NFS share" \
  --body "$(cat <<'EOF'
## Summary

- New wrapper at `gitops/apps/media/whisparr/` with **two controllers** under one bjw-s `app-template` 4.4.0 release: Whisparr v3 (Eros) plus a dedicated `whisparr-nzbget`.
- New dedicated `media-whisparr` static NFS PV/PVC for the operator-provisioned private share at `192.168.1.40:/mnt/PlexMedia/WhispArr`. The existing `media-plexmedia` PVC is intentionally not mounted.
- Postgres state in the shared `arrs-pg` cluster: new `whisparr` managed role + `whisparr_main` / `whisparr_log` databases, credentials from OpenBao `postgres/whisparr`.
- Two new ExternalSecrets: `whisparr-pg-creds` (in arrs-pg chart) and `whisparr-nzbget-credentials` (in whisparr chart).
- Four IngressRoutes — `whisparr.frame.chalupatech.com` and `whisparr-nzbget.frame.chalupatech.com`, each as the web+websecure pair.
- ApplicationSet picks up the new directory automatically.

## Pre-merge operator steps (already done)

- `bao kv put postgres/whisparr ...` populated.
- `bao kv put whisparr-nzbget/credentials ...` populated.
- `/mnt/PlexMedia/WhispArr/{Configs/whisparr,Configs/nzbget,Media,Downloads}` created on TrueNAS.

## Post-merge operator steps (still TODO at merge time)

- `kubectl exec` into the arrs-pg primary to `CREATE DATABASE whisparr_main / whisparr_log` (CNPG's `postInitApplicationSQL` only runs once at initdb).
- `kubectl -n media rollout restart deploy/whisparr` after the databases exist.
- Whisparr-NzbGet UI: paste Usenet provider config from OpenBao.
- Whisparr UI: complete first-run wizard, configure download client → `whisparr-nzbget.media.svc:6789`.

## Test plan

- [ ] `GitOps Lint & Render` PR check is green.
- [ ] After merge, `kubectl -n argocd get application whisparr arrs-pg` shows both `Synced/Healthy`.
- [ ] `kubectl -n media get pv,pvc media-whisparr` shows both `Bound`.
- [ ] `kubectl -n media get externalsecret whisparr-pg-creds whisparr-nzbget-credentials` shows both `SecretSynced`.
- [ ] `kubectl -n media exec arrs-pg-1 -- psql -U postgres -c '\du' | grep whisparr` returns the role.
- [ ] After Task 4 (manual DB creation), `kubectl -n media get pods -l app.kubernetes.io/instance=whisparr` shows 2 pods `1/1 Ready`.
- [ ] `curl -I https://whisparr.frame.chalupatech.com/ping` returns `HTTP/2 200`.
- [ ] `curl -I https://whisparr-nzbget.frame.chalupatech.com/` returns `HTTP/2 401` (NzbGet Basic Auth challenge — means it's up).

## Spec / Plan

- Spec: `docs/superpowers/specs/2026-05-11-whisparr-design.md`
- Plan: `docs/superpowers/plans/2026-05-11-whisparr-plan.md`
EOF
)"
```

- [ ] **Step 3-20: Wait for `GitOps Lint & Render` PR check to pass, then merge**

```bash
gh pr checks --watch
```

Wait until the `GitOps Lint & Render / Lint and dry-render gitops/` job reports `pass`. If it fails:

1. Read the failure: `gh pr checks` → click the job URL, or `gh run view --log-failed <runid>`.
2. Fix in a new commit on `feat/whisparr` (do **not** amend — keep a clean PR commit trail per CLAUDE.md).
3. `git push` and re-watch.

Before merging, double-check the PR is still open and not closed mid-session (memory `feedback_check_pr_merged`):

```bash
gh pr view --json state,number
# Expected: state=OPEN
```

When green:

```bash
gh pr merge --merge --delete-branch
git checkout main
git pull --ff-only origin main
git log --oneline -3
```

Expected: new commit at the tip of `main`.

---

## Task 4: Manually create `whisparr_main` and `whisparr_log` in the live cluster

CNPG's `managed.roles` will create the `whisparr` role on next reconcile (which `arrs-pg`'s Argo sync triggers), but it does **not** create databases. The two databases must be created manually because the cluster's `postInitApplicationSQL` only ran at initial bootstrap.

**Files:** none. Live-cluster operation.

- [ ] **Step 4-1: Wait for the `whisparr` role to appear**

CNPG reconciliation runs every few minutes. After the PR merges, poll:

```bash
for i in $(seq 1 60); do
  if kubectl -n media exec arrs-pg-1 -- psql -U postgres -tA -c "SELECT 1 FROM pg_roles WHERE rolname='whisparr';" 2>/dev/null | grep -q 1; then
    echo "whisparr role appeared after ${i} polls"
    break
  fi
  sleep 10
done
```

Expected: a "whisparr role appeared after N polls" line. If it doesn't appear within 10 minutes:

```bash
kubectl -n argocd get application arrs-pg
kubectl -n argocd describe application arrs-pg | tail -30
kubectl -n media logs -l cnpg.io/cluster=arrs-pg,cnpg.io/instanceRole=primary --tail=50
```

Investigate before continuing.

- [ ] **Step 4-2: Confirm the `whisparr-pg` Secret exists and has correct shape**

```bash
kubectl -n media get externalsecret whisparr-pg-creds
kubectl -n media get secret whisparr-pg -o json \
  | jq -r '.data | keys[]' | sort
```

Expected ExternalSecret: `STATUS=SecretSynced`. Expected secret keys: `log_db main_db password username` (alphabetical).

If the ExternalSecret is in `SecretSyncError`, re-check OpenBao (`bao kv get postgres/whisparr`) and `kubectl -n media describe externalsecret whisparr-pg-creds` for the underlying error.

- [ ] **Step 4-3: Create the two databases and grant privileges**

```bash
kubectl -n media exec -it arrs-pg-1 -- psql -U postgres <<'SQL'
CREATE DATABASE whisparr_main OWNER whisparr;
CREATE DATABASE whisparr_log  OWNER whisparr;
GRANT ALL PRIVILEGES ON DATABASE whisparr_main TO whisparr;
GRANT ALL PRIVILEGES ON DATABASE whisparr_log  TO whisparr;
SQL
```

Expected: four `GRANT`/`CREATE DATABASE` confirmation lines, no errors. If either database already exists (e.g. you re-ran the task) you'll see `ERROR: database "whisparr_main" already exists` — safe to ignore for that specific line; the GRANT is still useful and idempotent.

- [ ] **Step 4-4: Verify the databases and their owner**

```bash
kubectl -n media exec arrs-pg-1 -- psql -U postgres -c '\l' | grep -E 'whisparr_(main|log)'
```

Expected: two rows, both owned by `whisparr`.

- [ ] **Step 4-5: Restart the Whisparr Deployment so it re-resolves the now-present databases**

By this point the Whisparr pod has been CrashLoopBackOff'ing because its first DB write hit "database whisparr_main does not exist". Force a roll:

```bash
kubectl -n media rollout restart deploy/whisparr
kubectl -n media rollout status deploy/whisparr --timeout=180s
```

Expected: `deployment "whisparr" successfully rolled out`. The pod transitions to 1/1 Ready within ~60s.

---

## Task 5: Post-merge cluster verification

**Files:** none. Read-only kubectl + curl verification.

- [ ] **Step 5-1: Argo Applications healthy**

```bash
kubectl -n argocd get application whisparr arrs-pg
```

Expected: both `Synced` and `Healthy`.

- [ ] **Step 5-2: PV/PVC bound**

```bash
kubectl get pv media-whisparr
kubectl -n media get pvc media-whisparr
```

Expected: PV `Bound` with capacity `10Ti`, RWX, reclaim `Retain`; PVC `Bound` to `media-whisparr`.

- [ ] **Step 5-3: ExternalSecrets synced**

```bash
kubectl -n media get externalsecret whisparr-pg-creds whisparr-nzbget-credentials
```

Expected: both `STATUS=SecretSynced`.

- [ ] **Step 5-4: Secrets materialized with correct shape**

```bash
kubectl -n media get secret whisparr-pg whisparr-nzbget-credentials
kubectl -n media get secret whisparr-pg -o json | jq -r '.data | keys[]' | sort
kubectl -n media get secret whisparr-nzbget-credentials -o json | jq -r '.data | keys[]' | sort
```

Expected: both Secrets exist. `whisparr-pg` keys: `log_db main_db password username`. `whisparr-nzbget-credentials` keys: `control-password provider-host provider-password provider-username`.

- [ ] **Step 5-5: Pods Ready**

```bash
kubectl -n media get pods -l app.kubernetes.io/instance=whisparr
```

Expected: two pods, both `1/1 Ready`, names `whisparr-<hash>` and `whisparr-nzbget-<hash>`.

- [ ] **Step 5-6: Mounted subPaths reachable from inside the pods**

```bash
kubectl -n media exec deploy/whisparr -- sh -c 'ls -la /config /media /downloads'
kubectl -n media exec deploy/whisparr-nzbget -- sh -c 'ls -la /config /downloads'
```

Expected: all five directories listable. The two `/downloads` paths should share the same NFS subPath (you can sanity-check with `stat -c %i` on a file the operator drops in `/downloads` from either pod and verify the same inode shows from the other).

- [ ] **Step 5-7: Whisparr health endpoint reachable in-cluster**

```bash
kubectl -n media exec deploy/whisparr -- wget -qO- http://localhost:6969/ping
```

Expected: returns an `OK`/200 health response (the Servarr `/ping` endpoint).

- [ ] **Step 5-8: NzbGet control port reachable in-cluster**

```bash
kubectl -n media exec deploy/whisparr-nzbget -- sh -c 'apk add --no-cache busybox-extras >/dev/null 2>&1; nc -zv localhost 6789 2>&1 || true'
```

Expected: connection succeeds (LinuxServer image has `nc`).

- [ ] **Step 5-9: IngressRoutes present**

```bash
kubectl -n media get ingressroute | grep whisparr
```

Expected: four routes (`whisparr-http`, `whisparr-https`, `whisparr-nzbget-http`, `whisparr-nzbget-https`).

- [ ] **Step 5-10: DNS resolution and TLS from a LAN client**

```bash
dig +short whisparr.frame.chalupatech.com whisparr-nzbget.frame.chalupatech.com
curl -I https://whisparr.frame.chalupatech.com/ping
curl -I https://whisparr-nzbget.frame.chalupatech.com/
```

Expected:
- Both `dig`s resolve to `192.168.1.230`.
- `curl` to whisparr `/ping`: `HTTP/2 200`, no `-k` needed (valid wildcard cert).
- `curl` to whisparr-nzbget root: `HTTP/2 401` with a `WWW-Authenticate: Basic` header — means NzbGet is up and challenging.

- [ ] **Step 5-11: Whisparr → Postgres connectivity confirmed**

```bash
kubectl -n media logs deploy/whisparr --tail=200 | grep -iE 'postgres|database' | head -20
```

Expected: lines indicating Whisparr connected to Postgres at `arrs-pg-rw.media.svc.cluster.local:5432` and migrated schema in `whisparr_main`. No `database "whisparr_main" does not exist` lines (those would indicate Task 4 was skipped).

- [ ] **Step 5-12: Deploy pipeline reconciliation check**

```bash
gh run list --workflow=deploy.yml --limit 3
```

Expected: the latest `deploy.yml` run after the merge shows the `Verify GitOps reconciliation` step green. If that step failed, dig into the run log — it's the canonical post-merge gate.

---

## Task 6: First-run UI setup *(manual operator runbook — no PR)*

**Files:** none. Operator-driven configuration via the web UIs of Whisparr and the dedicated NzbGet.

- [ ] **Step 6-1: Log in to the new NzbGet and seed the Usenet provider**

1. Open `https://whisparr-nzbget.frame.chalupatech.com` in a browser. Green padlock expected.
2. HTTP Basic Auth challenge: username `nzbget`, password = the `control-password` from OpenBao `whisparr-nzbget/credentials` (saved in Step 1-3).
3. Settings → **News Servers** → server `s1` → paste:
   - `Host` = `provider-host` from OpenBao
   - `Port` = whichever port the provider uses (typically `563` SSL or `119` plain)
   - `Username` / `Password` from OpenBao
   - `Connections` = whatever the operator's provider plan allows (typical: 20–50)
   - `Encryption` = on (matches port)
4. Settings → **Categories** → add a `whisparr` category with destination `${MainDir}/whisparr` *(or leave defaults — Whisparr writes to the shared `/downloads`, NzbGet will subfolder per category)*.
5. Settings → **Security** → confirm `ControlUsername = nzbget` and `ControlPassword` is non-empty (it should already be — sourced from env at start).
6. Save. Status → "News server `s1` OK" confirms the provider creds are good.

- [ ] **Step 6-2: Whisparr first-run wizard**

1. Open `https://whisparr.frame.chalupatech.com`. Green padlock expected.
2. Step through the first-run wizard. Set auth method (Forms is typical), create the admin account, pick general settings.
3. Settings → **General** → confirm "PostgreSQL" appears as the active database backend (with `whisparr_main` as the main DB and `whisparr_log` as the log DB).

- [ ] **Step 6-3: Wire Whisparr → whisparr-nzbget**

Settings → **Download Clients** → Add → NzbGet:

| Field | Value |
|---|---|
| Name | `whisparr-nzbget` |
| Host | `whisparr-nzbget.media.svc` |
| Port | `6789` |
| Username | `nzbget` |
| Password | `control-password` from OpenBao |
| Category | `whisparr` |
| Use SSL | off |

Click **Test** — expect a green check. Save.

- [ ] **Step 6-4: Add an indexer**

Settings → **Indexers** → Add → operator's indexer of choice (Prowlarr-managed or direct). This is operator preference, out of scope for this plan.

- [ ] **Step 6-5: End-to-end smoke test**

Pick a sample scene Whisparr would track, search, queue. Verify:

```bash
# NzbGet sees the download
kubectl -n media exec deploy/whisparr-nzbget -- ls -la /downloads
# Whisparr media library receives the import
kubectl -n media exec deploy/whisparr -- ls -la /media
```

Expected: `/downloads` shows a working file during fetch then disappears after import; `/media` shows the imported file.

---

## Done

End state:

- `https://whisparr.frame.chalupatech.com` and `https://whisparr-nzbget.frame.chalupatech.com` serve over HTTPS.
- Both pods 1/1 Ready, owned by Argo Application `whisparr`.
- All on-disk state on the private NFS share `192.168.1.40:/mnt/PlexMedia/WhispArr`.
- Postgres state in the shared `arrs-pg` cluster, owned by the new `whisparr` role.
- Whisparr → whisparr-nzbget pipeline functioning end-to-end with a real scene downloaded and imported.
- The shared media stack (sonarr, radarr, seerr, nzbget, tdarr, clonarr) is entirely undisturbed.
