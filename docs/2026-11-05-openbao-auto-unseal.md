# 2026-11-05 — OpenBao auto-unseal with OCI KMS (free tier)

Follow-up to the auto-patching series (PRs #428–#432): the one decision the
owner had to make was how OpenBao gets unsealed after the reboots and node
rolls those PRs automate. Answer: Oracle Cloud Vault, "as an init container
in the Helm chart", at $0.

Design: `docs/superpowers/specs/2026-11-05-openbao-auto-unseal-design.md`.
Runbook (migration, verification, rollback): `docs/runbooks/openbao-seal-migration.md`.

## Why this shape

- **Cost.** OCI Vault bills HSM-protected keys (first 20 versions free, then
  per version/month) and virtual private vaults (per hour). A `DEFAULT`
  vault with a `SOFTWARE`-protected AES-256 key is on the free price list
  and on the Always Free service list. Terraform hard-codes both choices
  (`oracle-cloud-server/terraform/openbao-unseal.tf`) and `prevent_destroy`
  guards the key, because losing it makes every raft snapshot unreadable.
- **Plugin, not built-in.** OpenBao ≥ 2.6 moved the cloud seals out of the
  binary; `ocikms` is the `kms-oci` plugin of `openbao/openbao-plugins`.
  KMS plugins must be declared in the config file (they run while sealed),
  so an init container (`files/kms-init.sh`, same image as the server)
  downloads the pinned release tarball, verifies its sha256, installs the
  binary into an emptyDir and writes `/openbao/kms/seal.hcl` (plugin +
  seal stanzas). The server loads that file through
  `server.extraArgs: -config=/openbao/kms/seal.hcl`.
- **Auth from home.** The pods are not OCI instances, so the plugin uses an
  API key (`auth_type_api_key = "true"`) read by the OCI SDK from
  `/home/openbao/.oci/config` + `key.pem`, mounted read-only from the
  hand-made secret `openbao-oci-kms` (ESO cannot supply it: OpenBao is
  sealed when it is needed). The same secret carries `key_id`,
  `crypto_endpoint`, `management_endpoint` (Terraform outputs) via `envFrom`
  on the init container, so the chart values hold no OCIDs.
- **Explicit switch.** `global.ociKms.enabled` defaults to `false`; the
  wiring is unconditional (the subchart does not template its HCL), only
  the seal stanza is. A pod that restarts with `enabled: true` but a
  missing secret stays in `Init` (loud) instead of starting with a broken
  seal. `global.ociKms.disabled: true` writes `disabled = "true"` for a
  migration back.
- **Known upstream bug.** `go-kms-wrapping` inverted `auth_type_api_key` in
  its ocikms wrapper (openbao/go-kms-wrapping#163, open). Plugin v0.1.1
  pins wrapper v2.3.0 (pre-bug), so `true` means API key. Renovate tracks
  the plugin (`kms-oci-v*` releases) but **never automerges it**; its PR
  body says to update the sha256 and re-check #163.

## What changed

| Path | Change |
|---|---|
| `oracle-cloud-server/terraform/openbao-unseal.tf` | vault, key, IAM user/group/policy, optional API key from `files/openbao-unseal-api-key.pub`, five outputs |
| `gitops/apps/platform/openbao/values.yaml` | `global.ociKms.*`; `server.extraArgs`, `extraInitContainers` (kms-init), `volumes`, `volumeMounts` |
| `gitops/apps/platform/openbao/files/kms-init.sh` + `templates/kms-init-configmap.tpl` | the init script (7 tests: `tests/test_kms_init.sh`) |
| `gitops/apps/platform/openbao/tests/test_render.py` | render contract for the wiring |
| `scripts/talos/rolling-upgrade.sh` | `ensure_unsealed` waits up to 2 min (`UNSEAL_WAIT_ATTEMPTS × UNSEAL_WAIT_SLEEP`) for a rescheduled replica to auto-unseal before stopping |
| `renovate.json` | custom manager + no-automerge rule for the plugin pin |
| `ansible/roles/proxmox_prep/defaults/main.yml` | `proxmox_prep_backup_nfs_export: /mnt/AppData/Backups/proxmox` — the TrueNAS export exists (verified from pve1 2026-11-04: `192.168.1.40:/mnt/AppData/Backups`, 192.168.1.0/24, root→root, `k8s/` + `proxmox/` created) |
| docs | this entry, the runbook, `scripts/openbao/README.md` Phase 3/7, the two 2026-11-04 entries that described the manual path |

## Effect on the automation

- `maintenance-window.yml` and deploy.yml Stage 2c no longer depend on
  `OPENBAO_UNSEAL_KEYS`; after a pve1 reboot or a node drain the replica
  unseals itself and the health check / gate sees it within the wait.
- The `OpenBaoSealed` alert stays: it now means "auto-unseal failed" (OCI
  unreachable, secret wrong, plugin download failed) — see the runbook's
  troubleshooting lines.
- Recovery keys: the five Shamir shares. They cannot unseal by themselves;
  DR needs the raft snapshot **and** the OCI key + API key secret.

## Owner steps

1. Generate the API key pair, commit the `.pub`
   (`oracle-cloud-server/terraform/files/README.md`).
2. Merge (stacked on #432); the Oracle workflow applies Terraform; read the
   outputs.
3. Create `openbao-oci-kms`, flip `global.ociKms.enabled: true`, run the
   runbook with the Shamir shares. Also unseals `openbao-2`, sealed since
   September, as its first step.
4. TrueNAS: add `10.10.10.0/24` to the `/mnt/AppData/Backups` export's
   authorized networks — the cluster mounts it via `10.10.10.40` (storage
   subnet), pve1 via `192.168.1.40`.

## Verification done here

- `bash gitops/apps/platform/openbao/tests/test_kms_init.sh` (7/7),
  `/usr/bin/python3 gitops/apps/platform/openbao/tests/test_render.py`,
  `helm lint`, `yamllint`, `shellcheck`.
- `terraform fmt -check`, `terraform validate` with and without the `.pub`.
- `bash scripts/talos/tests/test_rolling_upgrade.sh` (15/15).
- `scripts/renovate/validate.sh`.
- Not possible here: a live apply/migration (needs OCI credentials and the
  Shamir shares). The plugin tarball sha256 was computed from the real
  release asset and matches `checksums-kms-oci.txt`.
