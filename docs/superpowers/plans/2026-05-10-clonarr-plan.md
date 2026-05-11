# Clonarr Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Clonarr (a TRaSH Guides sync UI for Radarr/Sonarr) as a sixth media-tier app on the Talos cluster. After this plan: `clonarr.frame.chalupatech.com` serves over HTTPS, Argo shows a `clonarr` Application Synced/Healthy, the pod runs 1/1 with `/config` bound to the shared NFS share, and the operator has configured Sonarr + Radarr instances via the web UI.

**Architecture:** One wrapper chart at `gitops/apps/media/clonarr/` consuming bjw-s `app-template` 4.4.0. The existing `media-apps` ApplicationSet picks it up automatically via its `directories.path: gitops/apps/media/*` generator — no ApplicationSet changes. Storage reuses the existing `media-plexmedia` RWX NFS PVC with a new `Configs/clonarr/` subPath. Ingress reuses the existing wildcard TLS cert and the existing `redirect-to-https` Middleware owned by the NzbGet wrapper. No new Secrets, no new ExternalSecret, no new OpenBao policy.

**Tech Stack:** Helm 3, kubeconform 0.6.x, yamllint 1.35.x, ArgoCD ApplicationSet (existing), bjw-s `app-template` 4.4.0, Traefik 3.x IngressRoute CRDs (existing), Clonarr `ghcr.io/prophetse7en/clonarr:2.5.6` (pin to current at impl time).

**Reference spec:** `docs/superpowers/specs/2026-05-10-clonarr-design.md`.

**Branching strategy:** One feature branch, one PR. Task 1 is a manual operator runbook on TrueNAS (no PR). Task 2 is the PR. Tasks 3 and 4 are post-merge verification + post-deploy operator setup (no PRs).

**Pre-existing prerequisites (already satisfied):**

- All 6 media Applications Synced/Healthy: `nzbget`, `sonarr`, `radarr`, `seerr`, `tdarr`, `arrs-pg`.
- Static PV `media-plexmedia` Bound, PVC `media-plexmedia` Bound in `media` namespace.
- Middleware `redirect-to-https` exists in `media` namespace (owned by NzbGet wrapper).
- Traefik default TLSStore covers `*.frame.chalupatech.com`.
- Unifi DNS override resolves `*.frame.chalupatech.com → 192.168.1.230` on LAN.
- external-dns + Cloudflare provider operating; TXT records visible in Cloudflare for existing media hosts.
- SSH access to TrueNAS at `192.168.1.40` (operator has credentials).
- `media-apps` ApplicationSet exists at `gitops/bootstrap/applicationsets/media.yaml` and is configured to pick up new directories under `gitops/apps/media/`.

---

## Pre-Flight: Local Tooling

The implementer must have these CLIs and a working KUBECONFIG before starting any task.

- [ ] **Step P-1: Verify local CLIs**

```bash
helm version --short                    # expect: v3.x
kubeconform -v                          # expect: v0.6+
yamllint --version                      # expect: any
gh --version                            # expect: gh version 2.x
kubectl version --client                # expect: v1.30+ (Homebrew-signed)
ssh -V                                  # expect: any OpenSSH
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
# Shared PV/PVC must be Bound
kubectl get pv media-plexmedia
kubectl -n media get pvc media-plexmedia
# Expected: STATUS=Bound for both

# Shared Middleware must exist
kubectl -n media get middleware redirect-to-https
# Expected: NAME=redirect-to-https with AGE > 0

# media-apps ApplicationSet must exist
kubectl -n argocd get applicationset media-apps
# Expected: NAME=media-apps, AGE > 0

# All five existing media Applications must be Synced/Healthy
kubectl -n argocd get application -l app.kubernetes.io/part-of=media-apps 2>/dev/null || \
  kubectl -n argocd get application | grep -E 'nzbget|sonarr|radarr|seerr|tdarr|arrs-pg'
# Expected: all show Synced and Healthy

# External-dns operating
kubectl -n external-dns get pods
# Expected: 1/1 Running

# Sonarr & Radarr Services reachable for clonarr later
kubectl -n media get svc sonarr radarr
# Expected: both ClusterIP, sonarr on 8989, radarr on 7878
```

If any check fails, do not start the plan — fix the precondition first.

- [ ] **Step P-4: Refresh the bjw-s helm repo**

```bash
helm repo add bjw-s https://bjw-s-labs.github.io/helm-charts/ || true
helm repo update bjw-s
helm search repo bjw-s/app-template --versions | head -5
```

Expected: `bjw-s/app-template` version `4.4.0` (or newer 4.x) shows up. If 4.4.0 is no longer in the index, pick the latest stable 4.x and update the Chart.yaml dependency version accordingly in Task 2 Step 2.

---

## Task 1: Create `Configs/clonarr/` on TrueNAS *(manual operator runbook — no PR)*

bjw-s `subPath` mounts require the directory to exist on the underlying NFS share before pod start. Same pattern used for `Configs/sonarr/`, `Configs/seerr/`, etc.

**Files:** none (manual TrueNAS-side action only).

- [ ] **Step 1-1: SSH to TrueNAS and create the directory**

```bash
ssh root@192.168.1.40 'mkdir -p /mnt/PlexMedia/frame/Configs/clonarr && ls -ld /mnt/PlexMedia/frame/Configs/clonarr'
```

Expected output: a single line ending in `/mnt/PlexMedia/frame/Configs/clonarr` with directory permissions. Ownership is irrelevant — the NFS share is Maproot=root, so the in-pod identity squashes to root on the wire.

- [ ] **Step 1-2: Verify the parent contains the new subdir alongside the existing five**

```bash
ssh root@192.168.1.40 'ls -1 /mnt/PlexMedia/frame/Configs/'
```

Expected: at least these entries (alphabetical, additional ones from #3's CNPG layout are also fine):

```
clonarr
nzbget
radarr
seerr
sonarr
tdarr
```

If `clonarr/` is missing, re-run 1-1. If the parent path itself doesn't exist, **stop** — `Configs/` should already exist from sub-project #3; investigate before proceeding.

---

## Task 2: Wrapper chart PR

This task lands `gitops/apps/media/clonarr/` (Chart.yaml + Chart.lock + .helmignore + values.yaml + templates/ingressroute.yaml) on a feature branch, gets the `GitOps Lint & Render` PR check green, and merges to main. The `media-apps` ApplicationSet then auto-generates a `clonarr` Application that materializes the chart on the cluster.

**Files:**
- Create: `gitops/apps/media/clonarr/Chart.yaml`
- Create: `gitops/apps/media/clonarr/Chart.lock` *(generated by `helm dependency update`)*
- Create: `gitops/apps/media/clonarr/.helmignore`
- Create: `gitops/apps/media/clonarr/values.yaml`
- Create: `gitops/apps/media/clonarr/templates/ingressroute.yaml`

- [ ] **Step 2-1: Create feature branch off main**

```bash
git fetch origin
git checkout -b feat/clonarr origin/main
git status
```

Expected: branch `feat/clonarr` based on the latest `origin/main`, working tree clean (apart from any untracked spec/plan files which are intentional).

- [ ] **Step 2-2: Create the chart directory + Chart.yaml**

```bash
mkdir -p gitops/apps/media/clonarr/templates
```

Then write `gitops/apps/media/clonarr/Chart.yaml`:

```yaml
apiVersion: v2
name: clonarr-wrapper
description: Wrapper chart for Clonarr (TRaSH Guides sync UI for Radarr/Sonarr)
type: application
version: 0.1.0
appVersion: "2.5.6"
dependencies:
  - name: app-template
    version: 4.4.0
    repository: https://bjw-s-labs.github.io/helm-charts/
```

If Step P-4 showed a newer 4.x stable, bump `version: 4.4.0` here to match — but keep within 4.x.

- [ ] **Step 2-3: Run `helm dependency update` to fetch the dependency and generate Chart.lock**

```bash
helm dependency update gitops/apps/media/clonarr/
ls gitops/apps/media/clonarr/
```

Expected: `Chart.lock` file appears; `charts/` directory appears containing `app-template-4.4.0.tgz`. The `charts/` dir is gitignored repo-wide (see `.gitignore`: `gitops/apps/*/*/charts/`).

```bash
cat gitops/apps/media/clonarr/Chart.lock
```

Expected: digest line + generated timestamp + correct repository URL.

- [ ] **Step 2-4: Create `.helmignore`**

Write `gitops/apps/media/clonarr/.helmignore`:

```
.git/
.gitignore
.DS_Store
*.swp
*.swo
```

Matches every other media wrapper byte-for-byte. Verify with `diff`:

```bash
diff gitops/apps/media/seerr/.helmignore gitops/apps/media/clonarr/.helmignore
```

Expected: no output (identical).

- [ ] **Step 2-5: Create `values.yaml`**

Write `gitops/apps/media/clonarr/values.yaml`:

```yaml
app-template:
  defaultPodOptions:
    securityContext:
      runAsNonRoot: false
      fsGroup: 568
      fsGroupChangePolicy: OnRootMismatch

  controllers:
    clonarr:
      type: deployment
      replicas: 1
      strategy: Recreate
      containers:
        main:
          image:
            repository: ghcr.io/prophetse7en/clonarr
            tag: 2.5.6
          env:
            TZ: America/Los_Angeles
            PUID: "1000"
            PGID: "1000"
            PORT: "6060"
          probes:
            liveness:
              enabled: true
              custom: true
              spec:
                httpGet:
                  path: /api/health
                  port: 6060
                initialDelaySeconds: 30
                periodSeconds: 30
                timeoutSeconds: 10
                failureThreshold: 5
            readiness:
              enabled: true
              custom: true
              spec:
                httpGet:
                  path: /api/health
                  port: 6060
                initialDelaySeconds: 5
                periodSeconds: 10
                timeoutSeconds: 5
                failureThreshold: 5
            startup:
              enabled: true
              custom: true
              spec:
                httpGet:
                  path: /api/health
                  port: 6060
                initialDelaySeconds: 10
                periodSeconds: 10
                timeoutSeconds: 5
                failureThreshold: 30
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              memory: 256Mi

  service:
    clonarr:
      controller: clonarr
      ports:
        http:
          port: 6060

  persistence:
    config:
      enabled: true
      type: persistentVolumeClaim
      existingClaim: media-plexmedia
      globalMounts:
        - path: /config
          subPath: Configs/clonarr
```

If Step P-4 showed a newer Clonarr release on GHCR (https://github.com/prophetse7en/clonarr/releases), bump `tag: 2.5.6` to the current latest at impl time and update `appVersion` in Chart.yaml to match. Stay on the same minor unless a release note says otherwise.

- [ ] **Step 2-6: Create `templates/ingressroute.yaml`**

Write `gitops/apps/media/clonarr/templates/ingressroute.yaml` — modeled exactly on `gitops/apps/media/seerr/templates/ingressroute.yaml` with names/ports/host adjusted:

```yaml
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: clonarr-http
  namespace: media
  annotations:
    external-dns.alpha.kubernetes.io/target: "192.168.1.230"
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`clonarr.frame.chalupatech.com`)
      kind: Rule
      services:
        - name: clonarr
          port: 6060
      middlewares:
        - name: redirect-to-https
          namespace: media
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: clonarr-https
  namespace: media
  annotations:
    external-dns.alpha.kubernetes.io/target: "192.168.1.230"
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`clonarr.frame.chalupatech.com`)
      kind: Rule
      services:
        - name: clonarr
          port: 6060
  tls: {}
```

The `external-dns.alpha.kubernetes.io/target: "192.168.1.230"` annotation on **both** routes is load-bearing — external-dns silently skips records without it (project memory: `project_external_dns_target_annotation`).

- [ ] **Step 2-7: yamllint locally**

```bash
yamllint gitops/apps/media/clonarr/
```

Expected: no output (clean). If you see warnings about line length or trailing spaces, fix them — CI's `yamllint gitops/` step (`.github/workflows/gitops.yml:38`) runs the same lint and will fail on warnings.

- [ ] **Step 2-8: Render with helm template and validate with kubeconform**

This replicates exactly what `gitops.yml` runs in CI (lines 40–84). If it passes locally, the PR check will pass.

```bash
helm template clonarr gitops/apps/media/clonarr/ \
  --api-versions monitoring.coreos.com/v1 \
  --api-versions monitoring.coreos.com/v1/ServiceMonitor \
  --api-versions monitoring.coreos.com/v1/PodMonitor \
  --api-versions monitoring.coreos.com/v1/PrometheusRule \
  --api-versions external-secrets.io/v1 \
  --api-versions traefik.io/v1alpha1 \
  | tee /tmp/clonarr-rendered.yaml \
  | kubeconform -strict -ignore-missing-schemas -summary \
      -skip 'VMSingle,VMAgent,VMServiceScrape,VMPodScrape,VMNodeScrape,VMRule,VMUser,VMAlertmanager,VMAlert,VMCluster,VMAuth' \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected from kubeconform: `Summary: X resources found...` with `0 invalid`, `0 errors`.

Inspect `/tmp/clonarr-rendered.yaml` for sanity:

```bash
grep -E '^kind:|name:|image:|host(P|p)ath|hostNetwork|privileged' /tmp/clonarr-rendered.yaml | head -40
```

Expected resource kinds: `Deployment`, `Service`, `IngressRoute` (x2). No `hostPath`, `hostNetwork`, or `privileged: true`. Image string: `ghcr.io/prophetse7en/clonarr:2.5.6`.

- [ ] **Step 2-9: Stage and commit**

```bash
git add gitops/apps/media/clonarr/Chart.yaml \
        gitops/apps/media/clonarr/Chart.lock \
        gitops/apps/media/clonarr/.helmignore \
        gitops/apps/media/clonarr/values.yaml \
        gitops/apps/media/clonarr/templates/ingressroute.yaml
git status
```

Expected: 5 new files staged, no modifications, no `charts/` directory included (gitignored).

Then commit:

```bash
git commit -m "$(cat <<'EOF'
feat(media): add clonarr — TRaSH Guides sync UI for Radarr/Sonarr

New wrapper chart at gitops/apps/media/clonarr/ consuming bjw-s
app-template 4.4.0. Picked up automatically by the existing media-apps
ApplicationSet. Reuses the shared media-plexmedia NFS PVC (subPath
Configs/clonarr) and the shared redirect-to-https Middleware owned by
the nzbget wrapper. Exposes clonarr.frame.chalupatech.com over HTTPS
via Traefik's wildcard cert. No new secrets — admin account + arr API
keys configured via the Clonarr web UI on first run.

Spec: docs/superpowers/specs/2026-05-10-clonarr-design.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 2-10: Push branch and open PR**

```bash
git push -u origin feat/clonarr
gh pr create \
  --title "feat(media): add clonarr — TRaSH Guides sync UI for Radarr/Sonarr" \
  --body "$(cat <<'EOF'
## Summary

- Add `gitops/apps/media/clonarr/` wrapper chart (bjw-s `app-template` 4.4.0).
- Picked up by the existing `media-apps` ApplicationSet; no ApplicationSet changes.
- Reuses shared `media-plexmedia` NFS PVC (subPath `Configs/clonarr`) and the shared `redirect-to-https` Middleware.
- Exposes `https://clonarr.frame.chalupatech.com` via Traefik wildcard cert.
- No new secrets — first-run setup + arr instance config happen via the Clonarr web UI.

## Pre-merge operator step (already done)

- `mkdir -p /mnt/PlexMedia/frame/Configs/clonarr` on TrueNAS so the subPath mount has a target.

## Test plan

- [ ] GitOps Lint & Render PR check is green.
- [ ] After merge, `kubectl -n argocd get application clonarr` shows `Synced/Healthy`.
- [ ] `kubectl -n media get pods -l app.kubernetes.io/name=clonarr` shows 1/1 Ready.
- [ ] `curl -I https://clonarr.frame.chalupatech.com/api/health` returns `HTTP/2 200` from a LAN client.
- [ ] Browser hits the host: green padlock, redirected to `/setup`.

## Spec

`docs/superpowers/specs/2026-05-10-clonarr-design.md`
EOF
)"
```

- [ ] **Step 2-11: Wait for `GitOps Lint & Render` PR check to pass, then merge**

```bash
gh pr checks --watch
```

Wait until the `GitOps Lint & Render / Lint and dry-render gitops/` job reports `pass`. If it fails, read the failure and fix in a new commit on `feat/clonarr` (do **not** amend — keep a clean PR commit trail per CLAUDE.md), then push and re-watch.

When green, merge:

```bash
gh pr merge --merge --delete-branch
```

(Use whichever merge strategy matches the project's PR settings — `--merge` is the safe default here; if the repo enforces squash, use `--squash`.)

After merge, verify your local main fast-forwards:

```bash
git checkout main
git pull --ff-only origin main
git log --oneline -3
```

Expected: the new commit is at the tip of `main`.

---

## Task 3: Post-merge cluster verification

The `media-apps` ApplicationSet polls the repo on a default interval (typically 3 min) and generates a new `clonarr` Application. With autoSync + retry, the pod should be Ready within ~5 min of merge.

**Files:** none. This task is read-only verification with kubectl + curl.

- [ ] **Step 3-1: Watch Argo generate the new Application**

```bash
for i in $(seq 1 60); do
  if kubectl -n argocd get application clonarr > /dev/null 2>&1; then
    echo "clonarr Application appeared after ${i} polls"
    break
  fi
  sleep 5
done
kubectl -n argocd get application clonarr
```

Expected within ~5 min: `SYNC STATUS=Synced`, `HEALTH STATUS=Healthy`. If it sticks `OutOfSync` for >5 min, jump to troubleshooting at the bottom of this task.

- [ ] **Step 3-2: Confirm the pod is Running and Ready**

```bash
kubectl -n media get pods -l app.kubernetes.io/name=clonarr -o wide
```

Expected: 1 pod, `READY 1/1`, `STATUS Running`, on one of the three worker nodes (.226 / .227 / .232).

Confirm the NFS mount inside the pod:

```bash
kubectl -n media exec deploy/clonarr -- ls -la /config
```

Expected: directory exists, readable. On a freshly-created `Configs/clonarr` it will start empty; Clonarr's entrypoint scaffolds `auth.json` placeholders + the data dir on first start, so within a few seconds you'll see a small set of files.

- [ ] **Step 3-3: Confirm health endpoint inside the pod**

```bash
kubectl -n media exec deploy/clonarr -- wget -qO- http://localhost:6060/api/health
```

Expected: a 200 JSON response (some shape of `{"status":"healthy"}` or similar — exact body is Clonarr-version-dependent; non-empty 200 is sufficient).

- [ ] **Step 3-4: Confirm IngressRoutes were applied**

```bash
kubectl -n media get ingressroute | grep clonarr
```

Expected: two entries — `clonarr-http` and `clonarr-https`.

```bash
kubectl -n media describe ingressroute clonarr-https | grep -A2 'Tls:\|External-Dns'
```

Expected: the `external-dns.alpha.kubernetes.io/target` annotation is present with value `192.168.1.230`; `Tls:` block is present (empty `{}` is correct — it triggers Traefik's default TLSStore).

- [ ] **Step 3-5: Confirm external-dns picked it up**

```bash
kubectl -n external-dns logs deploy/external-dns --tail=200 | grep -i clonarr
```

Expected: at least one log line showing external-dns processing `clonarr.frame.chalupatech.com` (creating TXT records or updating an existing zone). Cloudflare's free tier filters RFC 1918 A records, so no public A record will be visible in the Cloudflare dashboard — only the audit-trail TXT (per `project_cloudflare_rfc1918_filter` memory).

- [ ] **Step 3-6: Confirm LAN DNS + HTTPS from a LAN client**

From the operator's workstation (a LAN device behind the Unifi gateway, **not** the cluster):

```bash
dig +short clonarr.frame.chalupatech.com
# Expected: 192.168.1.230   (via Unifi *.frame.chalupatech.com wildcard override)

curl -I https://clonarr.frame.chalupatech.com/api/health
# Expected: HTTP/2 200   (no -k flag needed — wildcard cert covers this host)
```

If `dig` returns no answer, verify the Unifi DNS override for `*.frame.chalupatech.com → 192.168.1.230` is still in place (per `project_cloudflare_rfc1918_filter` memory).

- [ ] **Step 3-7 (optional sanity): browser smoke test**

Open `https://clonarr.frame.chalupatech.com` in a browser on the LAN.

Expected:
- Green padlock (wildcard cert valid).
- The page redirects to `/setup` (first-run admin onboarding).

This is the moment to either continue to Task 4 (configure the app) or close the browser tab and come back later. Either is fine — Argo will continue reconciling without operator interaction.

**Troubleshooting (if Step 3-1 sticks on OutOfSync or 3-2 sticks on Pending):**

```bash
kubectl -n argocd describe application clonarr | tail -40
kubectl -n media describe pod -l app.kubernetes.io/name=clonarr | tail -40
kubectl -n media get events --sort-by=.lastTimestamp | tail -20
```

Most common causes (and their fixes):

| Symptom | Likely cause | Fix |
|---|---|---|
| Pod `ContainerCreating`, event "MountVolume.SetUp failed", `nfs: mount.nfs: access denied` | The `Configs/clonarr/` directory wasn't created on TrueNAS (Task 1). | Re-run Task 1, then `kubectl -n media rollout restart deploy/clonarr`. |
| App `OutOfSync` with error about `external-secrets.io` ExternalSecret fields | New ESO admission-controller field defaulter not in `ignoreDifferences`. | Add the field to `gitops/bootstrap/applicationsets/media.yaml` `ignoreDifferences` block in a follow-up PR. Not blocking — clonarr has no ExternalSecret so this should not occur. |
| Pod `CrashLoopBackOff`, logs show "permission denied: /config/auth.json" | NFS share Maproot setting was changed away from root. | Verify Maproot=root on TrueNAS for `/mnt/PlexMedia/frame`. Restore if changed. |
| IngressRoute exists but `curl` returns 404 from Traefik | Service name mismatch between values.yaml and ingressroute.yaml. | The service block names the service `clonarr` (controller name is the service name in bjw-s app-template). IngressRoute backend must be `name: clonarr, port: 6060`. Re-render with `helm template` and confirm. |

---

## Task 4: First-run setup via Clonarr web UI *(manual operator runbook — no PR)*

This task makes Clonarr functional — admin account, Radarr/Sonarr instances, TRaSH guide pull. Not GitOps-managed because Clonarr stores instance configs in `/config/clonarr.json` (no env-var injection point).

- [ ] **Step 4-1: Create admin account**

In a LAN browser, navigate to `https://clonarr.frame.chalupatech.com`.

You should be redirected to `/setup`. Create an admin account:

- Username: operator's choice
- Password: min 10 characters; 16+ skips the complexity rule (passphrases like `correct horse battery staple` are fine)

Save the credentials in your password manager (1Password / Bitwarden / etc.). **There is no email reset flow — recovery is destructive (delete `/config/auth.json` and restart the pod).**

After submission you land in the main Clonarr UI logged in.

- [ ] **Step 4-2: Get Sonarr's API key**

In a separate tab, open `https://sonarr.frame.chalupatech.com` → Settings → General → **API Key** (top of page). Copy the value.

- [ ] **Step 4-3: Add Sonarr instance to Clonarr**

In Clonarr → Settings (gear icon, sidebar) → **Instances** → add Sonarr:

- Name: `Sonarr`
- URL: `http://sonarr.media.svc:8989`
- API Key: *(paste from Step 4-2)*

Click **Test** — should report a green ✓ (Clonarr reaches Sonarr over the in-cluster Service DNS). Save.

- [ ] **Step 4-4: Get Radarr's API key**

`https://radarr.frame.chalupatech.com` → Settings → General → **API Key**. Copy.

- [ ] **Step 4-5: Add Radarr instance to Clonarr**

Clonarr → Settings → **Instances** → add Radarr:

- Name: `Radarr`
- URL: `http://radarr.media.svc:7878`
- API Key: *(paste from Step 4-4)*

Click **Test** — green ✓. Save.

- [ ] **Step 4-6: Pull the TRaSH Guides repo**

In the Clonarr header, click **Pull**.

Expected: a progress indicator clones https://github.com/TRaSH-Guides/Guides into `/config/data/trash-guides/`. Within ~30 seconds you should see a success toast and the Sonarr/Radarr tabs in the main nav populate with quality profiles.

Verify the clone landed on NFS:

```bash
kubectl -n media exec deploy/clonarr -- ls /config/data/trash-guides/ | head
```

Expected: a non-empty directory listing (`README.md`, `docs/`, `.git/`, etc.).

- [ ] **Step 4-7: Smoke-test a dry-run sync**

In Clonarr → **Radarr** tab → pick any TRaSH profile (e.g., `SQP-1 (1080p)`) → click **Sync** → in the modal, leave **Dry Run** enabled → submit.

Expected: a preview lists what Clonarr would change (custom formats to create, profile to add/update, scores to apply). **Do not click "Apply"** — leave it as a dry-run for now. The point of this step is to verify Clonarr can read profiles back from Radarr; a green dry-run preview is proof.

Repeat once on the Sonarr tab against any TRaSH series profile.

When both dry-runs return clean preview output, **Clonarr is fully operational.**

---

## Wrap-up

After Task 4 completes:

- `clonarr.frame.chalupatech.com` is reachable from the LAN over HTTPS with a green padlock.
- `kubectl -n argocd get application clonarr` is `Synced/Healthy`.
- The pod is `1/1 Ready` with `/config` bound to NFS.
- Admin account is set; Radarr + Sonarr instances are configured and reachable.
- The TRaSH Guides repo is cloned and quality profiles render in the UI.
- The operator has run at least one dry-run sync per arr and seen a clean preview.

This is the end of the Clonarr deploy. Apply-mode syncs, auto-sync configuration, Discord/Gotify notifications, and per-profile override settings are operator preferences — configure them via the Clonarr UI on your own schedule. None of that is GitOps-managed.

If the deploy reveals anything that should be captured in memory (e.g., a long-lived gotcha about Clonarr's `URL_BASE` interaction with subdomain hosting, or a specific Radarr API quirk), update `/Users/tbigelow/.claude/projects/-Users-tbigelow-Documents-code-chalupa-tech-local/memory/` with a new feedback or project memory entry before closing out.
