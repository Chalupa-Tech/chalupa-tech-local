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
OPENBAO_TOKEN=$(jq -r '.root_token' ~/secure/openbao-init.json) \
  ./scripts/openbao/kv-put.sh <path> <key> <value>

# Examples:
OPENBAO_TOKEN=$(jq -r '.root_token' ~/secure/openbao-init.json) \
  ./scripts/openbao/kv-put.sh cloudflare/api-token token "abc123..."
OPENBAO_TOKEN=$(jq -r '.root_token' ~/secure/openbao-init.json) \
  ./scripts/openbao/kv-put.sh sonarr/api-key apikey "deadbeef..."
```

For ongoing operations, replace the root token with a per-operator token that has `update` capability on the relevant `secret/data/<path>` paths. Keep the root token in 1Password and only export it for the rare administrative operations that need it.

### Phase 5: Routine — Update a policy (e.g. add a new app's KV path)

Policies are codified in `scripts/openbao/policies/<name>.hcl` and applied with `apply-policy.sh`. The .hcl file is the source of truth; if it drifts from the live policy, re-apply.

```bash
# 1. Edit the .hcl file (e.g. add a new `path "secret/data/myapp/*" { capabilities = ["read"] }` line)
$EDITOR scripts/openbao/policies/media-read.hcl

# 2. Apply (idempotent — bao policy write replaces in-place)
OPENBAO_TOKEN=$(jq -r '.root_token' ~/secure/openbao-init.json) \
  ./scripts/openbao/apply-policy.sh media-read

# 3. Verify drift = 0
kubectl -n openbao exec openbao-0 \
  -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$OPENBAO_TOKEN" \
    bao policy read media-read
```

**Workflow for a new app needing a Bao path:** add the path line to the relevant policy .hcl, apply it (or hand the apply step to the operator runbook in the same PR), then commit both the .hcl change and the new app's ExternalSecret manifest in one PR.

**Currently codified:** `media-read.hcl`. The two sibling policies `cloudflare-read` and `observability-read` are still hand-maintained on the live cluster only — codify them the next time they need editing.

## Security notes

- KV values flow over `kubectl exec` stdin and never appear in any process's `argv`. Path and key arguments are passed as direct args to `bao kv put` (not via a shell-interpolated string), so quoting edge cases are not a concern.
- The `OPENBAO_TOKEN` value appears in `kubectl`'s `argv` on the operator's Mac (briefly, as an `--env` flag value) but does **not** appear in the container's process table — `kubectl exec --env` injects environment variables to the exec'd process directly. Avoid running these scripts on shared/multi-user machines.
- Unseal keys are piped via stdin to `bao operator unseal -` so they do not appear in `argv` on either side.
- `unseal.sh` accepts keys via env vars or a `--keys-file` JSON path. The JSON file should live somewhere encrypted at rest (e.g., `~/secure/`) and should not be committed.
- `kv-put.sh` requires `OPENBAO_TOKEN`; do not export this variable in your shell history. Set it inline (`OPENBAO_TOKEN=$(...) ./scripts/openbao/kv-put.sh ...`) or in a single-shot subshell.
- `apply-policy.sh` pipes the .hcl via stdin (file contents never appear in argv) and passes the token via `env` (see `kv-put.sh` for the same pattern + rationale).
