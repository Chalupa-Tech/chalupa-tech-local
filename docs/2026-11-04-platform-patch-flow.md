# Platform patch flow: Renovate coverage + automated Talos/Kubernetes upgrades

**Date:** 2026-11-04
**PR:** #TBD (PR 4 of the auto-patching series —
`docs/superpowers/specs/2026-11-04-auto-patching-design.md` §5.2 rings 1–2, §5.3)

## Why

Renovate was running but blind in places: lscr.io (linuxserver) image
lookups hit ghcr.io's anonymous rate limit (429) every run; Renovate's own
image was hand-pinned at 43.231.4 while the chart moved to 44.x (a dozen
unpatched advisories); the ArgoCD bootstrap chart version, kubeconform,
yamllint, DepotDownloader, the token-mint `node` image and the Terraform
provider were tracked by nothing. Platform chart patch releases (security
fixes ship as patches) sat in a PR for days, and a Talos/Kubernetes pin bump
only changed machine-config generation — the nodes were upgraded by hand.

## Rings (what merges itself)

| Dependency | patch | minor | major |
|---|---|---|---|
| media / observability images + charts | auto | auto | approval |
| platform charts (+ Renovate's own chart) | **auto** (new) | grouped Monday PR | approval |
| GitHub Actions, Go modules | auto | auto | approval |
| `siderolabs/talos` | **auto → Stage 2c rolls the nodes** | PR, manual merge → Stage 2c | approval |
| `kubernetes/kubernetes` | **auto → Stage 2c `upgrade-k8s`** | approval (support matrix) | approval |
| `home-assistant/operating-system` | auto | auto | approval |
| Go toolchain, Proxmox provider | approval | approval | approval |

`osvVulnerabilityAlerts` + `vulnerabilityAlerts` open a `security`-labelled
PR immediately for any dependency with a known advisory, outside the
weekday-morning schedule.

## Coverage fixes

- `hostRules` for `ghcr.io` and `lscr.io` use the Renovate GitHub App's
  installation token (App needs **`packages: read`** — owner step).
- Renovate image pinned as a `repository`/`tag` pair (tracked by the docker
  regex manager: minor/patch auto-merge, major approval) so a chart bump can
  never change the running Renovate version; `node:22.23.4-alpine` pinned and
  tracked by a new single-line `image:` regex.
- New regex managers: ArgoCD bootstrap `--version` in `deploy.yml`
  (datasource helm), `yannh/kubeconform` and `yamllint` in `gitops.yml`,
  `depotdownloader_version` (GitHub releases `DepotDownloader_X.Y.Z`); the
  `terraform` manager covers `oracle/oci`. A local `renovate --platform=local
  --dry-run=extract` confirmed every one is detected.
- `bash scripts/renovate/validate.sh` runs the upstream config validator.

## Stage 2c — how a Talos bump flows now

1. Renovate merges `talosVersion` v1.14.1 → v1.14.5 in `pulumi-talos/main.go`
   (patch) or you merge a minor.
2. `deploy.yml` Stage 2c (`deploy-talos-upgrade`) sees the constant changed
   between `github.event.before` and the merge commit and runs
   `scripts/talos/rolling-upgrade.sh`: pre-flight (nodes Ready, etcd,
   **every OpenBao replica unsealed** — a sealed one makes the PDB block the
   drain; a replica restarted by the previous node's drain auto-unseals via
   OCI KMS within a 2-minute wait (`docs/2026-11-05-openbao-auto-unseal.md`);
   on a pre-migration cluster `OPENBAO_UNSEAL_KEYS` unseals it; otherwise
   the run refuses/stops cleanly),
   etcd snapshot, then `talosctl upgrade --preserve --wait` per node:
   .225 → .228 → .229 (control planes) → .226 → .227 → .232 (workers). Each
   node must come back at the target version, Ready, with etcd healthy,
   `argocd`/`traefik` Healthy and the ClusterSecretStore Ready within 10
   minutes, or it is `talosctl rollback`ed and the run stops — later nodes
   are untouched.
3. If `kubernetesVersion` changed too, `talosctl upgrade-k8s --to <pin>`
   runs last (only ever to the repo pin, never a Talos default).
4. Stage 2b (Pulumi) runs after 2c, so machine configs are generated for the
   version the nodes actually run — the ordering the 2026-09-19 incident
   established. `gh workflow run deploy.yml -f talos_upgrade=true` runs 2c on
   demand for the current pins.

The installer image comes from the schematic in
`ansible/roles/proxmox_prep/defaults/main.yml` (qemu-guest-agent), the
same one the ISO uses.

## Owner steps

1. GitHub App `chalupa-renovate`: add **`packages: read`**.
1b. Verify ghcr.io accepts the App installation token before relying on it
   (otherwise lookups would fail instead of rate-limit): from the next
   Renovate job's init container, or by minting a token locally,
   `curl -su x-access-token:$TOKEN "https://ghcr.io/token?scope=repository:renovatebot/renovate:pull"`
   must return a `token`. If it does not, swap the hostRule password for a
   read-only `read:packages` PAT stored in OpenBao next to the App key.
2. Run the seal-migration runbook (`docs/runbooks/openbao-seal-migration.md`,
   whose first step restarts and unseals `openbao-2`, sealed since
   September) before approving the Talos 1.14.5 dashboard item — or, as a
   stop-gap, unseal it by hand / provide `OPENBAO_UNSEAL_KEYS` (PR 3).
3. After merge, the first Renovate run migrates its config to 44.x — read
   that run's log once for migration warnings.
4. The pending dashboard items this policy now auto-handles: Talos 1.14.5
   (patch → auto-merge → Stage 2c); Kubernetes 1.37.x stays approval-gated.

## Verification (local, 2026-11-04)

`renovate-config-validator --strict` passes; `--dry-run=extract` lists all
new dependencies; `scripts/talos/tests/test_rolling_upgrade.sh` (stubbed
talosctl/kubectl: order, skip, sealed-refusal, unseal, rollback-and-stop,
k8s pin, nothing-to-do) PASS; `actionlint`/`yamllint` on `deploy.yml`;
renovate chart renders with the chart's appVersion image.
