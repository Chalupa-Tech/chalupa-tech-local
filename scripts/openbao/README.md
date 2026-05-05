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
