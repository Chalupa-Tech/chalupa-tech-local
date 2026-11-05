# PR 4 — Platform patch flow (Renovate coverage + Talos/K8s rolling upgrades) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Renovate sees every version we pin (and can actually look up linuxserver images), platform patch releases and Renovate's own image flow without a human, and a merged Talos/Kubernetes pin bump upgrades the nodes one at a time with health gates and automatic rollback.

**Architecture:** `renovate.json` gains ring policy (platform *patch* automerge incl. the renovate chart; Talos/K8s patch automerge, minor PR, major approval; HAOS minor/patch automerge), `osvVulnerabilityAlerts`, and regex managers for the remaining pins (ArgoCD bootstrap chart version, kubeconform, yamllint, DepotDownloader, single-line `image: repo:tag`), plus the `terraform` manager. The Renovate wrapper's `config.js` adds `hostRules` for `ghcr.io` and `lscr.io` using the minted App token, and the explicit image `tag` pin is removed so the chart's `appVersion` drives the running version. `deploy.yml` gains Stage 2c `talos-upgrade`, running `scripts/talos/rolling-upgrade.sh` before Stage 2b whenever `talosVersion`/`kubernetesVersion` changed (or on dispatch): etcd snapshot, pre-flight (all nodes Ready, OpenBao all unsealed — else refuse), per-node `talosctl upgrade --preserve --wait`, gates (node Ready, etcd quorum, argocd+traefik Healthy, ClusterSecretStore Ready, re-unseal via `scripts/openbao/unseal-ci.sh` if keys present), `talosctl rollback` on gate timeout; then `talosctl upgrade-k8s` if the K8s pin changed.

**Tech Stack:** Renovate 44.x config (JSON5-compatible JSON), Helm wrapper chart values, GitHub Actions, bash + shellcheck, `talosctl`, `kubectl`, Pulumi stack outputs.

**Spec:** §5.2 rings 1, 2 + "Stage 2c"; §5.3; §6 PR 4; §7 item 3; §8 decision 1.

## Global Constraints

- Renovate rules (exact): platform charts: `matchUpdateTypes: ["patch"]` → `automerge: true, platformAutomerge: true`; `["minor"]` → grouped Monday PR (existing); `["major"]` → approval (existing). `renovate` chart (`gitops/apps/infra-tools/renovate/**`) joins the platform patch/minor rules. `siderolabs/talos`: patch automerge, minor PR (no approval), major approval. `kubernetes/kubernetes`: patch automerge, minor+major approval. `home-assistant/operating-system`: minor+patch automerge. `go`, `muhlba91/pulumi-proxmoxve`: unchanged (approval).
- `hostRules` in config.js: `[{ matchHost: 'ghcr.io', hostType: 'docker', username: 'x-access-token', password: token }, { matchHost: 'lscr.io', hostType: 'docker', username: 'x-access-token', password: token }]` where `token` is the minted installation token already read from `/auth/token`. Owner adds `packages: read` to the GitHub App (§7 item 3).
- Renovate image: delete `renovate.image.tag` from `gitops/apps/infra-tools/renovate/values.yaml`; pin the init image `node:22.22.0-alpine` (verify the current 22.x tag on Docker Hub at implementation time) and cover it with the single-line regex.
- New regex managers (depName / datasource / file / match): `argo-cd` / `helm` (`registryUrlTemplate: https://argoproj.github.io/argo-helm`) / `.github/workflows/deploy.yml` / `--version (?<currentValue>[0-9.]+)` on the line following `helm upgrade --install argocd`; `yannh/kubeconform` / `github-releases` / `gitops.yml` / `kubeconform/releases/download/(?<currentValue>v[0-9.]+)`; `yamllint` / `pypi` / `gitops.yml` / `yamllint==(?<currentValue>[0-9.]+)`; `SteamRE/DepotDownloader` / `github-releases` / `oracle-cloud-server/ansible/roles/valheim/defaults/main.yml` / `depotdownloader_version: "(?<currentValue>[0-9.]+)"` with `extractVersionTemplate: ^DepotDownloader_(?<version>.+)$`; single-line images: `/gitops/apps/.+/values\.ya?ml$/` + `image:\s+(?<depName>[^:\s"']+):(?<currentValue>[^\s"']+)` (docker).
- Enable `"terraform"` in `enabledManagers`; add `"osvVulnerabilityAlerts": true` and `"vulnerabilityAlerts": {"labels": ["security"], "automerge": false}`.
- Stage 2c runs only when `pulumi-talos/main.go` changed one of the two constants between `github.event.before` and `github.sha` (compare with `git show <sha>:pulumi-talos/main.go | grep -E 'talosVersion =|kubernetesVersion ='`), or `workflow_dispatch` input `talos_upgrade: true`. It `needs: deploy-proxmox-prep` (ISO staged) and Stage 2b `needs` it.
- Installer image: `factory.talos.dev/installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:<talosVersion>` — schematic read from `ansible/roles/proxmox_prep/defaults/main.yml` (`proxmox_prep_talos_schematic_id`) so there is one source.
- Node order: `192.168.1.225 192.168.1.228 192.168.1.229` then `192.168.1.226 192.168.1.227 192.168.1.232`. Per-node timeout 15 m; gate timeout 10 m; on gate timeout: `talosctl -n <ip> rollback`, wait Ready, exit 1.
- Pre-flight refuses (exit 1, nothing touched) if any OpenBao replica is sealed and `OPENBAO_UNSEAL_KEYS` is absent — the PDB would block the drain (verified live: allowed disruptions 0 while `openbao-2` is sealed).

## Review Focus

1. A Talos *minor* bump merged by a human must still not run `upgrade-k8s` to a version outside the new Talos support matrix — Stage 2c upgrades K8s only to the repo's pinned `kubernetesVersion`, never to a Talos default (Task 3 test `k8s_upgrade_uses_repo_pin_only`).
2. Rolling upgrade must stop at the first failing node and leave the remaining nodes untouched (Task 3 test `stops_after_first_failure`).
3. `hostRules` must not leak the token into logs (`LOG_LEVEL: info`; config.js never prints it) — Task 2 verification greps a dry-run log.
4. The single-line `image:` regex must not double-match the bjw-s `repository:`/`tag:` pairs (Task 1 validator run + `renovate --dry-run` lists each image once).
5. Removing the Renovate image tag jumps 43.231.4 → 44.175.0 (major): config-migration warnings must be read in the first run log (Task 2 verification).

---

### Task 1: `renovate.json` policy + coverage

**Files:** Modify `renovate.json`; Create `scripts/renovate/validate.sh` (`npx --yes --package renovate@44 renovate-config-validator renovate.json`).
- [ ] Step 1: edit per Global Constraints. Step 2: `bash scripts/renovate/validate.sh` Expected: `Config validated successfully`. Step 3: dry-run discovery: `docker run --rm -v "$PWD":/repo -e RENOVATE_CONFIG_FILE=/repo/renovate.json -e LOG_LEVEL=info ghcr.io/renovatebot/renovate:44 --platform=local --dry-run=extract` (or `npx renovate --platform=local --dry-run=extract`) → output lists `argo-cd`, `yannh/kubeconform`, `yamllint`, `SteamRE/DepotDownloader`, `node`, and the `oracle/oci` terraform provider. Step 4: commit `feat(renovate): ring policy, OSV alerts, coverage for remaining pins`.

### Task 2: Renovate wrapper — ghcr/lscr hostRules, image tag follows chart

**Files:** Modify `gitops/apps/infra-tools/renovate/values.yaml` (drop `image.tag`, pin `node:22.x.y-alpine`, add `hostRules` to `config`), `gitops/apps/infra-tools/renovate/Chart.yaml` (bump to the current chart — take PR #410's value).
- [ ] Step 1: edit. Step 2: `helm dependency update gitops/apps/infra-tools/renovate && helm template renovate gitops/apps/infra-tools/renovate --api-versions external-secrets.io/v1 | kubeconform -strict -ignore-missing-schemas -summary -schema-location default` → `Errors: 0`; `helm template … | grep -A2 'image:' | grep renovatebot` shows the chart's appVersion tag, not 43.231.4. Step 3: commit `fix(renovate): authenticate ghcr/lscr lookups; run the chart's appVersion`.

### Task 3: `scripts/talos/rolling-upgrade.sh`

**Files:** Create `scripts/talos/rolling-upgrade.sh`, `scripts/talos/tests/test_rolling_upgrade.sh` (stubs `talosctl`, `kubectl`, `scripts/openbao/unseal-ci.sh` via PATH/env).
**Interfaces:** `rolling-upgrade.sh --talos-version v1.14.5 --k8s-version 1.36.0 [--schematic <id>] [--nodes-cp "…"] [--nodes-worker "…"]`; env `TALOSCONFIG`, `KUBECONFIG`, `OPENBAO_UNSEAL_KEYS` (optional). Exit 0 all nodes done; 1 on refusal/failure (after rollback attempt). Prints one `node <ip>: upgraded|skipped(already at version)|FAILED(rolled back)` line per node.
- [ ] Step 1: failing tests: `skips_nodes_already_at_version`, `refuses_when_openbao_sealed_without_keys`, `upgrades_cp_before_workers`, `stops_after_first_failure` (2nd node gate stub fails → rollback called for it, 3rd..6th untouched, exit 1), `k8s_upgrade_uses_repo_pin_only` (`upgrade-k8s --to 1.36.0` exactly once, only when `--k8s-version` differs from the stubbed running version), `snapshots_etcd_first`.
- [ ] Step 2 → FAIL. Step 3: implement. Step 4: `bash scripts/talos/tests/test_rolling_upgrade.sh && shellcheck scripts/talos/rolling-upgrade.sh` → `PASS`. Step 5: commit `feat(talos): rolling node upgrade script with gates and rollback`.

### Task 4: Stage 2c in `deploy.yml` + weekly `etcd-snapshot.yml` (if not already in PR 2)

**Files:** Modify `.github/workflows/deploy.yml` (job `deploy-talos-upgrade` between Stage 1 and Stage 2b; `workflow_dispatch` input `talos_upgrade`), docs.
- [ ] Step 1: write job: checkout → setup-go → connect-proxmox → install `talosctl` (version = `talosVersion` from main.go) + kubectl + Pulumi CLI → `pulumi stack output talosconfig --show-secrets` / kubeconfig → run script with versions parsed from `pulumi-talos/main.go` and schematic from the Ansible defaults → `timeout-minutes: 120`. Stage 2b `needs` gains this job with `result != 'failure'`.
- [ ] Step 2: `actionlint .github/workflows/deploy.yml` clean; `grep -n "needs:" deploy.yml` shows 2b depends on 2c. Step 3: commit `ci: Stage 2c rolling Talos/K8s upgrade on pin bumps`.

### Task 5: Docs + PR

- `docs/2026-11-04-platform-patch-flow.md` (ring table, the approval matrix, how a Talos bump now flows end-to-end, the `openbao-2` prerequisite, GitHub App permission change), update `docs/2026-09-19-talos-1.14-upgrade-k8s-version-pin.md` "Upgrade runbook going forward" to point at Stage 2c, CLAUDE.md Talos paragraph.
- Full verification: Task 1 validator, Task 2 render, Task 3 tests, actionlint. PR `feat: Renovate coverage + automated Talos/K8s rolling upgrades (PR 4/5)` stacked on PR 3.
