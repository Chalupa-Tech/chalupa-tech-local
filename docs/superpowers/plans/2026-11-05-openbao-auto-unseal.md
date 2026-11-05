# OpenBao auto-unseal (OCI KMS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** OpenBao replicas unseal themselves after any restart via an OCI Vault software key, at $0, with a tested init container, Terraform for the OCI side, and a migration runbook.

**Architecture:** Terraform creates the free vault/key/IAM user/policy and outputs the key id + endpoints. The wrapper chart adds an init container (same image as the server) that fetches the pinned `kms-oci` plugin, verifies its sha256 and writes `/openbao/kms/seal.hcl`, which the server loads via `extraArgs`. A hand-made bootstrap secret carries the OCI API key and the three seal values. `rolling-upgrade.sh` waits for auto-unseal instead of failing immediately.

**Tech Stack:** Terraform oci provider ~> 9.0, openbao-helm 0.30.4, OpenBao 2.7.1, bash + sha256sum/wget (Alpine image), Renovate 44 custom managers.

**Spec:** `docs/superpowers/specs/2026-11-05-openbao-auto-unseal-design.md`

## Global Constraints
- Plugin pin: version `0.1.1`, tarball sha256 `103735c5b9c14d28ba37bf9c8d7a96c686b1d3afa2c96580b5b0fe0f7a4e9059`, binary inside tarball `openbao-plugin-kms-oci_linux_amd64_v1`, installed as `openbao-plugin-kms-oci`.
- Seal/plugin name `ocikms`; `auth_type_api_key = "true"`; key AES/32 `SOFTWARE`; vault `DEFAULT`.
- Secret name `openbao-oci-kms`, keys `config`, `key.pem`, `key_id`, `crypto_endpoint`, `management_endpoint`; mounted read-only at `/home/openbao/.oci`.
- `ociKms.enabled` defaults to `false`; disabled path performs no network access.
- No automerge for the plugin pin.

## Review Focus
1. Pod restart with `enabled: true` but the secret missing → init must fail loudly (exit 1), never start the server with a half seal.
2. `enabled: false` on a cluster that already migrated → server would start without a seal stanza and refuse to unseal; the runbook says to use `disabled: true` instead (test: seal.hcl contains `disabled = "true"`).
3. Download failure / wrong sha → init exits non-zero and leaves no binary.
4. `rolling-upgrade.sh`: replica that never unseals → still stops cleanly after the wait; replica that unseals during the wait → continues.
5. Terraform apply before the `.pub` exists → no api key resource, no error.

---

### Task 1: kms-init script (TDD)
**Files:** Create `gitops/apps/platform/openbao/files/kms-init.sh`, `gitops/apps/platform/openbao/tests/test_kms_init.sh`.
**Interfaces:** env in: `OCI_KMS_ENABLED`, `OCI_KMS_DISABLED`, `PLUGIN_VERSION`, `PLUGIN_SHA256`, `KMS_DIR`, `PLUGIN_URL` (optional override), `key_id`, `crypto_endpoint`, `management_endpoint`. Out: `$KMS_DIR/plugins/openbao-plugin-kms-oci`, `$KMS_DIR/seal.hcl`.
- [ ] Tests (stub `wget` on PATH copies a fixture tarball built in the test): disabled writes comment-only seal.hcl + no network; enabled happy path writes binary 0755 + seal.hcl with all 4 fields and `version = "v0.1.1"`; bad sha → rc≠0, no binary; missing key_id → rc≠0; `OCI_KMS_DISABLED=true` → `disabled = "true"` line. Run: `bash gitops/apps/platform/openbao/tests/test_kms_init.sh` → FAIL (script missing).
- [ ] Implement (POSIX sh, `set -eu`); run → PASS. Commit `feat(openbao): kms-init script fetching the pinned OCI KMS seal plugin`.

### Task 2: Helm wiring + render test
**Files:** Modify `gitops/apps/platform/openbao/values.yaml`, `Chart.yaml` (description), create `templates/kms-init-configmap.yaml`, `tests/test_render.py`.
- [ ] Test renders with defaults and with `--set ociKms.enabled=true`: init container `kms-init` with the server image, env values, envFrom secret optional; volumes `kms`/`oci-config` (optional, 0440); mounts; args contain `-config=/openbao/kms/seal.hcl`; ConfigMap holds the script verbatim. Run: `/usr/bin/python3 gitops/apps/platform/openbao/tests/test_render.py` → FAIL.
- [ ] Implement; run → PASS; `helm lint`; commit `feat(openbao): wire the OCI KMS seal plugin init container`.

### Task 3: Terraform
**Files:** Create `oracle-cloud-server/terraform/openbao-unseal.tf`, `oracle-cloud-server/terraform/files/README.md`; modify `oracle-cloud-server/README.md` (bootstrap step).
- [ ] `terraform fmt -check`, `terraform init -backend=false && terraform validate` → PASS (validate is the test here; no live apply). Commit `feat(oracle): free OCI Vault key + IAM user for OpenBao auto-unseal`.

### Task 4: rolling-upgrade waits for auto-unseal (TDD)
**Files:** Modify `scripts/talos/rolling-upgrade.sh`, `scripts/talos/tests/test_rolling_upgrade.sh`.
- [ ] Tests: `waits_for_auto_unseal` (stub unseals after 2 polls; `UNSEAL_WAIT_ATTEMPTS=3 UNSEAL_WAIT_SLEEP=0` → continues, no keys); existing `stops_before_next_node_when_sealed_without_keys` still passes with the wait. Run → FAIL. Implement; run → PASS. Commit.

### Task 5: Renovate + proxmox export + docs
**Files:** `renovate.json` (custom manager + rule), `ansible/roles/proxmox_prep/defaults/main.yml`, `docs/2026-11-05-openbao-auto-unseal.md`, `docs/runbooks/openbao-seal-migration.md`, `scripts/openbao/README.md` (Phase 3 + 7), `docs/2026-11-04-os-auto-patching.md`, `docs/2026-11-04-platform-patch-flow.md`, `README.md`, `CLAUDE.md`.
- [ ] `scripts/renovate/validate.sh` → PASS; ansible-lint on the role; yamllint. Commit `docs: OpenBao auto-unseal entry, migration runbook, Renovate pin`.
