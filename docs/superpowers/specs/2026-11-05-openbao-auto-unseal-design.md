# OpenBao auto-unseal with OCI KMS — design

Follow-up to `2026-11-04-auto-patching-design.md` §8 item 1: the owner chose
option (a), auto-unseal via Oracle Cloud Vault, delivered "as an init
container in the Helm chart". This closes the last gap that kept host
reboots (PR 3) and Talos node upgrades (PR 4) from running unattended: every
one of them reseals an OpenBao replica, and today a human has to unseal it.

## Intent

After this ships, an OpenBao pod that restarts for any reason (node reboot,
drain, image bump, crash) comes back unsealed on its own, with no unseal
share stored anywhere in CI. Oracle spend stays at $0.

## Constraints (verified 2026-11-04/05)

- OCI Vault with **software-protected keys is free** (price list: "Vault —
  Software protected Keys: Free"; Vault is on the Always Free list). HSM
  keys and virtual private vaults cost money and are never created here.
- OpenBao ≥ 2.6 does **not** ship the OCI KMS seal in its binary; it is the
  external KMS plugin `kms-oci` from `openbao/openbao-plugins` (release tag
  `kms-oci-v0.1.1`, asset `openbao-plugin-kms-oci_linux_amd64_v1.tar.gz`,
  tarball sha256 `103735c5b9c14d28ba37bf9c8d7a96c686b1d3afa2c96580b5b0fe0f7a4e9059`).
  KMS plugins can only be declared in the config file (never via the API)
  because they must be available while sealed.
- The cluster is at home, not in OCI, so the plugin authenticates with an
  **API key** (`auth_type_api_key = "true"`) read by the OCI SDK from
  `$HOME/.oci/config` + a PEM file. Plugin v0.1.1 pins
  `go-kms-wrapping/wrappers/ocikms v2.3.0`, where `true` = API key.
  **Newer wrapper versions invert the flag**
  (openbao/go-kms-wrapping#163, open) — the plugin version is therefore pinned
  and Renovate must not automerge it.
- The running StatefulSet already points at `openbao:2.7.1` (chart 0.30.4,
  `updateStrategyType: OnDelete`) while the pods still run 2.6.2: the next
  restart of each pod is also a 2.6.2 → 2.7.1 upgrade. The migration runbook
  takes a raft snapshot first and restarts standbys before the leader.
- The seal is a hard dependency: if the OCI key is deleted the raft data
  is unrecoverable even from backups. Terraform marks it
  `prevent_destroy`; OCI additionally enforces a ≥ 7-day deletion delay.
- Repo rules unchanged: PR-only, no destructive ops, docs entry per change.

## Design

### Terraform (`oracle-cloud-server/terraform/openbao-unseal.tf`)

- `oci_kms_vault.openbao` — `vault_type = "DEFAULT"` (shared, free).
- `oci_kms_key.openbao_unseal` — AES/32, `protection_mode = "SOFTWARE"`,
  `prevent_destroy = true`.
- IAM: user `openbao-unseal` (no console login, no other capabilities),
  group `openbao-unseal`, membership, and one policy in the compartment:
  `Allow group openbao-unseal to use keys in compartment id <c> where
  target.key.id = '<key>'` (covers encrypt/decrypt on the crypto endpoint
  and the GetKey the wrapper does on the management endpoint).
- `oci_identity_api_key` for that user from
  `files/openbao-unseal-api-key.pub` (RSA public PEM the owner generates
  locally and commits; private half never enters Terraform state). Created
  only when the file exists (`fileexists`), so the stack applies before the
  owner has generated the key.
- Outputs: `openbao_kms_key_id`, `openbao_kms_crypto_endpoint`,
  `openbao_kms_management_endpoint`, `openbao_unseal_user_ocid`,
  `openbao_unseal_api_key_fingerprint`. These are not secrets.

### Helm (`gitops/apps/platform/openbao`)

New values block:

```yaml
ociKms:
  enabled: false            # flip to true only after the secret exists (runbook)
  disabled: false           # true = `disabled = "true"` in the seal block (migration back)
  plugin:
    version: "0.1.1"        # renovate: github-releases openbao/openbao-plugins, tag kms-oci-v<version>
    sha256: "103735c5…9059" # of openbao-plugin-kms-oci_linux_amd64_v1.tar.gz — update with the version
  secretName: openbao-oci-kms
```

Everything the pod needs is wired **unconditionally** (the subchart does
not `tpl` its HCL, and `volumes`/`volumeMounts` are plain `toYaml`), and
the seal itself is switched by `ociKms.enabled`:

- `server.extraInitContainers[0]` `kms-init`: same image as the server
  (`tpl` resolves registry/repository/tag), runs
  `files/kms-init.sh` (ConfigMap `openbao-kms-init` rendered by the wrapper
  chart) with env `OCI_KMS_ENABLED`, `OCI_KMS_DISABLED`, `PLUGIN_VERSION`,
  `PLUGIN_SHA256`, `KMS_DIR=/openbao/kms`, plus `envFrom` the bootstrap
  secret (`optional: true`) for `key_id`, `crypto_endpoint`,
  `management_endpoint`.
- `files/kms-init.sh`: when enabled, downloads the release tarball
  (`PLUGIN_URL` overridable for tests), verifies the sha256, extracts the
  binary to `$KMS_DIR/plugins/openbao-plugin-kms-oci` (0755), and writes
  `$KMS_DIR/seal.hcl`:

  ```hcl
  plugin_directory = "/openbao/kms/plugins"
  plugin "kms" "ocikms" { command = "openbao-plugin-kms-oci"  version = "v0.1.1" }
  seal "ocikms" {
    key_id = "…"  crypto_endpoint = "…"  management_endpoint = "…"
    auth_type_api_key = "true"
    # disabled = "true"   (only when OCI_KMS_DISABLED=true)
  }
  ```

  Missing key id/endpoints while enabled → exit 1 (pod stays in Init,
  which is louder and safer than a server that starts with the wrong seal).
  When disabled it writes a comment-only `seal.hcl` and exits 0 without
  network access.
- `server.extraArgs: "-config=/openbao/kms/seal.hcl"` — OpenBao merges
  config files; scalars from the last file win, which is what we want.
- `server.volumes`: `kms` (emptyDir) and `oci-config` (secret
  `openbao-oci-kms`, `optional: true`, `defaultMode: 0440`);
  `server.volumeMounts`: `/openbao/kms` and `/home/openbao/.oci` (read-only,
  nested inside the chart's `home` emptyDir — Kubernetes allows that).

Bootstrap secret `openbao-oci-kms` (namespace `openbao`, created by hand —
OpenBao is sealed when it starts, so ESO cannot provide it):

| key | value |
|---|---|
| `config` | OCI SDK config: `[DEFAULT]`, `user=`, `fingerprint=`, `tenancy=`, `region=`, `key_file=/home/openbao/.oci/key.pem` |
| `key.pem` | private half of the API key |
| `key_id`, `crypto_endpoint`, `management_endpoint` | Terraform outputs |

### Migration (runbook `docs/runbooks/openbao-seal-migration.md`)

Shamir → ocikms on the HA raft cluster, per the OpenBao seal docs: raft
snapshot; standbys first (`kubectl delete pod openbao-2`, then
`bao operator unseal -migrate <share>` ×3; same for `openbao-1`);
`bao operator step-down` on `openbao-0`; the new leader performs the
migration; delete `openbao-0` → it auto-unseals. The five Shamir shares
become the **recovery keys**. Rollback: `ociKms.disabled: true` → pods →
`unseal -migrate` with the recovery keys. The runbook also covers the
2.6.2 → 2.7.1 jump that happens at the same restart.

### Automation that assumed Shamir

- `scripts/talos/rolling-upgrade.sh` `ensure_unsealed`: a drained replica
  now auto-unseals shortly after it is rescheduled; the check waits up to
  `UNSEAL_WAIT_ATTEMPTS × UNSEAL_WAIT_SLEEP` (default 8 × 15 s) before
  concluding a replica is stuck sealed. Key-based unseal stays as a
  fallback (recovery keys cannot unseal an auto-seal, so
  `OPENBAO_UNSEAL_KEYS` becomes irrelevant after migration; the helper is
  kept for the migration window and documented as such).
- `maintenance-window.yml` already tolerates the no-keys path (notice +
  health check retries).
- Renovate: custom manager for `ociKms.plugin.version`
  (`github-releases`, `extractVersion ^kms-oci-v(?<version>.+)$`), rule:
  never automerge, label `openbao-plugin`, PR note to update the sha256
  and re-check go-kms-wrapping#163 before merging.

### Also in this PR

- `proxmox_prep_backup_nfs_export: /mnt/AppData/Backups/proxmox` — the
  TrueNAS export exists now (verified from pve1: `192.168.1.40:/mnt/AppData/
  Backups`, 192.168.1.0/24, root maps to root, `k8s/` and `proxmox/` created).

## Non-goals

- Changing the restic/VolSync target or the TrueNAS export list (the
  cluster mounts via 10.10.10.40; the owner adds 10.10.10.0/24 to the
  export's authorized networks).
- Migrating any other secret to OCI, or auto-unseal for anything but OpenBao.

## Owner steps (ordered)

1. `openssl genrsa -out openbao-unseal.pem 2048 && openssl rsa -in
   openbao-unseal.pem -pubout -out openbao-unseal.pub`; commit the `.pub`
   as `oracle-cloud-server/terraform/files/openbao-unseal-api-key.pub`.
2. Merge; CI applies Terraform; read the five outputs from the run.
3. Create the `openbao-oci-kms` secret (exact command in the runbook).
4. Flip `ociKms.enabled: true` (PR), then run the migration runbook with
   the Shamir shares at hand. Store "recovery keys = old unseal keys" in
   1Password next to them.
