# Secrets + TLS Ingress — Design

**Date:** 2026-05-04
**Status:** Approved (pending implementation plan)
**Sub-project:** #2 of a multi-cycle ArgoCD/GitOps rollout

## Context

Sub-project #1 delivered the GitOps foundation: `gitops/` repository structure, three tiered ApplicationSets, ArgoCD self-management, MetalLB (LoadBalancer pool `192.168.1.160-192.168.1.170`), and local-path-provisioner (default StorageClass). The cluster reconciles cleanly. The remaining gap is everything that depends on real secrets and TLS-terminated ingress: the ArgoCD UI is still only reachable via `kubectl port-forward` on a self-signed cert, no other workload can be exposed, and there is no shared secret backend.

Sub-project #2 closes that gap end-to-end. After merge, internal hostnames under `*.frame.chalupatech.com` resolve to a Traefik LoadBalancer IP, all carry valid Let's Encrypt certificates, and operators can store secrets in OpenBao that workloads consume via External Secrets Operator (ESO) — no plaintext secrets in Git, no secrets pasted into the deploy pipeline.

This is the platform layer that subsequent sub-projects (#3 media stack, #4 home automation, #5 backups) all depend on.

## Roadmap (carry forward)

1. **ArgoCD foundation** — DONE 2026-05-04. Spec: `docs/superpowers/specs/2026-05-03-argocd-foundation-design.md`.
2. **Secrets + TLS Ingress** *(this spec)* — OpenBao + ESO + cert-manager + Traefik + external-dns.
3. **Media stack** — Sonarr, Radarr, Seerr, NzbGet, Tdarr (CPU transcoding) on bjw-s `app-template`, NFS-backed.
4. **Home automation** — Home Assistant + Z-Wave in a new privileged LXC (USB passthrough).
5. **Backups** — Velero or equivalent, target on TrueNAS share.

## Goals

- Run OpenBao as the cluster's secret backend (HA Raft, manual Shamir unseal).
- Run external-secrets-operator with a `ClusterSecretStore` pointing at OpenBao via Kubernetes auth.
- Issue TLS certificates from Let's Encrypt via cert-manager, using Cloudflare DNS-01.
- Run Traefik as the cluster's ingress controller, fronted by a MetalLB LoadBalancer IP.
- Run external-dns to auto-create Cloudflare DNS records from Traefik IngressRoutes.
- Expose ArgoCD UI at `https://argocd.frame.chalupatech.com` and OpenBao UI at `https://openbao.frame.chalupatech.com` with valid certs.
- Provide an operator runbook plus two helper scripts (`unseal.sh`, `kv-put.sh`) for the recurring OpenBao operations.

## Non-Goals (explicitly out of scope)

- OpenBao OIDC provider role (no SSO into other apps from OpenBao yet).
- ArgoCD SSO/OIDC integration (#2 keeps password auth via the kubectl-retrievable initial admin secret).
- Auto-unseal via cloud KMS or transit seal (manual Shamir is fine for a homelab).
- Migrating the existing ArgoCD bootstrap helm-install into GitOps (intentional retention from #1).
- Velero / backups (#5).
- Renovate / image automation (backlog).
- Per-host TLS certificates (we use a single wildcard cert for `*.frame.chalupatech.com`).
- Tailscale Operator or other Tailscale K8s integration.
- Network policies between namespaces.

## Architecture

### Tiering

No new tiers. All five new platform apps land under `gitops/apps/platform/`. Sync policy follows the existing platform-tier rules from sub-project #1 (`prune: false, selfHeal: true, retry`, `SkipDryRunOnMissingResource=true`).

### New platform applications

| App | Upstream chart | Purpose |
|---|---|---|
| `openbao` | `openbao` from `https://openbao.github.io/openbao-helm` | HA Raft secret backend, 3 replicas |
| `external-secrets` | `external-secrets` from `https://charts.external-secrets.io` | Sync OpenBao secrets to native K8s Secrets |
| `cert-manager` | `cert-manager` from `https://charts.jetstack.io` | TLS certs from Let's Encrypt via DNS-01 |
| `traefik` | `traefik` from `https://traefik.github.io/charts` | Ingress controller, LoadBalancer service from MetalLB |
| `external-dns` | `external-dns` from `https://kubernetes-sigs.github.io/external-dns/` | Auto-create Cloudflare DNS records from Traefik IngressRoutes |

Each follows the wrapper-chart pattern from #1: a `Chart.yaml` declaring the upstream as a single dependency, a `values.yaml` for tuning, a `templates/` directory for local CRs (IngressRoutes, Issuers, ExternalSecrets, etc.), and a committed `Chart.lock`.

### Secret flow

The critical path the cluster depends on:

```
Operator → OpenBao kv put secret/cloudflare/api-token token=<value>
              ↓
ESO (Kubernetes auth, SA: external-secrets/external-secrets) reads OpenBao via ClusterSecretStore
              ↓
ExternalSecret CR (cert-manager namespace) → K8s Secret cloudflare-api-token
              ↓
cert-manager ClusterIssuer letsencrypt-prod uses the Secret to solve DNS-01
              ↓
cert-manager creates wildcard Certificate for *.frame.chalupatech.com → Secret wildcard-frame-tls
              ↓
Traefik IngressRoutes (and TLSStore) reference the Secret for HTTPS termination
              ↓
HTTPS works for argocd.frame.chalupatech.com, openbao.frame.chalupatech.com, etc.
              ↓
external-dns watches IngressRoutes, creates A records in Cloudflare zone
```

A second ExternalSecret in the `external-dns` namespace pulls the same `secret/cloudflare/api-token` for external-dns's Cloudflare provider. **Both consumers share one Cloudflare API token** scoped to the `chalupatech.com` zone with `Zone.DNS:Edit` (and `Zone.Zone:Read`).

### OpenBao path conventions

- KV v2 secret engine mounted at `secret/`.
- Secrets organized by domain: `secret/<domain>/<name>` with field name(s) inside.
- Initial path for #2: `secret/cloudflare/api-token` with field `token`.
- Future paths (#3, #4, #5) will follow the same convention: `secret/sonarr/api-key`, `secret/postgres/admin-password`, `secret/velero/restic-password`, etc.

### Kubernetes auth roles in OpenBao

Three roles, each bound to a single ServiceAccount in a single namespace, all granted the same read-only policy on `secret/data/cloudflare/*`:

| Role | SA | Namespace | Policy |
|---|---|---|---|
| `cert-manager` | `cert-manager-cloudflare-token` | `cert-manager` | `cloudflare-read` |
| `external-dns` | `external-dns-cloudflare-token` | `external-dns` | `cloudflare-read` |
| `external-secrets` | `external-secrets` | `external-secrets` | `cloudflare-read` |

The `cloudflare-read` policy:

```hcl
path "secret/data/cloudflare/*" { capabilities = ["read"] }
```

Only ESO authenticates as the third role; cert-manager and external-dns get their secrets via ESO-synced K8s Secrets, not direct OpenBao access. The cert-manager and external-dns roles exist primarily so future direct integrations (without ESO indirection) are possible without OpenBao reconfiguration.

### TLS strategy

Single wildcard certificate for `*.frame.chalupatech.com` issued from `letsencrypt-prod` (Let's Encrypt production endpoint, ACME via DNS-01 with Cloudflare). One Certificate resource produces one TLS Secret. Traefik's TLSStore default references that Secret, so any IngressRoute under `*.frame.chalupatech.com` gets HTTPS without per-app cert plumbing.

### DNS strategy

Cloudflare DNS records under the `chalupatech.com` zone. Hosts under `frame.chalupatech.com` resolve to Traefik's MetalLB IP (assigned dynamically from the existing `192.168.1.160-192.168.1.170` pool — Traefik's Service spec doesn't pin a specific IP, but we'll annotate the requested IP if MetalLB picks an inconvenient one).

`external-dns` runs with `domainFilters: [frame.chalupatech.com]` and `policy: upsert-only` (safer than the reference repo's `policy: sync`; prevents accidental record-deletion cascades if an IngressRoute is removed). Records are tagged with TXT registry entries (`txtOwnerId: chalupa-talos`, `txtPrefix: _edns.`) so external-dns only manages records it created.

DNS-01 challenges write `_acme-challenge.frame.chalupatech.com` TXT records via cert-manager's direct Cloudflare API integration (separate from external-dns). Both rely on the same Cloudflare API token.

## Repository layout

Additions only — no changes to existing files.

```
gitops/
├── apps/
│   └── platform/
│       ├── openbao/                NEW
│       │   ├── Chart.yaml
│       │   ├── Chart.lock
│       │   ├── values.yaml
│       │   ├── .helmignore
│       │   └── templates/
│       │       └── namespace.yaml          # standard PSA labels
│       ├── external-secrets/       NEW
│       │   ├── Chart.yaml
│       │   ├── Chart.lock
│       │   ├── values.yaml
│       │   ├── .helmignore
│       │   └── templates/
│       │       ├── namespace.yaml
│       │       └── clustersecretstore.yaml # OpenBao via Kubernetes auth
│       ├── cert-manager/           NEW
│       │   ├── Chart.yaml
│       │   ├── Chart.lock
│       │   ├── values.yaml
│       │   ├── .helmignore
│       │   └── templates/
│       │       ├── namespace.yaml
│       │       ├── cloudflare-token-externalsecret.yaml
│       │       └── clusterissuer.yaml
│       ├── traefik/                NEW
│       │   ├── Chart.yaml
│       │   ├── Chart.lock
│       │   ├── values.yaml
│       │   ├── .helmignore
│       │   └── templates/
│       │       ├── namespace.yaml          # privileged PSA (hostPort)
│       │       ├── wildcard-certificate.yaml
│       │       ├── tlsstore-default.yaml
│       │       └── redirect-middleware.yaml
│       ├── external-dns/           NEW
│       │   ├── Chart.yaml
│       │   ├── Chart.lock
│       │   ├── values.yaml
│       │   ├── .helmignore
│       │   └── templates/
│       │       ├── namespace.yaml
│       │       └── cloudflare-token-externalsecret.yaml
│       └── argocd/                 MODIFIED
│           └── templates/
│               ├── ingressroute.yaml       # NEW: HTTPS at argocd.frame.chalupatech.com
│               └── redirect-middleware.yaml NEW (HTTP → HTTPS)
└── ...
scripts/                            NEW top-level
└── openbao/
    ├── README.md
    ├── unseal.sh
    └── kv-put.sh
```

## Per-app design details

### `gitops/apps/platform/openbao/`

- **Chart:** `openbao` from `https://openbao.github.io/openbao-helm`, latest stable in the 0.x series.
- **Mode:** HA with Raft, 3 replicas, anti-affinity to spread across the three Talos nodes.
- **Storage:** local-path StorageClass (default), `1Gi` per replica.
- **Auth/seal:** none configured at deploy time; pods come up sealed and uninitialized. Operator runs the runbook (below) to init + unseal + configure auth methods.
- **Service:** ClusterIP (UI exposed via Traefik IngressRoute, not directly).
- **PSA:** namespace labelled `pod-security.kubernetes.io/enforce: restricted` (the default).
- **values.yaml** mirrors `Chalupa-Tech/chalupa-infra/k8s/platform/openbao/values.yaml` adjusted for Talos local-path StorageClass (already verified to work for OpenBao Raft in the reference repo).

### `gitops/apps/platform/external-secrets/`

- **Chart:** `external-secrets` from `https://charts.external-secrets.io`, latest stable in 0.x.
- **Mode:** single replica (HA isn't needed for a homelab; controller and webhook can co-exist on one node).
- **CRDs:** `installCRDs: true`.
- **`templates/clustersecretstore.yaml`:** a `ClusterSecretStore` named `openbao` configured with provider type `vault` (OpenBao API-compatible), authenticating via Kubernetes auth using SA `external-secrets/external-secrets` and OpenBao role `external-secrets`. Server URL `http://openbao.openbao.svc.cluster.local:8200` (HTTP intra-cluster; OpenBao's TLS is terminated at Traefik for the UI only).

### `gitops/apps/platform/cert-manager/`

- **Chart:** `cert-manager` from `https://charts.jetstack.io`, latest stable in v1.x (likely v1.15+ at implementation time).
- **CRDs:** `installCRDs: true`.
- **`templates/cloudflare-token-externalsecret.yaml`:** an `ExternalSecret` referencing `ClusterSecretStore` `openbao`, secretKey `token` from `secret/cloudflare/api-token`, target K8s Secret `cloudflare-api-token` in the `cert-manager` namespace.
- **`templates/clusterissuer.yaml`:** `letsencrypt-prod` ClusterIssuer with ACME server `https://acme-v02.api.letsencrypt.org/directory`, DNS-01 solver via Cloudflare using the `cloudflare-api-token` Secret.
- **Email** for ACME registration: configurable via Helm value, default `bigelowtayven+chalupatech@gmail.com` (matching reference repo).
- An additional `ServiceAccount` named `cert-manager-cloudflare-token` exists in the `cert-manager` namespace; this is the SA OpenBao binds to for the `cert-manager` Vault role. cert-manager itself doesn't use this SA for current functionality — it's reserved for future direct OpenBao integration.

### `gitops/apps/platform/traefik/`

- **Chart:** `traefik` from `https://traefik.github.io/charts`, latest stable in 30.x or 31.x.
- **Service type:** LoadBalancer (gets a MetalLB-assigned IP from the existing pool). The chosen IP isn't pinned at first; if MetalLB picks one we don't want, we'll add `loadBalancerIP: 192.168.1.230` (or similar) in a follow-up.
- **Entry points:** `web` (port 80) and `websecure` (port 443) only. No `traefik` admin entry point exposed externally — the dashboard is reachable via `kubectl port-forward` if needed.
- **`templates/wildcard-certificate.yaml`:** a `Certificate` resource named `wildcard-frame-tls` requesting `*.frame.chalupatech.com` from `letsencrypt-prod`, target Secret `wildcard-frame-tls` in the `traefik` namespace.
- **`templates/tlsstore-default.yaml`:** a `TLSStore` named `default` referencing the `wildcard-frame-tls` Secret. Traefik uses this as the default cert for TLS connections that don't match a more-specific TLS option.
- **`templates/redirect-middleware.yaml`:** a `Middleware` named `redirect-to-https` doing `redirectScheme: { scheme: https, permanent: true }`. Apps reference this in their HTTP IngressRoutes.
- **PSA:** namespace labelled `pod-security.kubernetes.io/enforce: privileged` initially, downgraded to `baseline` if the chosen Traefik chart values don't actually need privileges (some configs use hostPorts for ports 80/443; we use Service of type LoadBalancer so likely don't need hostPorts — verify post-deploy).

### `gitops/apps/platform/external-dns/`

- **Chart:** `external-dns` from `https://kubernetes-sigs.github.io/external-dns/`, latest stable in 1.x.
- **Provider:** Cloudflare.
- **Sources:** `traefik-proxy` (watches Traefik IngressRoute CRDs).
- **Domain filter:** `[frame.chalupatech.com]`.
- **Policy:** `upsert-only` (creates and updates records, never deletes).
- **TXT registry:** `txtOwnerId: chalupa-talos`, `txtPrefix: _edns.` so external-dns only manages records it created.
- **Cloudflare auth:** `CF_API_TOKEN` env var sourced from K8s Secret `cloudflare-api-token` in `external-dns` namespace, populated by an `ExternalSecret` from OpenBao.

### `gitops/apps/platform/argocd/` (modifications)

Two new files in the existing wrapper:
- **`templates/redirect-middleware.yaml`:** `Middleware` `redirect-to-https` in the `argocd` namespace.
- **`templates/ingressroute.yaml`:** two `IngressRoute`s — one HTTP (entryPoint `web`) at `Host(argocd.frame.chalupatech.com)` referencing the redirect middleware; one HTTPS (entryPoint `websecure`) at the same host with `tls: {}` (uses Traefik's default TLSStore wildcard cert) routing to the `argocd-server` Service on port 80.

`gitops/apps/platform/argocd/values.yaml` is updated to keep `server.insecure: true` (Traefik terminates TLS; ArgoCD's server speaks plain HTTP behind it).

## Bootstrap flow

The merge order matters because some Applications have dependencies that aren't satisfied until others are running and configured. Implementation tasks (defined in the implementation plan, not this spec) will be ordered as follows:

1. **OpenBao + ESO** merged first as separate PRs. OpenBao comes up sealed; ESO comes up but cannot reconcile any ExternalSecret yet (the ClusterSecretStore can't authenticate).
2. **OPERATOR RUNBOOK STEP** (manual, one-time): operator runs the init + unseal + auth-method-configure + token-seed sequence (see runbook below).
3. **cert-manager** merged. The ExternalSecret in its namespace immediately syncs the Cloudflare token; the ClusterIssuer becomes ready.
4. **Traefik** merged. Wildcard Certificate is requested; cert-manager performs DNS-01, the cert is issued within ~2 minutes, the TLS Secret is created. Traefik comes up with a LoadBalancer IP.
5. **external-dns** merged. ExternalSecret syncs the same token; external-dns starts watching Traefik IngressRoutes (currently none) and creating Cloudflare records as IngressRoutes appear.
6. **ArgoCD IngressRoute** merged (modification to existing argocd wrapper). external-dns creates the `argocd.frame.chalupatech.com` A record; Traefik routes the host to argocd-server; HTTPS works.
7. **OpenBao IngressRoute** merged (modification to openbao wrapper). Same flow — DNS record + IngressRoute → `openbao.frame.chalupatech.com` works.

The verification step from sub-project #1's `deploy.yml` extends to cover the new Applications (via implementation-plan PR additions, not specified here at the spec level beyond "verification covers all platform apps").

## Manual runbook

After Tasks 1-2 of the implementation plan land (OpenBao + ESO deployed, both reconciling but functionally inert):

```bash
export KUBECONFIG=~/.kube/chalupa-cluster.yaml

# 1. Init (one-time per cluster lifetime; produces 5 unseal keys + root token)
kubectl -n openbao exec openbao-0 -- bao operator init -key-shares=5 -key-threshold=3 -format=json > ~/secure/openbao-init.json
chmod 600 ~/secure/openbao-init.json
# Save ~/secure/openbao-init.json contents in 1Password under "homelab-openbao-keys" before continuing.

# 2. Unseal all pods (use the helper script)
./scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json

# 3. Configure auth methods + KV + policies + roles (one-time, idempotent)
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

# 4. Seed Cloudflare token
export OPENBAO_TOKEN=$ROOT_TOKEN
./scripts/openbao/kv-put.sh cloudflare/api-token token "<your-cloudflare-api-token-value>"

# Hand off to ArgoCD: from this point on, merging cert-manager / Traefik / external-dns / IngressRoutes
# will reconcile cleanly because the Cloudflare token is available via OpenBao + ESO.
```

After cluster reboot, only step 2 (unseal) needs to run.

## Helper scripts

### `scripts/openbao/unseal.sh`

Idempotent unseal across all three OpenBao pods. Reads keys from a JSON file (output of `bao operator init -format=json`) or three environment variables. Skips pods that are already unsealed.

```bash
#!/usr/bin/env bash
# Unseal all OpenBao pods. Idempotent.
#
# Usage:
#   OPENBAO_KEY_1=... OPENBAO_KEY_2=... OPENBAO_KEY_3=... ./scripts/openbao/unseal.sh
#   ./scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json
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

### `scripts/openbao/kv-put.sh`

Write a single key/value to OpenBao KV v2 mounted at `secret/`. Reads value from stdin if value arg is `-`. Requires `OPENBAO_TOKEN` env var (typically the root token from `openbao-init.json` for runbook seeding, or any token with `update` capability on `secret/data/<path>` for ongoing operations).

```bash
#!/usr/bin/env bash
# Write a key/value to OpenBao KV v2 (mount: secret).
#
# Usage:
#   OPENBAO_TOKEN=<token> ./scripts/openbao/kv-put.sh <path> <key> <value>
#   ./scripts/openbao/kv-put.sh cloudflare/api-token token "abc123..."
#   ./scripts/openbao/kv-put.sh cloudflare/api-token token -    # value from stdin
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

# Send value via stdin to bao to avoid leaking through process args.
printf '%s' "$VALUE" | kubectl -n openbao exec -i openbao-0 -- sh -c "
  export BAO_ADDR=http://127.0.0.1:8200
  export BAO_TOKEN='$OPENBAO_TOKEN'
  bao kv put -mount=secret '$PATH_' '$KEY=-'
"
```

### `scripts/openbao/README.md`

Documents:
- Prerequisites: `KUBECONFIG` set, OpenBao reachable via `kubectl exec`, `jq` installed locally.
- Lifecycle phases (init, configure, routine).
- Security notes: keys/tokens never written to disk by the scripts; values flow over `kubectl exec` stdin and are not visible in process arg listings.
- Pointer to the verbatim runbook commands for the one-time configuration phase.

## Verification

End-of-step verification checklist (run after the final implementation PR merges):

1. `kubectl -n argocd get application` shows 8 platform Applications + `root` — all `Synced/Healthy`:
   - `argocd`, `metallb`, `local-path-provisioner` (existing)
   - `openbao`, `external-secrets`, `cert-manager`, `traefik`, `external-dns` (new)
2. `kubectl -n openbao get pods` shows `openbao-0/1/2` all `Running 1/1`. After unseal, `kubectl -n openbao exec openbao-0 -- bao status` reports `Initialized: true, Sealed: false`.
3. `kubectl -n cert-manager get clusterissuer letsencrypt-prod` shows `Ready: True`.
4. `kubectl -n traefik get certificate wildcard-frame-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'` returns `True`. `kubectl -n traefik get secret wildcard-frame-tls` exists with type `kubernetes.io/tls`.
5. `kubectl -n traefik get svc traefik` shows a LoadBalancer with an external IP from the `192.168.1.160-170` pool.
6. `kubectl get ingressroute -A` shows ArgoCD and OpenBao IngressRoutes (web + websecure variants for each).
7. `dig +short argocd.frame.chalupatech.com` returns the Traefik LoadBalancer IP.
8. `dig +short openbao.frame.chalupatech.com` returns the same IP.
9. `curl -I https://argocd.frame.chalupatech.com` returns `HTTP/2 200` with no `-k` flag needed (valid Let's Encrypt cert). Same for `https://openbao.frame.chalupatech.com`.
10. Browsing `https://argocd.frame.chalupatech.com` in a browser shows ArgoCD UI with green padlock; login with admin user works.
11. **GitOps loop proof:** edit a benign field in `gitops/apps/platform/cert-manager/values.yaml`, merge a PR. cert-manager reconciles without deploy pipeline running its Helm install.

## Risks and mitigations

- **OpenBao manual unseal burden.** Every cluster reboot requires 9 `bao operator unseal` calls (3 per pod × 3 pods). Mitigation: helper script reduces to one command. Reboots should be rare in steady state.
- **Lost unseal keys.** If the keys (and root token) in `openbao-init.json` are lost, OpenBao is unrecoverable — all stored secrets must be re-seeded, and any PVCs backing OpenBao are abandoned. Mitigation: keys go into 1Password under "homelab-openbao-keys" before the runbook proceeds. Document this in the runbook prominently.
- **Cloudflare token blast radius.** A single token with `Zone.DNS:Edit` for the entire `chalupatech.com` zone is shared by cert-manager, external-dns, and (transitively) anything else that mounts the synced Secret. Mitigation: token is scoped to one zone, not account-wide; `policy: upsert-only` on external-dns prevents catastrophic deletes. Future improvement: rotate to per-consumer scoped tokens once the platform is stable.
- **Bootstrap deadlock if cert-manager merges before OpenBao is configured.** cert-manager's ClusterIssuer would be `Ready: False` indefinitely; ArgoCD shows it Degraded. Mitigation: the implementation plan enforces task ordering (OpenBao + ESO first, then operator runbook step, then cert-manager); if a deadlock happens anyway, recovery is to run the runbook and let `retry` re-sync.
- **ACME rate limits.** Let's Encrypt enforces 50 issuances per registered domain per week and 5 duplicate-cert-per-week limits. With one wildcard cert this is far below the limit, but a misconfigured renewal loop could exhaust it. Mitigation: cert-manager renewal uses default `renewBefore` (~30 days), which is well under any rate limit.
- **Talos PSA on Traefik.** If Traefik's chart defaults require `hostNetwork` or `NET_RAW`, the namespace needs `pod-security.kubernetes.io/enforce: privileged`. Mitigation: namespace is labelled privileged from the start (cheap insurance); we'll downgrade to `baseline` post-deploy if observation shows nothing privileged is needed.
- **MetalLB IP pinning for Traefik.** Without an explicit `loadBalancerIP`, MetalLB picks any available IP from the pool; this IP becomes load-bearing for all DNS records. Mitigation: pin `loadBalancerIP: 192.168.1.230` (or similar reserved value) in Traefik's Service spec from day one. The reserved IP is documented in the implementation plan.
- **OpenBao Raft + local-path-provisioner.** Each replica writes to its own node's local disk. If a node is permanently lost, that replica's data is too — but Raft quorum recovers from the surviving 2. Mitigation: this is acceptable for a 3-node homelab; expanding to 5 replicas is overkill.
- **External-secrets-operator's secret-zero problem.** ESO authenticates to OpenBao via Kubernetes auth — its ServiceAccount JWT is the bootstrap credential. If the SA token is somehow stolen, an attacker can read everything ESO can. Mitigation: standard K8s threat model; SA tokens are short-lived and rotated by the kubelet.

## Open questions

None blocking. Small things resolved at implementation time:

- Exact pinned chart versions for openbao-helm, external-secrets, cert-manager, traefik, external-dns — chosen at implementation time from latest-stable in each repo.
- Whether Traefik needs privileged PSA or just baseline — verified post-deploy.
- Whether MetalLB picks a "reasonable" IP for Traefik on first sync, or whether we pin from day one (lean: pin).

## References

- Reference repo wrapper-chart pattern: `Chalupa-Tech/chalupa-infra/k8s/platform/{openbao,cert-manager,external-secrets,external-dns}`.
- Sub-project #1 spec: `docs/superpowers/specs/2026-05-03-argocd-foundation-design.md`.
- Sub-project #1 plan: `docs/superpowers/plans/2026-05-03-argocd-foundation-plan.md`.
- Project conventions: `CLAUDE.md`.
- Memory: `project_talos_psa_constraint.md`, `project_argocd_sync_config.md`, `project_homelab_roadmap.md`.
