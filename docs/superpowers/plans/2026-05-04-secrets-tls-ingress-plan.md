# Secrets + TLS Ingress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy OpenBao + ESO + cert-manager + Traefik + external-dns on the Talos cluster so internal hostnames under `*.frame.chalupatech.com` resolve to a Traefik LoadBalancer IP with valid Let's Encrypt certs, and operators can store secrets in OpenBao that workloads consume via ESO.

**Architecture:** Five new wrapper Helm charts under `gitops/apps/platform/`, mirroring the wrapper-chart pattern from sub-project #1. One single Cloudflare API token (zone `chalupatech.com`, `Zone.DNS:Edit`) seeded into OpenBao at `secret/cloudflare/api-token` is the source of truth for both cert-manager (DNS-01 challenges) and external-dns (record management). One wildcard cert for `*.frame.chalupatech.com` issued from `letsencrypt-prod` and used as Traefik's default TLS via a `TLSStore`.

**Tech Stack:** OpenBao 0.27.2 (app v2.5.3), cert-manager v1.20.2, External Secrets Operator 2.4.1, Traefik 39.0.9 (app v3.6.15), external-dns 1.21.1, Talos Linux v1.12, Helm 3, kubeconform, GitHub Actions.

**Reference spec:** `docs/superpowers/specs/2026-05-04-secrets-tls-ingress-design.md`.

**Branching strategy:** One feature branch per task, one PR per task, one merge to `main`. Tasks 1-3 and 5-9 are PR-driven. Task 4 is a **manual operator runbook** that does not produce a PR — it runs once between Tasks 3 and 5 to initialize OpenBao, configure auth methods, and seed the Cloudflare token. Subsequent PRs can only succeed after Task 4 completes.

**Pre-existing prerequisites (already satisfied by sub-project #1):**

- `gitops/` directory + 3 ApplicationSets (`platform-apps`, `media-apps`, `infra-tools-apps`)
- `argocd`, `metallb`, `local-path-provisioner` Applications already Synced/Healthy
- `local-path` is the cluster's default StorageClass
- MetalLB IP pool `192.168.1.160-192.168.1.170` available for LoadBalancer assignment
- `.github/workflows/gitops.yml` validates wrapper charts on PR
- `.github/workflows/deploy.yml` Stage 4 includes a `Verify GitOps reconciliation` step

**Pre-existing prerequisite (must be set by operator before Task 1):**

- A Cloudflare API token with permissions `Zone.Zone:Read` + `Zone.DNS:Edit` scoped to the `chalupatech.com` zone. Save the token value somewhere retrievable for Task 4 (1Password recommended). The token is **not** stored in this repo or any GitHub secret.

---

## Pre-Flight: Local Tooling

Subagent must have these CLIs installed before starting any task:

- [ ] **Step P-1: Verify local tooling**

Run:
```bash
helm version --short                    # expect: v3.x
kubeconform -v                          # expect: v0.6+
yamllint --version                      # expect: any
gh --version                            # expect: gh version 2.x
jq --version                            # expect: jq-1.6+
kubectl version --client                # expect: v1.30+ (signed binary; /opt/homebrew/bin or similar)
```

Notes:
- If `jq` is missing: `brew install jq`.
- kubectl must be the Homebrew-signed binary, not an adhoc-signed manual install. If `which kubectl` returns `/usr/local/bin/kubectl` (manual install), `sudo rm` it and reinstall via `brew install kubectl`. Adhoc-signed Go binaries get silently sandboxed by macOS Sequoia+ network privacy filtering and produce phantom `no route to host` errors on TCP 6443 even though TCP/TLS work fine via curl/openssl.
- `KUBECONFIG` must be set before running any cluster verification step:
  ```bash
  cd pulumi-talos && pulumi stack output kubeconfig --show-secrets > ~/.kube/chalupa-cluster.yaml && cd -
  chmod 600 ~/.kube/chalupa-cluster.yaml
  export KUBECONFIG=~/.kube/chalupa-cluster.yaml
  kubectl get nodes  # sanity check
  ```

---

## Task 1: Helper Scripts (`scripts/openbao/`)

Add the operator helper scripts before any cluster work — they're needed for Task 4's runbook. Pure file additions; no cluster changes.

**Files:**
- Create: `scripts/openbao/unseal.sh`
- Create: `scripts/openbao/kv-put.sh`
- Create: `scripts/openbao/README.md`

**Step 1.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/openbao-helper-scripts
```

**Step 1.2: Create `scripts/openbao/unseal.sh`**

Write the file with content:

```bash
#!/usr/bin/env bash
# Unseal all OpenBao pods. Idempotent — pods already unsealed are skipped.
#
# Usage:
#   OPENBAO_KEY_1=... OPENBAO_KEY_2=... OPENBAO_KEY_3=... ./scripts/openbao/unseal.sh
#   ./scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json
#
# Requires: kubectl with KUBECONFIG set, jq (only if --keys-file).
set -euo pipefail

if [[ "${1:-}" == "--keys-file" ]]; then
  KEYS_FILE=$2
  : "${KEYS_FILE:?--keys-file requires a path}"
  OPENBAO_KEY_1=$(jq -r '.unseal_keys_b64[0]' "$KEYS_FILE")
  OPENBAO_KEY_2=$(jq -r '.unseal_keys_b64[1]' "$KEYS_FILE")
  OPENBAO_KEY_3=$(jq -r '.unseal_keys_b64[2]' "$KEYS_FILE")
fi

: "${OPENBAO_KEY_1:?OPENBAO_KEY_1 not set}"
: "${OPENBAO_KEY_2:?OPENBAO_KEY_2 not set}"
: "${OPENBAO_KEY_3:?OPENBAO_KEY_3 not set}"

NS=openbao
PODS=(openbao-0 openbao-1 openbao-2)

for pod in "${PODS[@]}"; do
  echo "==> $pod"
  sealed=$(kubectl -n "$NS" exec "$pod" -- bao status -format=json 2>/dev/null | jq -r '.sealed' || echo "unknown")
  if [[ "$sealed" == "false" ]]; then
    echo "    already unsealed, skipping"
    continue
  fi
  for key in "$OPENBAO_KEY_1" "$OPENBAO_KEY_2" "$OPENBAO_KEY_3"; do
    kubectl -n "$NS" exec "$pod" -- bao operator unseal "$key" >/dev/null
  done
  echo "    unsealed"
done
```

Make it executable: `chmod +x scripts/openbao/unseal.sh`.

**Step 1.3: Create `scripts/openbao/kv-put.sh`**

Write the file with content:

```bash
#!/usr/bin/env bash
# Write a key/value to OpenBao KV v2 (mount: secret).
#
# Usage:
#   OPENBAO_TOKEN=<token> ./scripts/openbao/kv-put.sh <path> <key> <value>
#   ./scripts/openbao/kv-put.sh cloudflare/api-token token "abc123..."
#   ./scripts/openbao/kv-put.sh cloudflare/api-token token -    # value from stdin
#
# Requires: kubectl with KUBECONFIG set, OPENBAO_TOKEN env var.
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <path> <key> <value>" >&2
  echo "       $0 <path> <key> -    (read value from stdin)" >&2
  exit 2
fi

PATH_=$1
KEY=$2
VALUE=$3

: "${OPENBAO_TOKEN:?OPENBAO_TOKEN must be set}"

if [[ "$VALUE" == "-" ]]; then
  VALUE=$(cat)
fi

# Send value via stdin to avoid leaking through process args.
printf '%s' "$VALUE" | kubectl -n openbao exec -i openbao-0 -- sh -c "
  export BAO_ADDR=http://127.0.0.1:8200
  export BAO_TOKEN='$OPENBAO_TOKEN'
  bao kv put -mount=secret '$PATH_' '$KEY=-'
"
```

Make it executable: `chmod +x scripts/openbao/kv-put.sh`.

**Step 1.4: Create `scripts/openbao/README.md`**

```markdown
# OpenBao Operator Scripts

Helper scripts for the recurring OpenBao operations in this homelab. The cluster runs OpenBao in HA Raft mode (3 replicas, manual Shamir unseal) per the spec at `docs/superpowers/specs/2026-05-04-secrets-tls-ingress-design.md`.

## Prerequisites

- `KUBECONFIG` exported (see `pulumi-talos/` for how to pull the kubeconfig).
- `kubectl` (Homebrew-installed; not the adhoc-signed binary from kubernetes.io).
- `jq` (Homebrew).
- OpenBao Application Synced and pods Running (after Task 2 of the implementation plan merges).

## Lifecycle

### Phase 1: One-time per cluster lifetime — Init

After Task 2 (OpenBao chart) and Task 3 (ESO chart) merge, the OpenBao pods come up sealed. Init them once:

```bash
kubectl -n openbao exec openbao-0 -- bao operator init -key-shares=5 -key-threshold=3 -format=json > ~/secure/openbao-init.json
chmod 600 ~/secure/openbao-init.json
```

**Save the contents of `openbao-init.json` in 1Password under "homelab-openbao-keys" before continuing.** The unseal keys and root token cannot be recovered if lost. If you lose them, every secret stored in OpenBao is unrecoverable and OpenBao must be re-initialized from scratch (PVCs deleted, chart re-synced).

### Phase 2: One-time per cluster lifetime — Configure

After init, configure auth methods, KV engine, policies, and roles. This is documented in detail in `docs/superpowers/plans/2026-05-04-secrets-tls-ingress-plan.md` Task 4 (the operator runbook).

### Phase 3: Routine — Unseal after every cluster reboot

```bash
./scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json
```

The script is idempotent. Already-unsealed pods are skipped.

### Phase 4: Routine — Add or update a secret

```bash
export OPENBAO_TOKEN=$(jq -r '.root_token' ~/secure/openbao-init.json)
./scripts/openbao/kv-put.sh <path> <key> <value>

# Examples:
./scripts/openbao/kv-put.sh cloudflare/api-token token "abc123..."
./scripts/openbao/kv-put.sh sonarr/api-key apikey "deadbeef..."
```

For ongoing operations, replace the root token with a per-operator token that has `update` capability on the relevant `secret/data/<path>` paths. Keep the root token in 1Password and only export it for the rare administrative operations that need it.

## Security notes

- Neither script writes any sensitive material to disk on the operator's machine. All values flow over `kubectl exec` stdin and are not visible in process arg listings.
- `unseal.sh` accepts keys via env vars or a `--keys-file` JSON path. The JSON file should live somewhere encrypted at rest (e.g., `~/secure/`) and should not be committed.
- `kv-put.sh` requires `OPENBAO_TOKEN`; do not export this variable in your shell history. Set it inline (`OPENBAO_TOKEN=$(...) ./scripts/openbao/kv-put.sh ...`) or in a single-shot subshell.
```

**Step 1.5: Lint and commit**

```bash
yamllint scripts/openbao/  # should produce no output
shellcheck scripts/openbao/*.sh 2>&1 | head -10  # if shellcheck installed; otherwise skip
git add scripts/openbao/
git commit -m "$(cat <<'EOF'
feat(openbao): add helper scripts for unseal and KV writes

Adds scripts/openbao/{unseal.sh,kv-put.sh,README.md} to support
the operator runbook for OpenBao (init, configure, routine unseal,
secret seeding). unseal.sh is idempotent; kv-put.sh accepts values
via stdin to avoid leaking through process args.

These scripts are used in Task 4 of the Secrets+TLS Ingress
implementation plan. Pure file additions; no cluster impact.
EOF
)"
```

**Step 1.6: Push, open PR, wait for CI, merge**

```bash
git push -u origin feat/openbao-helper-scripts
gh pr create --title "feat(openbao): add unseal + kv-put helper scripts" \
  --body "$(cat <<'EOF'
## Summary

Adds operator helper scripts for OpenBao under \`scripts/openbao/\`:
- \`unseal.sh\` — idempotent unseal of all 3 OpenBao pods
- \`kv-put.sh\` — write a single KV entry, value via stdin
- \`README.md\` — usage + lifecycle docs

Part 1/9 of sub-project #2 (Secrets + TLS Ingress). Pure file additions — no chart changes, no cluster changes. The scripts will be used in Task 4 (operator runbook) once OpenBao is deployed.

## Test plan

- [ ] CI passes
- [ ] yamllint clean on the new files
EOF
)"
gh pr checks --watch
gh pr merge --squash --delete-branch
```

**Acceptance criteria for "DONE":**
- All three files exist with the specified content.
- `unseal.sh` and `kv-put.sh` have executable permission bits committed.
- CI passes green.
- PR squash-merged.

---

## Task 2: OpenBao Wrapper Chart

Adds OpenBao as a wrapper Helm chart. Pods come up sealed and uninitialized. Application reaches Synced (StatefulSet rollout completes). Functional state is gated on Task 4.

**Files:**
- Create: `gitops/apps/platform/openbao/Chart.yaml`
- Create: `gitops/apps/platform/openbao/values.yaml`
- Create: `gitops/apps/platform/openbao/.helmignore`
- Create: `gitops/apps/platform/openbao/templates/namespace.yaml`

**Step 2.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-openbao-chart
```

**Step 2.2: Create directory and namespace template**

```bash
mkdir -p gitops/apps/platform/openbao/templates
```

Write `gitops/apps/platform/openbao/templates/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openbao
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

The sync-wave `-1` ensures the namespace lands before any other resource in the chart.

**Step 2.3: Write `gitops/apps/platform/openbao/Chart.yaml`**

```yaml
apiVersion: v2
name: openbao-wrapper
description: Wrapper chart for OpenBao (HA Raft, manual Shamir unseal)
type: application
version: 0.1.0
appVersion: "v2.5.3"
dependencies:
  - name: openbao
    version: 0.27.2
    repository: https://openbao.github.io/openbao-helm
```

**Step 2.4: Write `gitops/apps/platform/openbao/values.yaml`**

```yaml
openbao:
  server:
    ha:
      enabled: true
      raft:
        enabled: true
        setNodeId: true
        config: |
          ui = true
          api_addr = "http://HOSTNAME.openbao-internal:8200"
          cluster_addr = "http://HOSTNAME.openbao-internal:8201"
          listener "tcp" {
            tls_disable = 1
            address = "[::]:8200"
            cluster_address = "[::]:8201"
          }
          storage "raft" {
            path = "/openbao/data"
            retry_join {
              leader_api_addr = "http://openbao-0.openbao-internal:8200"
            }
            retry_join {
              leader_api_addr = "http://openbao-1.openbao-internal:8200"
            }
            retry_join {
              leader_api_addr = "http://openbao-2.openbao-internal:8200"
            }
          }
          service_registration "kubernetes" {}
    replicas: 3
    affinity: |
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                  - key: app.kubernetes.io/name
                    operator: In
                    values:
                      - openbao
              topologyKey: kubernetes.io/hostname
    dataStorage:
      enabled: true
      size: 1Gi
      storageClass: local-path
    ui:
      enabled: true
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
```

**Step 2.5: Write `.helmignore`**

```
.helmignore
```

**Step 2.6: Render and validate**

```bash
cd gitops/apps/platform/openbao
helm dependency update
helm template openbao . > /tmp/openbao-rendered.yaml
wc -l /tmp/openbao-rendered.yaml
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/openbao-rendered.yaml
cd -
```

Expected: clean render, kubeconform reports `Valid: N` with `Invalid: 0` and `Errors: 0`.

**Step 2.7: Commit, push, PR, merge**

```bash
git add gitops/apps/platform/openbao/
git commit -m "$(cat <<'EOF'
feat(gitops): add OpenBao wrapper chart (HA Raft, sealed)

Wraps openbao 0.27.2 (app v2.5.3). HA Raft with 3 replicas,
local-path StorageClass (1Gi per replica), manual Shamir unseal.
Pod-anti-affinity preference spreads replicas across the three
Talos nodes. Namespace labelled with baseline PSA.

Inert until Task 4 (operator runbook) initializes the cluster.
After init+unseal+configure, ESO can authenticate via Kubernetes
auth role 'external-secrets'.
EOF
)"
git push -u origin feat/gitops-openbao-chart
gh pr create --title "feat(gitops): add OpenBao wrapper chart" \
  --body "$(cat <<'EOF'
## Summary

- Adds \`gitops/apps/platform/openbao/\` wrapping openbao 0.27.2
- HA Raft, 3 replicas, 1Gi local-path PVC each
- Namespace with baseline PSA labels (sync-wave -1)
- Pods come up **sealed** — Application reaches Synced when StatefulSet rolls out, but OpenBao itself is inert until Task 4 of the implementation plan

Part 2/9 of sub-project #2.

## Test plan

- [ ] CI renders chart and validates manifests
- [ ] Post-merge: \`kubectl -n openbao get pods\` shows openbao-0/1/2 Running 1/1
- [ ] Post-merge: \`kubectl -n openbao exec openbao-0 -- bao status\` shows Initialized=false, Sealed=true
- [ ] Post-merge: \`kubectl -n argocd get application openbao\` shows Synced/Healthy
EOF
)"
gh pr checks --watch
gh pr merge --squash --delete-branch
```

**Step 2.8: Post-merge verification**

```bash
gh run watch
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
kubectl -n openbao get pods
kubectl -n openbao exec openbao-0 -- bao status 2>&1 | head -5
kubectl -n argocd get application openbao
```

Expected:
- 3 pods Running 1/1
- `bao status` reports `Initialized: false, Sealed: true` (exit code 2 — this is normal for an uninitialized OpenBao; the script handles it via the `2>&1 | head` form)
- ArgoCD application Synced/Healthy

**Acceptance criteria for "DONE":**
- All four chart files committed, including Chart.lock.
- `helm template` renders cleanly; kubeconform reports valid.
- CI passes; PR squash-merged.
- Post-merge: 3 OpenBao pods Running and ArgoCD application Synced/Healthy.
- Post-merge: `bao status` confirms Initialized=false, Sealed=true (this is the expected pre-runbook state).

---

## Task 3: External Secrets Operator (ESO) Wrapper Chart

Adds ESO as a wrapper chart with a `ClusterSecretStore` pointing at OpenBao. The store will be `Status: Failed` until Task 4 configures OpenBao's Kubernetes auth — that's expected and not blocking for this task.

**Files:**
- Create: `gitops/apps/platform/external-secrets/Chart.yaml`
- Create: `gitops/apps/platform/external-secrets/values.yaml`
- Create: `gitops/apps/platform/external-secrets/.helmignore`
- Create: `gitops/apps/platform/external-secrets/templates/namespace.yaml`
- Create: `gitops/apps/platform/external-secrets/templates/clustersecretstore.yaml`

**Step 3.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-external-secrets-chart
```

**Step 3.2: Create directory and namespace**

```bash
mkdir -p gitops/apps/platform/external-secrets/templates
```

Write `gitops/apps/platform/external-secrets/templates/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: external-secrets
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

**Step 3.3: Write `gitops/apps/platform/external-secrets/Chart.yaml`**

```yaml
apiVersion: v2
name: external-secrets-wrapper
description: Wrapper chart for External Secrets Operator with OpenBao ClusterSecretStore
type: application
version: 0.1.0
appVersion: "v2.4.1"
dependencies:
  - name: external-secrets
    version: 2.4.1
    repository: https://charts.external-secrets.io
```

**Step 3.4: Write `gitops/apps/platform/external-secrets/values.yaml`**

```yaml
external-secrets:
  installCRDs: true
  replicaCount: 1
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 128Mi
  webhook:
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        memory: 64Mi
  certController:
    resources:
      requests:
        cpu: 10m
        memory: 64Mi
      limits:
        memory: 256Mi
```

**Step 3.5: Write `gitops/apps/platform/external-secrets/templates/clustersecretstore.yaml`**

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao
  annotations:
    # CRDs from the chart must apply before this CR.
    argocd.argoproj.io/sync-wave: "1"
spec:
  provider:
    vault:
      server: "http://openbao.openbao.svc.cluster.local:8200"
      path: secret
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: external-secrets
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

**Step 3.6: Write `.helmignore`**

```
.helmignore
```

**Step 3.7: Render and validate**

```bash
cd gitops/apps/platform/external-secrets
helm dependency update
helm template external-secrets . > /tmp/eso-rendered.yaml
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/eso-rendered.yaml
cd -
```

Expected: clean render. ClusterSecretStore may report "skipped" if datreeio CRDs catalog doesn't have a schema for `external-secrets.io/v1`; that's acceptable.

**Step 3.8: Commit, push, PR, merge**

```bash
git add gitops/apps/platform/external-secrets/
git commit -m "$(cat <<'EOF'
feat(gitops): add External Secrets Operator wrapper chart

Wraps external-secrets 2.4.1. ClusterSecretStore 'openbao' uses
Kubernetes auth via the external-secrets ServiceAccount; will be
Status: Failed until Task 4 (operator runbook) enables Kubernetes
auth in OpenBao and creates the matching role.

Sync-wave 1 on the ClusterSecretStore ensures CRDs from the chart
apply first.
EOF
)"
git push -u origin feat/gitops-external-secrets-chart
gh pr create --title "feat(gitops): add External Secrets Operator wrapper" \
  --body "$(cat <<'EOF'
## Summary

- Adds \`gitops/apps/platform/external-secrets/\` wrapping external-secrets 2.4.1
- ClusterSecretStore named \`openbao\` configured for Kubernetes auth
- ClusterSecretStore will be Status: Failed until Task 4 of the implementation plan completes — this is expected

Part 3/9 of sub-project #2.

## Test plan

- [ ] CI renders chart and validates manifests
- [ ] Post-merge: \`kubectl -n external-secrets get pods\` shows controller + webhook + cert-controller all Running
- [ ] Post-merge: \`kubectl get clustersecretstore openbao\` shows the resource exists (status may be Failed pre-Task 4)
- [ ] Post-merge: \`kubectl -n argocd get application external-secrets\` shows Synced/Healthy
EOF
)"
gh pr checks --watch
gh pr merge --squash --delete-branch
```

**Step 3.9: Post-merge verification**

```bash
gh run watch
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
kubectl -n external-secrets get pods
kubectl get clustersecretstore openbao 2>&1 | head -3
kubectl -n argocd get application external-secrets
```

Expected:
- 3 ESO pods Running (controller + webhook + cert-controller)
- `clustersecretstore openbao` exists; status likely `Failed` because OpenBao isn't yet configured for Kubernetes auth
- ArgoCD Application Synced/Healthy

**Acceptance criteria for "DONE":**
- All five files committed.
- `helm template` renders cleanly; kubeconform reports valid (or skipped on the ClusterSecretStore CR — fine).
- CI passes; PR squash-merged.
- Post-merge: ESO Application Synced/Healthy and pods running. ClusterSecretStore exists; status Failed is acceptable.

---

## Task 4: [MANUAL] Operator Runbook — Init, Configure, Seed

**This task does not produce a PR.** It's a one-time operator runbook that runs on the cluster after Tasks 2 and 3 are merged and before Task 5 starts. The runbook initializes OpenBao, configures Kubernetes auth + KV + policies + roles, and seeds the Cloudflare API token.

After this runs, ESO's ClusterSecretStore transitions to `Ready: True`, and subsequent ExternalSecret CRs (added in Tasks 5 and 7) reconcile cleanly.

**Step 4.1: Verify pre-conditions**

```bash
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
kubectl -n openbao get pods                          # 3 pods, 1/1 Running
kubectl -n external-secrets get pods                 # 3 pods running
kubectl -n openbao exec openbao-0 -- bao status 2>&1 | head -3   # Sealed: true, Initialized: false
```

If any of these are wrong, fix before proceeding.

**Step 4.2: Initialize OpenBao (one-time per cluster lifetime)**

```bash
mkdir -p ~/secure
chmod 700 ~/secure
kubectl -n openbao exec openbao-0 -- bao operator init -key-shares=5 -key-threshold=3 -format=json > ~/secure/openbao-init.json
chmod 600 ~/secure/openbao-init.json
```

The output JSON contains `unseal_keys_b64` (5 keys), `unseal_keys_hex` (5 keys), and `root_token`.

**STOP.** Open `~/secure/openbao-init.json` in your editor. Copy the JSON to 1Password under a new entry named "homelab-openbao-keys". This is the only chance to back these up. If the local file is lost and not in 1Password, OpenBao is unrecoverable.

```bash
cat ~/secure/openbao-init.json   # paste into 1Password
```

**Step 4.3: Unseal all pods**

```bash
./scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json
```

Expected output:
```
==> openbao-0
    unsealed
==> openbao-1
    unsealed
==> openbao-2
    unsealed
```

Verify:
```bash
kubectl -n openbao exec openbao-0 -- bao status | head -5
# Sealed: false, Initialized: true, HA Mode: active or standby
```

**Step 4.4: Login + configure auth + KV + policy + roles**

```bash
ROOT_TOKEN=$(jq -r '.root_token' ~/secure/openbao-init.json)

# Enable Kubernetes auth + configure (idempotent; the `|| echo` swallows
# "already exists" errors on re-runs).
kubectl -n openbao exec openbao-0 \
  --env BAO_ADDR=http://127.0.0.1:8200 \
  --env BAO_TOKEN="$ROOT_TOKEN" \
  -- sh -c '
    bao auth enable kubernetes || echo "kubernetes auth already enabled"
    bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc.cluster.local
    bao secrets enable -path=secret -version=2 kv || echo "kv already enabled at secret/"
'

# Write the cloudflare-read policy via stdin (no heredoc — robust to copy-paste).
echo 'path "secret/data/cloudflare/*" { capabilities = ["read"] }' \
  | kubectl -n openbao exec -i openbao-0 \
      --env BAO_ADDR=http://127.0.0.1:8200 \
      --env BAO_TOKEN="$ROOT_TOKEN" \
      -- bao policy write cloudflare-read -

# Verify the policy was written
kubectl -n openbao exec openbao-0 \
  --env BAO_ADDR=http://127.0.0.1:8200 \
  --env BAO_TOKEN="$ROOT_TOKEN" \
  -- bao policy read cloudflare-read

# Write the three Kubernetes auth roles.
for entry in \
  "cert-manager:cert-manager-cloudflare-token" \
  "external-dns:external-dns-cloudflare-token" \
  "external-secrets:external-secrets"; do
  ns="${entry%:*}"
  sa="${entry#*:}"
  echo "==> role $ns (SA $ns/$sa)"
  kubectl -n openbao exec openbao-0 \
    --env BAO_ADDR=http://127.0.0.1:8200 \
    --env BAO_TOKEN="$ROOT_TOKEN" \
    -- bao write "auth/kubernetes/role/$ns" \
        "bound_service_account_names=$sa" \
        "bound_service_account_namespaces=$ns" \
        policies=cloudflare-read \
        ttl=1h
done
```

Expected: each command succeeds. The `auth enable` and `secrets enable` may already have succeeded if you re-run; the `|| echo ...` makes that case non-fatal.

**Step 4.5: Seed the Cloudflare API token**

You need the Cloudflare API token value (with `Zone.Zone:Read` + `Zone.DNS:Edit` scoped to `chalupatech.com`). Get it from 1Password.

```bash
export OPENBAO_TOKEN=$ROOT_TOKEN
./scripts/openbao/kv-put.sh cloudflare/api-token token "<paste-cloudflare-token-value-here>"

# Verify
kubectl -n openbao exec openbao-0 -- bao kv get -mount=secret cloudflare/api-token
```

Expected: `bao kv get` shows `token = <value>` (the value is shown by default; this is the only Vault command that displays values without `-format=json` and `jq`).

**Step 4.6: Verify ESO can now reconcile**

```bash
kubectl get clustersecretstore openbao -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Expected: True

# Force a refresh just in case
kubectl get clustersecretstore openbao -o yaml | grep -A 5 conditions
```

If the store still says `Failed`, check the controller logs:
```bash
kubectl -n external-secrets logs -l app.kubernetes.io/name=external-secrets --tail=30
```

Common issues:
- Kubernetes host URL wrong (check `auth/kubernetes/config`)
- Role name doesn't match (`external-secrets` in OpenBao vs `external-secrets` SA in K8s)
- Policy doesn't include the path being read

**Step 4.7: Document completion**

After this runbook completes successfully, the cluster is ready for Tasks 5+. There's no commit to make — this is purely operator action.

**Acceptance criteria for "DONE":**
- `~/secure/openbao-init.json` exists locally with the init output, AND its contents are stored in 1Password.
- All 3 OpenBao pods report `Sealed: false`.
- `kubectl get clustersecretstore openbao` shows `Ready: True`.
- `kubectl -n openbao exec openbao-0 -- bao kv get -mount=secret cloudflare/api-token` returns the token.

If any of these are wrong, **stop and resolve before Task 5**. Tasks 5 onward depend on this state.

---

## Task 5: cert-manager Wrapper Chart

Adds cert-manager with a `ClusterIssuer` (`letsencrypt-prod`) and an `ExternalSecret` that syncs the Cloudflare token from OpenBao. The ClusterIssuer can become `Ready: True` only after Task 4.

**Files:**
- Create: `gitops/apps/platform/cert-manager/Chart.yaml`
- Create: `gitops/apps/platform/cert-manager/values.yaml`
- Create: `gitops/apps/platform/cert-manager/.helmignore`
- Create: `gitops/apps/platform/cert-manager/templates/namespace.yaml`
- Create: `gitops/apps/platform/cert-manager/templates/cloudflare-token-serviceaccount.yaml`
- Create: `gitops/apps/platform/cert-manager/templates/cloudflare-token-externalsecret.yaml`
- Create: `gitops/apps/platform/cert-manager/templates/clusterissuer.yaml`

**Step 5.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-cert-manager-chart
```

**Step 5.2: Create directory and namespace**

```bash
mkdir -p gitops/apps/platform/cert-manager/templates
```

Write `gitops/apps/platform/cert-manager/templates/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

**Step 5.3: Write `gitops/apps/platform/cert-manager/Chart.yaml`**

```yaml
apiVersion: v2
name: cert-manager-wrapper
description: Wrapper chart for cert-manager with letsencrypt-prod ClusterIssuer (DNS-01 via Cloudflare)
type: application
version: 0.1.0
appVersion: "v1.20.2"
dependencies:
  - name: cert-manager
    version: v1.20.2
    repository: https://charts.jetstack.io
```

**Step 5.4: Write `gitops/apps/platform/cert-manager/values.yaml`**

```yaml
cert-manager:
  installCRDs: true
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 128Mi
  webhook:
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        memory: 64Mi
  cainjector:
    resources:
      requests:
        cpu: 10m
        memory: 64Mi
      limits:
        memory: 256Mi
```

**Step 5.5: Write `templates/cloudflare-token-serviceaccount.yaml`**

This SA is bound by OpenBao's Kubernetes auth role `cert-manager`. Reserved for future direct OpenBao integration; cert-manager itself doesn't currently use it (it consumes the ESO-synced Secret).

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cert-manager-cloudflare-token
  namespace: cert-manager
  annotations:
    argocd.argoproj.io/sync-wave: "1"
```

**Step 5.6: Write `templates/cloudflare-token-externalsecret.yaml`**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: cloudflare-api-token
    creationPolicy: Owner
  data:
    - secretKey: token
      remoteRef:
        key: secret/data/cloudflare/api-token
        property: token
```

**Step 5.7: Write `templates/clusterissuer.yaml`**

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: bigelowtayven+chalupatech@gmail.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: token
```

The sync-waves enforce ordering: namespace (-1) → chart resources including CRDs (0) → SA (1) → ExternalSecret (2) → ClusterIssuer (3).

**Step 5.8: Write `.helmignore`**

```
.helmignore
```

**Step 5.9: Render and validate**

```bash
cd gitops/apps/platform/cert-manager
helm dependency update
helm template cert-manager . > /tmp/certmgr-rendered.yaml
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/certmgr-rendered.yaml
cd -
```

**Step 5.10: Commit, push, PR, merge**

```bash
git add gitops/apps/platform/cert-manager/
git commit -m "$(cat <<'EOF'
feat(gitops): add cert-manager wrapper with letsencrypt-prod ClusterIssuer

Wraps cert-manager v1.20.2 with installCRDs=true. Adds:
- ServiceAccount cert-manager-cloudflare-token (reserved for future
  direct OpenBao integration)
- ExternalSecret cloudflare-api-token (syncs from OpenBao to a K8s
  Secret consumed by the ClusterIssuer)
- ClusterIssuer letsencrypt-prod (ACME, DNS-01 via Cloudflare)

Sync-waves enforce: namespace -1 -> chart 0 -> SA 1 -> ExternalSecret
2 -> ClusterIssuer 3. Requires Task 4 (operator runbook) to have
completed; otherwise the ExternalSecret will fail to sync.
EOF
)"
git push -u origin feat/gitops-cert-manager-chart
gh pr create --title "feat(gitops): add cert-manager wrapper + letsencrypt-prod ClusterIssuer" \
  --body "$(cat <<'EOF'
## Summary

- Adds \`gitops/apps/platform/cert-manager/\` wrapping cert-manager v1.20.2
- Includes ExternalSecret syncing Cloudflare API token from OpenBao
- Includes ClusterIssuer \`letsencrypt-prod\` using DNS-01 via Cloudflare
- Sync-wave ordering: namespace -> chart -> SA -> ExternalSecret -> ClusterIssuer

Part 5/9 of sub-project #2. Requires Task 4 of the plan (operator runbook) to have completed before this merges, or the ExternalSecret will fail.

## Test plan

- [ ] CI renders chart and validates manifests
- [ ] Post-merge: \`kubectl -n cert-manager get pods\` shows controller + webhook + cainjector all Running
- [ ] Post-merge: \`kubectl -n cert-manager get externalsecret cloudflare-api-token\` shows Status SecretSynced=True
- [ ] Post-merge: \`kubectl -n cert-manager get secret cloudflare-api-token\` exists with the token
- [ ] Post-merge: \`kubectl get clusterissuer letsencrypt-prod\` shows Ready=True
- [ ] Post-merge: \`kubectl -n argocd get application cert-manager\` shows Synced/Healthy
EOF
)"
gh pr checks --watch
gh pr merge --squash --delete-branch
```

**Step 5.11: Post-merge verification**

```bash
gh run watch
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
kubectl -n cert-manager get pods
kubectl -n cert-manager get externalsecret cloudflare-api-token
kubectl -n cert-manager get secret cloudflare-api-token
kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[?(@.type=="Ready")]}{"\n"}'
kubectl -n argocd get application cert-manager
```

Expected:
- cert-manager controller + webhook + cainjector pods Running
- ExternalSecret SecretSynced=True
- Secret `cloudflare-api-token` exists
- ClusterIssuer Ready=True (cert-manager registers an account with Let's Encrypt on first sync; takes 5-10 seconds)
- ArgoCD Application Synced/Healthy

**Acceptance criteria for "DONE":**
- All chart files committed.
- CI passes; PR squash-merged.
- Post-merge: cert-manager Application Synced/Healthy.
- Post-merge: ClusterIssuer Ready=True (Let's Encrypt account registered).
- Post-merge: ExternalSecret SecretSynced=True.

---

## Task 6: Traefik Wrapper Chart + Wildcard Cert + TLSStore

Adds Traefik as the cluster's ingress controller. LoadBalancer service from MetalLB. Issues the wildcard cert via cert-manager and configures it as the default TLS via TLSStore. Adds a redirect-to-https Middleware.

**Files:**
- Create: `gitops/apps/platform/traefik/Chart.yaml`
- Create: `gitops/apps/platform/traefik/values.yaml`
- Create: `gitops/apps/platform/traefik/.helmignore`
- Create: `gitops/apps/platform/traefik/templates/namespace.yaml`
- Create: `gitops/apps/platform/traefik/templates/wildcard-certificate.yaml`
- Create: `gitops/apps/platform/traefik/templates/tlsstore-default.yaml`
- Create: `gitops/apps/platform/traefik/templates/redirect-middleware.yaml`

**Step 6.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-traefik-chart
```

**Step 6.2: Create directory and namespace**

```bash
mkdir -p gitops/apps/platform/traefik/templates
```

Write `gitops/apps/platform/traefik/templates/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: traefik
  labels:
    # Privileged initially; downgrade to baseline if Traefik doesn't actually need privileges.
    # Set privileged because Traefik may need to bind low ports via NET_BIND_SERVICE.
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

**Step 6.3: Write `Chart.yaml`**

```yaml
apiVersion: v2
name: traefik-wrapper
description: Wrapper chart for Traefik with wildcard TLS via TLSStore
type: application
version: 0.1.0
appVersion: "v3.6.15"
dependencies:
  - name: traefik
    version: 39.0.9
    repository: https://traefik.github.io/charts
```

**Step 6.4: Write `values.yaml`**

```yaml
traefik:
  ingressRoute:
    dashboard:
      enabled: false
  service:
    type: LoadBalancer
    annotations:
      # MetalLB-specific annotation (replaces the deprecated loadBalancerIP field)
      metallb.universe.tf/loadBalancerIPs: "192.168.1.230"
  ports:
    web:
      port: 8000
      exposedPort: 80
      expose:
        default: true
      protocol: TCP
    websecure:
      port: 8443
      exposedPort: 443
      expose:
        default: true
      protocol: TCP
      tls:
        enabled: true
  providers:
    kubernetesCRD:
      enabled: true
      allowCrossNamespace: true
    kubernetesIngress:
      enabled: false
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      memory: 256Mi
  logs:
    general:
      level: INFO
    access:
      enabled: true
```

**Step 6.5: Write `templates/wildcard-certificate.yaml`**

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-frame-tls
  namespace: traefik
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  secretName: wildcard-frame-tls
  duration: 2160h     # 90d
  renewBefore: 360h   # 15d
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  commonName: "*.frame.chalupatech.com"
  dnsNames:
    - "*.frame.chalupatech.com"
    - "frame.chalupatech.com"
```

**Step 6.6: Write `templates/tlsstore-default.yaml`**

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: traefik
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  defaultCertificate:
    secretName: wildcard-frame-tls
```

**Step 6.7: Write `templates/redirect-middleware.yaml`**

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-https
  namespace: traefik
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  redirectScheme:
    scheme: https
    permanent: true
```

**Step 6.8: Write `.helmignore`**

```
.helmignore
```

**Step 6.9: Render and validate**

```bash
cd gitops/apps/platform/traefik
helm dependency update
helm template traefik . > /tmp/traefik-rendered.yaml
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/traefik-rendered.yaml
cd -
```

**Step 6.10: Commit, push, PR, merge**

```bash
git add gitops/apps/platform/traefik/
git commit -m "$(cat <<'EOF'
feat(gitops): add Traefik wrapper with wildcard cert + TLSStore

Wraps traefik 39.0.9 (app v3.6.15). Service type LoadBalancer with
loadBalancerIP=192.168.1.230 (from MetalLB pool). Adds:
- Certificate wildcard-frame-tls (*.frame.chalupatech.com)
- TLSStore 'default' referencing the wildcard secret
- Middleware redirect-to-https
- providers.kubernetesCRD.allowCrossNamespace=true so app
  IngressRoutes can reference this Middleware from other namespaces

Namespace labelled privileged PSA initially (cheap insurance against
the metallb-style stuck-Progressing issue we hit in #1). Will be
downgraded to baseline in a follow-up if Traefik proves not to need
privileges.

Sync-waves: namespace -1 -> chart 0 -> Certificate/Middleware 1 ->
TLSStore 2 (TLSStore depends on the cert Secret existing).
EOF
)"
git push -u origin feat/gitops-traefik-chart
gh pr create --title "feat(gitops): add Traefik wrapper + wildcard TLS" \
  --body "$(cat <<'EOF'
## Summary

- Adds \`gitops/apps/platform/traefik/\` wrapping traefik 39.0.9
- Service type LoadBalancer pinned to 192.168.1.230 (MetalLB pool)
- Certificate \`wildcard-frame-tls\` for \`*.frame.chalupatech.com\` via cert-manager
- TLSStore \`default\` so any IngressRoute under \`*.frame.chalupatech.com\` gets HTTPS without per-app cert plumbing
- Middleware \`redirect-to-https\` (referenced cross-namespace by app IngressRoutes in Tasks 8/9)
- \`allowCrossNamespace=true\` on the kubernetesCRD provider

Part 6/9 of sub-project #2.

## Test plan

- [ ] CI renders chart and validates manifests
- [ ] Post-merge: \`kubectl -n traefik get pods\` shows traefik pod Running
- [ ] Post-merge: \`kubectl -n traefik get svc traefik\` shows external IP 192.168.1.230
- [ ] Post-merge: \`kubectl -n traefik get certificate wildcard-frame-tls\` shows Ready=True (may take 1-2 minutes for DNS-01)
- [ ] Post-merge: \`kubectl -n traefik get secret wildcard-frame-tls\` exists with type kubernetes.io/tls
- [ ] Post-merge: \`kubectl -n traefik get tlsstore default\` exists
- [ ] Post-merge: \`kubectl -n argocd get application traefik\` shows Synced/Healthy
EOF
)"
gh pr checks --watch
gh pr merge --squash --delete-branch
```

**Step 6.11: Post-merge verification**

```bash
gh run watch
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
kubectl -n traefik get pods
kubectl -n traefik get svc traefik
kubectl -n traefik get certificate wildcard-frame-tls
# Watch the cert progress through Issuing -> Issued (1-2 minutes)
kubectl -n traefik wait --for=condition=Ready certificate/wildcard-frame-tls --timeout=180s
kubectl -n traefik get secret wildcard-frame-tls
kubectl -n traefik get tlsstore default
kubectl -n argocd get application traefik
```

Expected:
- traefik pod Running 1/1
- Service has external IP `192.168.1.230`
- Certificate progresses to Ready=True (cert-manager creates a temporary CertificateRequest, performs DNS-01 challenge by writing a TXT record to Cloudflare, waits for propagation, validates, downloads the cert, stores in Secret)
- Secret `wildcard-frame-tls` exists
- TLSStore `default` exists
- ArgoCD Application Synced/Healthy

**If cert is stuck `Issuing` for >5 minutes:**
```bash
kubectl -n traefik describe certificate wildcard-frame-tls
kubectl -n traefik get certificaterequest -o wide
kubectl -n traefik get challenge
kubectl -n traefik describe challenge $(kubectl -n traefik get challenge -o name | head -1)
```
Common issues:
- Cloudflare token doesn't have DNS:Edit on the right zone → check Task 4 token value
- DNS-01 propagation slow → wait, can take up to 5 minutes
- ClusterIssuer not Ready → re-check Task 5

**Acceptance criteria for "DONE":**
- All chart files committed.
- CI passes; PR squash-merged.
- Post-merge: Traefik Application Synced/Healthy.
- Post-merge: Service has external IP 192.168.1.230.
- Post-merge: Certificate Ready=True.
- Post-merge: Secret `wildcard-frame-tls` exists.

---

## Task 7: external-dns Wrapper Chart

Adds external-dns to auto-create Cloudflare DNS A records from Traefik IngressRoutes. Includes an ExternalSecret syncing the same Cloudflare token.

**Files:**
- Create: `gitops/apps/platform/external-dns/Chart.yaml`
- Create: `gitops/apps/platform/external-dns/values.yaml`
- Create: `gitops/apps/platform/external-dns/.helmignore`
- Create: `gitops/apps/platform/external-dns/templates/namespace.yaml`
- Create: `gitops/apps/platform/external-dns/templates/cloudflare-token-serviceaccount.yaml`
- Create: `gitops/apps/platform/external-dns/templates/cloudflare-token-externalsecret.yaml`

**Step 7.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/gitops-external-dns-chart
```

**Step 7.2: Create directory and namespace**

```bash
mkdir -p gitops/apps/platform/external-dns/templates
```

Write `gitops/apps/platform/external-dns/templates/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: external-dns
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

**Step 7.3: Write `Chart.yaml`**

```yaml
apiVersion: v2
name: external-dns-wrapper
description: Wrapper chart for external-dns with Cloudflare provider
type: application
version: 0.1.0
appVersion: "0.21.0"
dependencies:
  - name: external-dns
    version: 1.21.1
    repository: https://kubernetes-sigs.github.io/external-dns/
```

**Step 7.4: Write `values.yaml`**

```yaml
external-dns:
  provider:
    name: cloudflare
  sources:
    - traefik-proxy
  domainFilters:
    - frame.chalupatech.com
  policy: upsert-only
  registry: txt
  txtOwnerId: "chalupa-talos"
  txtPrefix: "_edns."
  interval: 1m
  env:
    - name: CF_API_TOKEN
      valueFrom:
        secretKeyRef:
          name: cloudflare-api-token
          key: token
  extraArgs:
    - --traefik-disable-legacy
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 128Mi
```

**Step 7.5: Write `templates/cloudflare-token-serviceaccount.yaml`**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-dns-cloudflare-token
  namespace: external-dns
  annotations:
    argocd.argoproj.io/sync-wave: "1"
```

**Step 7.6: Write `templates/cloudflare-token-externalsecret.yaml`**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cloudflare-api-token
  namespace: external-dns
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: cloudflare-api-token
    creationPolicy: Owner
  data:
    - secretKey: token
      remoteRef:
        key: secret/data/cloudflare/api-token
        property: token
```

**Step 7.7: Write `.helmignore`**

```
.helmignore
```

**Step 7.8: Render and validate**

```bash
cd gitops/apps/platform/external-dns
helm dependency update
helm template external-dns . > /tmp/extdns-rendered.yaml
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/extdns-rendered.yaml
cd -
```

**Step 7.9: Commit, push, PR, merge**

```bash
git add gitops/apps/platform/external-dns/
git commit -m "$(cat <<'EOF'
feat(gitops): add external-dns wrapper for Cloudflare records

Wraps external-dns 1.21.1 (app 0.21.0). Cloudflare provider, sources
traefik-proxy (watches Traefik IngressRoute CRs), domain filter
frame.chalupatech.com, policy upsert-only (never deletes records),
TXT registry with owner-id chalupa-talos and prefix _edns.

ExternalSecret syncs the same Cloudflare token (from OpenBao path
secret/cloudflare/api-token, key 'token') as cert-manager.
EOF
)"
git push -u origin feat/gitops-external-dns-chart
gh pr create --title "feat(gitops): add external-dns wrapper" \
  --body "$(cat <<'EOF'
## Summary

- Adds \`gitops/apps/platform/external-dns/\` wrapping external-dns 1.21.1
- Cloudflare provider, source: traefik-proxy
- Domain filter: \`frame.chalupatech.com\`, policy: upsert-only (never deletes)
- ExternalSecret syncs same Cloudflare token from OpenBao
- TXT registry with owner-id \`chalupa-talos\`, prefix \`_edns.\`

Part 7/9 of sub-project #2.

## Test plan

- [ ] CI renders chart and validates manifests
- [ ] Post-merge: \`kubectl -n external-dns get pods\` shows external-dns Running
- [ ] Post-merge: \`kubectl -n external-dns get externalsecret\` shows SecretSynced=True
- [ ] Post-merge: \`kubectl -n external-dns logs -l app.kubernetes.io/name=external-dns --tail=30\` shows it polling but no records to create yet (no IngressRoutes exist)
- [ ] Post-merge: \`kubectl -n argocd get application external-dns\` shows Synced/Healthy
EOF
)"
gh pr checks --watch
gh pr merge --squash --delete-branch
```

**Step 7.10: Post-merge verification**

```bash
gh run watch
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
kubectl -n external-dns get pods
kubectl -n external-dns get externalsecret cloudflare-api-token
kubectl -n external-dns logs -l app.kubernetes.io/name=external-dns --tail=20
kubectl -n argocd get application external-dns
```

Expected:
- external-dns pod Running
- ExternalSecret SecretSynced=True
- Logs show "All records are already up to date" or similar (nothing to do yet — no IngressRoutes targeting frame.chalupatech.com)
- ArgoCD Application Synced/Healthy

**Acceptance criteria for "DONE":**
- All chart files committed.
- CI passes; PR squash-merged.
- Post-merge: external-dns Application Synced/Healthy and pod Running.
- Post-merge: ExternalSecret SecretSynced=True and Secret exists.

---

## Task 8: ArgoCD IngressRoute (modify existing wrapper)

Adds two IngressRoutes (HTTP and HTTPS) and a redirect Middleware to the existing `gitops/apps/platform/argocd/` wrapper chart. After this merges, ArgoCD UI is reachable at `https://argocd.frame.chalupatech.com`.

**Files:**
- Create: `gitops/apps/platform/argocd/templates/ingressroute.yaml`
- Modify: nothing else; `argocd-server` chart values already have `server.insecure: true` (TLS terminates at Traefik).

**Step 8.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/argocd-ingressroute
```

**Step 8.2: Write `gitops/apps/platform/argocd/templates/ingressroute.yaml`**

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-http
  namespace: argocd
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`argocd.frame.chalupatech.com`)
      kind: Rule
      middlewares:
        - name: redirect-to-https
          namespace: traefik
      services:
        - name: argocd-server
          port: 80
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-https
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`argocd.frame.chalupatech.com`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
  tls: {}
```

The HTTP IngressRoute uses Traefik's `redirect-to-https` Middleware (cross-namespace reference, enabled via Traefik's `allowCrossNamespace=true` from Task 6). The HTTPS IngressRoute leaves `tls: {}` empty — Traefik falls back to the default TLSStore which references the wildcard cert.

**Step 8.3: Render and validate**

```bash
cd gitops/apps/platform/argocd
helm dependency update
helm template argocd . > /tmp/argocd-rendered.yaml
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/argocd-rendered.yaml
grep -A 3 "kind: IngressRoute" /tmp/argocd-rendered.yaml
cd -
```

Expected: clean render. The `grep` should show both IngressRoutes.

**Step 8.4: Commit, push, PR, merge**

```bash
git add gitops/apps/platform/argocd/templates/ingressroute.yaml
git commit -m "$(cat <<'EOF'
feat(gitops): expose ArgoCD UI at argocd.frame.chalupatech.com

Adds two IngressRoutes to the existing argocd wrapper chart:
- argocd-http (entryPoint web): redirects to HTTPS via the Traefik
  cross-namespace Middleware redirect-to-https
- argocd-https (entryPoint websecure): routes to argocd-server:80,
  uses Traefik's default TLSStore wildcard cert

After merge: external-dns observes the IngressRoute and creates
the Cloudflare A record argocd.frame.chalupatech.com -> 192.168.1.230.
The ArgoCD UI is reachable with a valid Let's Encrypt cert.
EOF
)"
git push -u origin feat/argocd-ingressroute
gh pr create --title "feat(gitops): expose ArgoCD UI at argocd.frame.chalupatech.com" \
  --body "$(cat <<'EOF'
## Summary

Adds HTTP + HTTPS IngressRoutes to the existing argocd wrapper chart. After merge:

- external-dns creates Cloudflare A record \`argocd.frame.chalupatech.com -> 192.168.1.230\`
- Traefik routes the host to argocd-server:80 with the wildcard TLS cert
- HTTP requests get a permanent redirect to HTTPS

Part 8/9 of sub-project #2. The ArgoCD UI exposure was the original "configure ArgoCD as a service" goal from way back in sub-project #1's brainstorming.

## Test plan

- [ ] CI renders chart and validates manifests
- [ ] Post-merge: \`kubectl -n argocd get ingressroute\` shows argocd-http and argocd-https
- [ ] Post-merge: \`dig +short argocd.frame.chalupatech.com\` returns 192.168.1.230 (within ~1 minute of merge)
- [ ] Post-merge: \`curl -I http://argocd.frame.chalupatech.com\` returns a 308 redirect to HTTPS
- [ ] Post-merge: \`curl -I https://argocd.frame.chalupatech.com\` returns 200 with valid Let's Encrypt cert
- [ ] Post-merge: ArgoCD UI loads in browser with green padlock; admin login works
EOF
)"
gh pr checks --watch
gh pr merge --squash --delete-branch
```

**Step 8.5: Post-merge verification**

```bash
gh run watch
export KUBECONFIG=~/.kube/chalupa-cluster.yaml

kubectl -n argocd get ingressroute

# Wait up to 90s for external-dns to create the Cloudflare record
for i in $(seq 1 18); do
  ip=$(dig +short @1.1.1.1 argocd.frame.chalupatech.com | head -1)
  if [ -n "$ip" ]; then
    echo "DNS resolved: $ip"
    break
  fi
  echo "Waiting for DNS... ($i/18)"
  sleep 5
done

curl -sI http://argocd.frame.chalupatech.com -m 10
echo "---"
curl -sI https://argocd.frame.chalupatech.com -m 10
```

Expected:
- Both IngressRoutes present.
- DNS resolves to `192.168.1.230` within ~1-2 minutes.
- HTTP returns `HTTP/1.1 308` (or similar redirect to HTTPS).
- HTTPS returns `HTTP/2 200` (or 302 to login) — and importantly, the cert is valid (no `-k` needed).

**Acceptance criteria for "DONE":**
- IngressRoutes file committed and CI passes.
- PR squash-merged.
- Post-merge: DNS resolves, HTTPS returns valid response with valid cert.
- Post-merge: ArgoCD UI accessible in a browser at `https://argocd.frame.chalupatech.com`.

---

## Task 9: OpenBao IngressRoute (modify existing wrapper)

Same pattern as Task 8 but for OpenBao. After this merges, OpenBao UI is reachable at `https://openbao.frame.chalupatech.com`.

**Files:**
- Create: `gitops/apps/platform/openbao/templates/ingressroute.yaml`

**Step 9.1: Create branch**

```bash
git checkout main && git pull
git checkout -b feat/openbao-ingressroute
```

**Step 9.2: Write `gitops/apps/platform/openbao/templates/ingressroute.yaml`**

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: openbao-http
  namespace: openbao
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`openbao.frame.chalupatech.com`)
      kind: Rule
      middlewares:
        - name: redirect-to-https
          namespace: traefik
      services:
        - name: openbao
          port: 8200
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: openbao-https
  namespace: openbao
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`openbao.frame.chalupatech.com`)
      kind: Rule
      services:
        - name: openbao
          port: 8200
  tls: {}
```

Note the service is named `openbao` (the OpenBao chart's primary Service); port `8200` is the OpenBao HTTP API/UI port.

**Step 9.3: Render and validate**

```bash
cd gitops/apps/platform/openbao
helm dependency update
helm template openbao . > /tmp/openbao-rendered.yaml
kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/openbao-rendered.yaml
grep -A 3 "kind: IngressRoute" /tmp/openbao-rendered.yaml
cd -
```

**Step 9.4: Commit, push, PR, merge**

```bash
git add gitops/apps/platform/openbao/templates/ingressroute.yaml
git commit -m "$(cat <<'EOF'
feat(gitops): expose OpenBao UI at openbao.frame.chalupatech.com

Adds two IngressRoutes (HTTP+HTTPS) targeting the openbao Service
on port 8200. Mirrors the Task 8 ArgoCD pattern. After merge:
external-dns creates the Cloudflare A record, Traefik routes the
host to OpenBao with the wildcard cert, OpenBao UI is reachable.
EOF
)"
git push -u origin feat/openbao-ingressroute
gh pr create --title "feat(gitops): expose OpenBao UI at openbao.frame.chalupatech.com" \
  --body "$(cat <<'EOF'
## Summary

Adds HTTP + HTTPS IngressRoutes to the existing openbao wrapper chart. Mirrors the Task 8 ArgoCD IngressRoute pattern. After merge:

- external-dns creates Cloudflare A record \`openbao.frame.chalupatech.com -> 192.168.1.230\`
- Traefik routes the host to the openbao Service on port 8200 with the wildcard TLS cert

Part 9/9 of sub-project #2 — the final task.

## Test plan

- [ ] CI renders chart and validates manifests
- [ ] Post-merge: \`kubectl -n openbao get ingressroute\` shows openbao-http and openbao-https
- [ ] Post-merge: \`dig +short openbao.frame.chalupatech.com\` returns 192.168.1.230
- [ ] Post-merge: \`curl -I https://openbao.frame.chalupatech.com\` returns 200 with valid Let's Encrypt cert
- [ ] Post-merge: OpenBao UI loads in browser with green padlock
EOF
)"
gh pr checks --watch
gh pr merge --squash --delete-branch
```

**Step 9.5: Post-merge verification**

```bash
gh run watch
export KUBECONFIG=~/.kube/chalupa-cluster.yaml

kubectl -n openbao get ingressroute

for i in $(seq 1 18); do
  ip=$(dig +short @1.1.1.1 openbao.frame.chalupatech.com | head -1)
  if [ -n "$ip" ]; then
    echo "DNS resolved: $ip"
    break
  fi
  echo "Waiting for DNS... ($i/18)"
  sleep 5
done

curl -sI https://openbao.frame.chalupatech.com -m 10
```

Expected: DNS resolves, HTTPS returns valid response.

Open `https://openbao.frame.chalupatech.com` in a browser. The OpenBao UI loads. Login with the root token from `~/secure/openbao-init.json`.

**Acceptance criteria for "DONE":**
- IngressRoutes file committed and CI passes.
- PR squash-merged.
- Post-merge: DNS resolves; HTTPS returns valid cert; OpenBao UI loads.

---

## Final Verification

After Task 9 merges, verify the end-state matches the spec's acceptance criteria:

- [ ] **F-1:** `kubectl -n argocd get application` shows 8 platform Applications + `root` — all `Synced/Healthy`:
  - Existing: `argocd`, `metallb`, `local-path-provisioner`
  - New: `openbao`, `external-secrets`, `cert-manager`, `traefik`, `external-dns`

- [ ] **F-2:** `kubectl -n openbao exec openbao-0 -- bao status` reports `Initialized: true, Sealed: false`.

- [ ] **F-3:** `kubectl -n cert-manager get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'` returns `True`.

- [ ] **F-4:** `kubectl -n traefik get certificate wildcard-frame-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'` returns `True`. `kubectl -n traefik get secret wildcard-frame-tls` exists.

- [ ] **F-5:** `kubectl -n traefik get svc traefik` has `EXTERNAL-IP: 192.168.1.230`.

- [ ] **F-6:** `kubectl get ingressroute -A` shows ArgoCD and OpenBao IngressRoutes (HTTP + HTTPS for each, 4 total).

- [ ] **F-7:** `dig +short @1.1.1.1 argocd.frame.chalupatech.com` returns `192.168.1.230`. Same for `openbao.frame.chalupatech.com`.

- [ ] **F-8:** `curl -I https://argocd.frame.chalupatech.com` returns valid response with valid Let's Encrypt cert (no `-k` needed). Same for `openbao.frame.chalupatech.com`.

- [ ] **F-9:** Browser test: ArgoCD UI loads at `https://argocd.frame.chalupatech.com` with green padlock; admin login works. OpenBao UI loads at `https://openbao.frame.chalupatech.com`; root-token login works.

- [ ] **F-10:** **GitOps loop proof:** edit a benign field in `gitops/apps/platform/cert-manager/values.yaml` (e.g., bump a resource request), open PR, merge. cert-manager Application reconciles within ~3 minutes. Pipeline does NOT need to rerun cert-manager's Helm install.

If F-1 through F-10 all pass, sub-project #2 is complete. Move on to sub-project #3 (Media Stack).

---

## Risks and Recovery

- **OpenBao stuck pre-Task-4:** the StatefulSet rolls out, pods are Running, but `bao status` reports Sealed=true. This is expected. Run the Task 4 runbook.

- **ESO ClusterSecretStore Failed:** typically means OpenBao's Kubernetes auth role doesn't match. Check Task 4 step 4.4 ran successfully. Re-run if needed (the role-write commands are idempotent).

- **cert-manager ExternalSecret SecretSyncFailed:** check `kubectl -n cert-manager describe externalsecret cloudflare-api-token` for the error. Common: ClusterSecretStore not yet Ready, or path wrong. Wait or fix the OpenBao path.

- **Wildcard Certificate stuck Issuing:** check `kubectl -n traefik describe challenge`. Common: Cloudflare token doesn't have DNS:Edit on the right zone. Re-seed the token via `kv-put.sh` and `kubectl -n cert-manager rollout restart deployment/cert-manager`.

- **Traefik IP not assigned by MetalLB:** check `kubectl -n traefik describe svc traefik` and `kubectl -n metallb get ipaddresspool`. Confirm `192.168.1.230` is in the pool range and not already allocated.

- **DNS records not appearing in Cloudflare:** check `kubectl -n external-dns logs --tail=50`. Common: token doesn't have Zone:Read on the zone. Re-seed.

- **Cluster reboot drops OpenBao back to Sealed:** routine. Run `./scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json`.

- **Lost `~/secure/openbao-init.json` and not in 1Password:** OpenBao is unrecoverable. All stored secrets must be re-seeded after reinitialization. Procedure: scale OpenBao StatefulSet to 0, delete the 3 PVCs (`kubectl -n openbao delete pvc data-openbao-0 data-openbao-1 data-openbao-2`), scale back to 3, re-run Task 4 from step 4.2.

---

## Out of Scope (Reminders)

These were explicitly de-scoped during brainstorming and are not implemented by this plan:

- ArgoCD SSO/OIDC integration
- OpenBao OIDC provider role
- Auto-unseal via cloud KMS
- Per-host certificates (we use one wildcard)
- Velero / backups (sub-project #5)
- Renovate / image automation
- Network policies between namespaces
- Tailscale Operator
