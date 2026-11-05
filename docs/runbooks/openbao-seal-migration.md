# Runbook: migrate OpenBao from Shamir to OCI KMS auto-unseal

Design: `docs/2026-11-05-openbao-auto-unseal.md`. Do the steps in order; each
one is verifiable before the next. Budget ~30 minutes. The cluster keeps
serving secrets throughout (one standby restarts at a time, the leader last).

**Warning.** The OCI key becomes a hard dependency of the raft data: with it
deleted, no raft snapshot can be opened again. Terraform sets
`prevent_destroy`; never remove that. The five Shamir shares become the
**recovery keys** — keep them exactly where they are (1Password).

## 0. Prerequisites

1. This PR merged and the Oracle stack applied (`oracle-deploy.yml`). The
   apply log prints `openbao_kms_key_id`, `openbao_kms_crypto_endpoint` and
   `openbao_kms_management_endpoint`. The two principal values are
   `sensitive` (not printed on the public repo): the user OCID is in the
   OCI console under Identity → Domains → Default → Users → `openbao-unseal`,
   and the fingerprint is computed locally from the committed public key:
   `openssl rsa -pubin -in oracle-cloud-server/terraform/files/openbao-unseal-api-key.pub -outform DER | openssl md5 -c`
   (or `terraform output -raw openbao_unseal_api_key_fingerprint` with local credentials).
2. The API key pair exists: `openssl genrsa -out openbao-unseal.pem 2048 &&
   openssl rsa -in openbao-unseal.pem -pubout -out openbao-unseal-api-key.pub`;
   the `.pub` is committed as
   `oracle-cloud-server/terraform/files/openbao-unseal-api-key.pub` (done
   2026-11-05) and applied with the stack.
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
   ```

   Store `openbao-unseal.pem` in 1Password (OpenBao item, "OCI unseal API
   key") **before** `rm oci-config openbao-unseal.pem`; the secret must not
   be the only copy.

4. Flip `global.ociKms.enabled: true` in
   `gitops/apps/platform/openbao/values.yaml` (PR), let ArgoCD sync. The
   StatefulSet updates but **no pod restarts** (`updateStrategyType:
   OnDelete`). Check: `kubectl -n openbao get sts openbao -o
   jsonpath='{.spec.template.spec.initContainers[0].env}'` shows
   `OCI_KMS_ENABLED=true`.
5. Shamir shares (3 of 5) and the root token at hand
   (`~/secure/openbao-init.json`). `export BAO_TOKEN=...` is needed only
   for `step-down`.
6. **The 2.7.1 upgrade is done first, separately (step 1).** The pods still
   run 2.6.2 while the StatefulSet already says `openbao:2.7.1`
   (`updateStrategyType: OnDelete`), so the first restart of each pod is
   that upgrade. Doing it with `global.ociKms.enabled: false` (the state
   right after this PR merges) and plain Shamir unseals keeps "2.7 broke
   something" apart from "the seal plugin / OCI config is wrong". Read the
   2.7 release notes once; a downgrade of a raft node that ran 2.7 is not
   supported, so take the step 1 snapshot first.

## 1. Pass A — upgrade the pods to 2.7.1 (Shamir still, `enabled: false`)

```bash
kubectl -n openbao exec openbao-0 -- bao status | grep -E 'HA Mode|Seal Type|Version'   # expect active, shamir, 2.6.2
kubectl -n openbao create job --from=cronjob/openbao-snapshot pre-upgrade
kubectl -n openbao wait --for=condition=complete job/pre-upgrade --timeout=5m
```

(The snapshot lands on the TrueNAS backups export; alternatively
`bao operator raft snapshot save /tmp/pre.snap` + `kubectl cp`.)

Then, standbys first, leader last — for `P` in `openbao-2`, `openbao-1`:

```bash
restart() { kubectl -n openbao delete pod "$1"; until kubectl -n openbao get pod "$1" >/dev/null 2>&1; do sleep 2; done; kubectl -n openbao wait --for=condition=initialized "pod/$1" --timeout=5m; }
restart $P
kubectl -n openbao logs $P -c kms-init            # "OCI KMS seal disabled; wrote empty /openbao/kms/seal.hcl"
./scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json   # Shamir, as today
kubectl -n openbao exec $P -- bao status | grep -E 'Version|Sealed|HA Mode'   # 2.7.1, false, standby
```

Then `kubectl -n openbao exec openbao-0 -- env BAO_TOKEN=$BAO_TOKEN bao operator step-down`,
`restart openbao-0`, unseal it the same way, and confirm all three report
2.7.1 and a leader exists (`bao operator raft list-peers`). Only now
create the secret (prereq 3) and flip `enabled: true` (prereq 4) — the
pods do not restart on that sync.

## 1b. Snapshot before the seal migration

```bash
kubectl -n openbao create job --from=cronjob/openbao-snapshot pre-seal-migration
kubectl -n openbao wait --for=condition=complete job/pre-seal-migration --timeout=5m
```

## 2. Pass B — seal migration, standbys first: openbao-2, then openbao-1

For `P` in `openbao-2` then `openbao-1` (the `restart` helper from step 1):

```bash
restart $P
kubectl -n openbao logs $P -c kms-init          # "installed openbao-plugin-kms-oci v0.1.1; seal config at /openbao/kms/seal.hcl" (+ "cached verified tarball")
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
restart openbao-0
kubectl -n openbao wait --for=condition=ready pod/openbao-0 --timeout=5m
kubectl -n openbao exec openbao-0 -- bao status   # Sealed false WITHOUT any unseal command; Seal Type ocikms, Recovery Seal Type shamir
kubectl -n openbao exec openbao-0 -- ls /home/openbao/.oci   # config  key.pem (nested mount works)
```

## 4. Verify and record

```bash
for p in openbao-0 openbao-1 openbao-2; do kubectl -n openbao exec $p -- bao status | grep -E 'Seal Type|Sealed|Version|HA Mode'; done
restart openbao-2 && kubectl -n openbao wait --for=condition=ready pod/openbao-2 --timeout=5m   # the real test: comes back unsealed by itself, from the cached tarball (kms-init log says "using cached")
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
