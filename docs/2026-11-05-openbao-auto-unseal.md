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
- **Restarts do not depend on GitHub.** The first start downloads the
  15 MB tarball; after verifying it, `kms-init` keeps a copy on the
  replica's data PVC (`subPath: kms-cache`, never part of the raft files)
  and later starts use it when its sha256 still matches. Only a version
  bump or a rebuilt PVC (node rebuild) downloads again — those need
  network anyway. A cold start after a WAN outage therefore unseals as
  long as OCI itself is reachable, which is the dependency auto-unseal
  inherently has.
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

## Terraform notes

- `prevent_destroy` on the vault, key and API key means any `ForceNew`
  change to them (`vault_type`, `key_shape`, `protection_mode`, the `.pub`
  content) and a stack-level `terraform destroy` fail the plan — on purpose.
  Change those only by migrating OpenBao to a new key first (runbook
  rollback, then forward). `prevent_destroy` only protects resources that
  are still in the configuration, so both Oracle workflows now run
  `scripts/plan-guard.sh` on the JSON plan and refuse any plan that deletes
  or replaces those three resources, or that creates an HSM-protected key
  (the API default when `protection_mode` is omitted), a `VIRTUAL_PRIVATE`
  vault or any HSM/external-KMS resource. The deploy workflow applies the
  guarded plan file, not a fresh plan. Tests: `oracle-cloud-server/terraform/tests/test_plan_guard.sh`.
- IAM: `use keys` would also grant `KEY_EXPORT` (software keys are
  exportable), so a stolen API key could take a permanent copy of the unseal
  key. The policy therefore allows only `KEY_ENCRYPT`/`KEY_DECRYPT` (plus
  `read keys`) on that one key.
- The user OCID and API-key fingerprint outputs are `sensitive`; the PR
  workflow comments a plan *summary* (addresses + actions) instead of the
  raw plan, because comments on a public repository are readable by anyone
  and not masked. Earlier plan comments (e.g. PRs #305–#307, #377) already
  contain the tenancy and resource OCIDs — identifiers, not credentials.
- Creating the IAM user/group/policy needs the CI principal to manage
  identity resources in the tenancy. The bootstrap user is the tenancy
  admin, so this applies; if the apply ever reports `NotAuthorized` on
  `oci_identity_user`, grant that user `manage users, groups, policies in
  tenancy` or create the user by hand and import it.

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

## Public-repo and cost review (2026-11-05)

A second, independent review looked at this branch plus the existing Oracle
stack from two angles: what a public repository exposes, and whether
anything can ever bill. Verdict: the branch's own resources are $0 and the
hardening above closes its two real gaps (key export, silent deletion).
What remains is the owner's, most important first:

1. **Check the Always Free compute allowance now.** Oracle's Always Free
   page (updated 2026-06) states 1,500 OCPU-hours and 9,000 GB-hours per
   month for A1 (≈ 2 OCPU / 12 GB), while the price list still says 3,000 /
   18,000. The Valheim VM is 4 OCPU / 24 GB. Open Billing → Cost Analysis
   and look for any "Compute – Ampere A1" charge since June. If there is
   one, set `instance_ocpus = 2`, `instance_memory_gb = 12`
   (`oracle-cloud-server/terraform/variables.tf`) — the $5 budget should
   also have alerted.
2. **Compartment quota policy** (free, enforced at create time — the only
   hard cap Oracle offers; budgets alert only). Suggested statements, to be
   added as `oci_limits_quota` in the root compartment once item 1 is
   decided (`standard-a1-*` values depend on it):
   `zero kms quota virtual-private-vault-count in tenancy`,
   `set kms quota virtual-vault-count to 1 in tenancy`,
   `zero compute-core quotas in tenancy`,
   `set compute-core quota standard-a1-core-count to <2|4> in tenancy`,
   `zero compute-memory quotas in tenancy`,
   `set compute-memory quota standard-a1-memory-count to <12|24> in tenancy`,
   `set block-storage quota total-storage-gb to 200 in tenancy`,
   `set object-storage quota storage-bytes to 10000000000 in tenancy`.
   There is no quota for HSM key versions; the plan guard covers that.
3. **Object Storage**: the paid-account free allowance is 10 GB Standard +
   50,000 requests/month. The Valheim bucket keeps 30 daily world archives;
   check its size (`oci os bucket get --bucket-name valheim-backups
   --fields approximateSize`) and shorten the lifecycle to 14 days if a
   month of archives approaches 9 GB.
4. **Budget**: lower `budget_amount` to 1 and add an ACTUAL alert with an
   absolute $0.01 threshold targeting the tenancy, so the first cent alerts.
5. **CI supply chain** (pre-existing): the Oracle workflows hold the
   tenancy-admin API key as job-level env next to tag-pinned third-party
   actions that Renovate automerges. Pin those actions by SHA, exclude
   `.github/workflows/oracle*.yml` from automerge, and require one review
   on `oracle-cloud-server/**`.
6. **Events → Notifications** (free) on KMS `ScheduleKeyDeletion`,
   `DisableKey`, `DeleteVault` and on identity API-key create/delete, so the
   7–30-day key-deletion window is noticed.
7. **Plugin bumps**: the release ships OpenPGP `.sig` files signed by a
   subkey of OpenBao's published key; add `gpg --verify` to the Renovate PR
   checklist for the plugin.
8. `preserve_boot_volume = false` on the instance (a replaced instance
   would otherwise keep two 150 GB boot volumes, over the 200 GB free block
   storage).

Not exploitable from the repository: the committed public key (cannot sign
requests), RFC1918 addresses, export paths. After the migration, revoke the
root token kept on disk (`~/secure/openbao-init.json`) and keep the TrueNAS
export's root mapping in mind: a raft snapshot plus the `openbao-oci-kms`
secret now opens the vault, where before it needed 3 Shamir shares.

## Verification done here

- `bash gitops/apps/platform/openbao/tests/test_kms_init.sh` (12/12),
  `/usr/bin/python3 gitops/apps/platform/openbao/tests/test_render.py`,
  `helm lint`, `yamllint`, `shellcheck`.
- `terraform fmt -check`, `terraform validate`; `oracle-cloud-server/terraform/tests/test_plan_guard.sh` (9/9).
- `bash scripts/talos/tests/test_rolling_upgrade.sh` (15/15).
- `scripts/renovate/validate.sh`.
- Not possible here: a live apply/migration (needs OCI credentials and the
  Shamir shares). The plugin tarball sha256 was computed from the real
  release asset and matches `checksums-kms-oci.txt`.

**2026-11-05 follow-up:** the OpenBao StatefulSet uses `updateStrategyType: OnDelete`, so after any chart change it reports *Progressing* until the pods are restarted by hand. The snapshot CronJob/SA/ConfigMap sat in later sync-waves, which made every ArgoCD sync wait on that health and never finish (and queue the next revision). The waves are removed; a sync now applies everything at once and completes, and the pod restart only decides when the new spec takes effect.
