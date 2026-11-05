# Runbook: migrate OpenBao from Shamir to OCI KMS auto-unseal

Design: `docs/2026-11-05-openbao-auto-unseal.md`. Do the steps in order; each
one is verifiable before the next. Budget ~30 minutes. The cluster keeps
serving secrets throughout (one standby restarts at a time, the leader last).

**Warning.** The OCI key becomes a hard dependency of the raft data: with it
deleted, no raft snapshot can be opened again. Terraform sets
`prevent_destroy`; never remove that. The five Shamir shares become the
**recovery keys** — keep them exactly where they are (1Password).

## 0. Prerequisites

1. This PR merged and the Oracle stack applied (`oracle-deploy.yml`). Collect
   the outputs from the apply log or `terraform output` locally:
   `openbao_kms_key_id`, `openbao_kms_crypto_endpoint`,
   `openbao_kms_management_endpoint`, `openbao_unseal_user_ocid`,
   `openbao_unseal_api_key_fingerprint` (non-empty only after step 2).
2. The API key pair exists: `openssl genrsa -out openbao-unseal.pem 2048 &&
   openssl rsa -in openbao-unseal.pem -pubout -out openbao-unseal-api-key.pub`;
   the `.pub` is committed as
   `oracle-cloud-server/terraform/files/openbao-unseal-api-key.pub` and
   applied (the fingerprint output is then set).
3. Bootstrap secret (hand-made; ESO cannot provide it because OpenBao is
   sealed when it is needed):

   ```bash
   cat > oci-config <<EOC
   [DEFAULT]
   user=<openbao_unseal_user_ocid>
   fingerprint=<openbao_unseal_api_key_fingerprint>
   tenancy=<OCI_TENANCY_OCID>
   region=<OCI_REGION, e.g. us-ashburn-1>
   key_file=/home/openbao/.oci/key.pem
   EOC
   kubectl -n openbao create secret generic openbao-oci-kms \
     --from-file=config=oci-config \
     --from-file=key.pem=openbao-unseal.pem \
     --from-literal=key_id='<openbao_kms_key_id>' \
     --from-literal=crypto_endpoint='<openbao_kms_crypto_endpoint>' \
     --from-literal=management_endpoint='<openbao_kms_management_endpoint>'
   rm oci-config openbao-unseal.pem   # the PEM now lives only in the secret + 1Password
   ```

4. Flip `global.ociKms.enabled: true` in
   `gitops/apps/platform/openbao/values.yaml` (PR), let ArgoCD sync. The
   StatefulSet updates but **no pod restarts** (`updateStrategyType:
   OnDelete`). Check: `kubectl -n openbao get sts openbao -o
   jsonpath='{.spec.template.spec.initContainers[0].env}'` shows
   `OCI_KMS_ENABLED=true`.
5. Shamir shares (3 of 5) and the root token at hand
   (`~/secure/openbao-init.json`). `export BAO_TOKEN=...` is needed only
   for `step-down`.
6. Note: the pods still run 2.6.2 while the StatefulSet already says
   `openbao:2.7.1`; every restart below is also that upgrade. Read the
   2.7 release notes first (built-in seals removed → plugin, which is what
   this runbook installs).

## 1. Snapshot

```bash
kubectl -n openbao exec openbao-0 -- bao status | grep -E 'HA Mode|Seal Type'   # expect active, shamir
kubectl -n openbao create job --from=cronjob/openbao-snapshot pre-seal-migration
kubectl -n openbao wait --for=condition=complete job/pre-seal-migration --timeout=5m
```

(The snapshot lands on the TrueNAS backups export; alternatively
`bao operator raft snapshot save /tmp/pre.snap` + `kubectl cp`.)

## 2. Standbys first: openbao-2, then openbao-1

For `P` in `openbao-2` (sealed since September — nothing to lose) then
`openbao-1`:

```bash
kubectl -n openbao delete pod $P
kubectl -n openbao wait --for=condition=initialized pod/$P --timeout=5m
kubectl -n openbao logs $P -c kms-init          # "installed openbao-plugin-kms-oci v0.1.1; seal config at /openbao/kms/seal.hcl"
kubectl -n openbao logs $P | grep -iE 'seal|plugin|error' | head
kubectl -n openbao exec $P -- bao status        # Sealed true, Seal Type shamir (migration pending)
kubectl -n openbao exec $P -- bao operator unseal -migrate '<share 1>'
kubectl -n openbao exec $P -- bao operator unseal -migrate '<share 2>'
kubectl -n openbao exec $P -- bao operator unseal -migrate '<share 3>'
kubectl -n openbao exec $P -- bao status        # Sealed false, HA Mode standby
```

If `kms-init` fails (sha mismatch, download, missing secret key) the pod
stays in `Init:Error`/`Init:CrashLoopBackOff` and **nothing has changed**
for the other replicas: fix the cause (secret keys, network) and delete the
pod again. If the server logs `failed key_id validation` or an OCI 401/404,
the IAM policy, fingerprint or endpoints are wrong — fix the secret, delete
the pod again; the raft data is untouched.

Wait until `bao operator raft list-peers` (on openbao-0, with the token)
shows the replica back before doing the next one.

## 3. Hand over leadership, migrate, restart the old leader

```bash
kubectl -n openbao exec openbao-0 -- env BAO_TOKEN=$BAO_TOKEN bao operator step-down
sleep 10; for p in openbao-1 openbao-2; do kubectl -n openbao exec $p -- bao status | grep -E 'HA Mode|Seal Type|Sealed'; done
# the new active node performs the migration; look for it in its log:
kubectl -n openbao logs <new active> | grep -i 'seal migration'
kubectl -n openbao delete pod openbao-0
kubectl -n openbao wait --for=condition=ready pod/openbao-0 --timeout=5m
kubectl -n openbao exec openbao-0 -- bao status   # Sealed false WITHOUT any unseal command; Seal Type ocikms, Recovery Seal Type shamir
```

## 4. Verify and record

```bash
for p in openbao-0 openbao-1 openbao-2; do kubectl -n openbao exec $p -- bao status | grep -E 'Seal Type|Sealed|Version|HA Mode'; done
kubectl -n openbao delete pod openbao-2 && kubectl -n openbao wait --for=condition=ready pod/openbao-2 --timeout=5m   # the real test: comes back unsealed by itself
kubectl get clustersecretstore openbao   # Ready
```

- 1Password note on the OpenBao item: "Seal: OCI KMS (key `openbao-unseal`,
  tenancy …). The 5 Shamir shares are now RECOVERY keys: they cannot unseal
  on their own; they authorise `generate-root`, rekey and a migration back."
- `OPENBAO_UNSEAL_KEYS` (GitHub secret) is no longer needed; delete it if it
  was created. `scripts/openbao/unseal.sh` only applies to a migration back.
- Disaster recovery now needs **both** the raft snapshot and the OCI key
  (plus the API key secret). A rebuilt cluster restores the snapshot with
  the same `seal "ocikms"` config and the recovery keys.

## Rollback (auto-unseal → Shamir)

1. PR: `global.ociKms.disabled: true` (keeps `enabled: true`); ArgoCD syncs.
2. Standbys one at a time: delete pod → `bao operator unseal -migrate
   '<recovery key>'` ×3 → the recovery keys become Shamir unseal keys again.
3. `step-down` on the active, wait for the migration, delete the old active
   and unseal it with the keys.
4. PR: `enabled: false`, `disabled: false`; delete the secret; re-enable the
   `OPENBAO_UNSEAL_KEYS` path if CI unsealing is still wanted.
