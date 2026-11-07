# Handoff: Oracle billing check and the stale OpenBao ClusterRoleBindings

Written 2026-11-07 after the OpenBao auto-unseal migration (#433–#450).
Two loose ends remain that need a human with console access or a cluster
mutation. Each section is self-contained: context, how to check, what to do,
how to verify.

Secrets referenced here (restic repository password, `openbao-unseal.pem`,
the Shamir shares / root token) live in **Bitwarden**, not 1Password.

---

## 1. Oracle: confirm the account is still at $0

### Context

Everything in `oracle-cloud-server/terraform` is meant to be Always Free:
one `VM.Standard.A1.Flex` instance (4 OCPU / 24 GB), a 150 GB boot volume,
the `valheim-backups` Object Storage bucket (30-day lifecycle), the OpenBao
vault (`DEFAULT` type) with one `SOFTWARE` AES key, IAM, and a $5 budget
(`budget.tf`) that only alerts.

The uncertainty, found in the 2026-11-05 review
(`docs/2026-11-05-openbao-auto-unseal.md`, "Public-repo and cost review"):
Oracle's Always Free page, updated June 2026, states **1,500 OCPU-hours and
9,000 GB-hours per month** for A1 (≈ 2 OCPU / 12 GB running continuously),
while the price list still shows the old 3,000 / 18,000 (4 OCPU / 24 GB).
Press coverage suggested pay-as-you-go accounts kept the old allowance. If
the new figure applies to this tenancy, the VM has been billing for the
half above the allowance since June, at a rate small enough that the $5
budget may not have fired yet.

### Check (10 minutes)

Console path: **Billing & Cost Management → Cost Analysis**. Set the date
range to 2026-06-01 → today, group by *Service* then *SKU*. Anything other
than $0.00 is the answer; in particular look for:

- `Compute – Standard – A1 – OCPU Per Hour` / `Memory Per GB Hour`
- `Block Volume – Performance Units` or `Storage`
- `Object Storage – Standard Storage` / `Requests`
- anything under `Key Management` (would mean a non-DEFAULT vault or HSM key; the plan guard should make that impossible)

CLI alternative (tenancy-admin profile):

```bash
oci usage-api usage-summary request-summarized-usages \
  --tenant-id "$(oci iam tenancy get --tenancy-id "$OCI_TENANCY_OCID" --query 'data.id' --raw-output)" \
  --time-usage-started 2026-06-01T00:00:00Z --time-usage-ended "$(date -u +%Y-%m-%dT00:00:00Z)" \
  --granularity MONTHLY --query-type COST --group-by '["service","skuName"]' \
  --query 'data.items[?computedAmount > `0`].{month:timeUsageStarted,service:service,sku:skuName,amount:computedAmount}' --output table
```

Also check two things that are not costs yet:

- **Budget alert history**: Billing → Budgets → `oracle-server-budget`;
  confirm the alert e-mail (`OCI_BUDGET_ALERT_EMAIL`) is still deliverable.
- **Bucket size**: `oci os bucket get --bucket-name valheim-backups --fields approximateSize`.
  Free allowance on a paid account is 10 GB; 30 daily world archives must stay well under it.

### Decide

| Finding | Action |
|---|---|
| $0 everywhere | Record the date in this file; add the quota policy below with `standard-a1-core-count = 4`, `standard-a1-memory-count = 24`. |
| A1 compute charges | PR: `instance_ocpus = 2`, `instance_memory_gb = 12` in `oracle-cloud-server/terraform/variables.tf` (the instance resizes in place; Valheim restarts). Then the quota policy with `2` / `12`. Open a billing support request for a credit if the amount is non-trivial. |
| Object Storage charges | PR: lifecycle `time_amount` 30 → 14 in `backups.tf`. |
| Anything under KMS / Vault | Should be impossible; stop and look at `plan-guard.sh` and the Terraform state before touching anything. |

### Quota policy (do after the decision)

Quotas are the only hard cap Oracle offers (budgets alert, quotas refuse at
create time). Add to `oracle-cloud-server/terraform` as an
`oci_limits_quota` in the root compartment; statements:

```
zero kms quota virtual-private-vault-count in tenancy
set kms quota virtual-vault-count to 1 in tenancy
zero compute-core quotas in tenancy
set compute-core quota standard-a1-core-count to <2|4> in tenancy
zero compute-memory quotas in tenancy
set compute-memory quota standard-a1-memory-count to <12|24> in tenancy
set block-storage quota total-storage-gb to 200 in tenancy
set object-storage quota storage-bytes to 10000000000 in tenancy
```

Run it through `oracle.yml` (plan + plan guard) like any other change; the
guard has no rule for quotas, so read the plan summary. Also worth doing in
the same PR: `budget_amount = 1` plus an ACTUAL alert rule with an absolute
$0.01 threshold, so the very first cent e-mails.

### Verify

- `terraform plan` shows only the quota (and budget) resources.
- Console → Governance → Quota Policies lists the policy.
- Next month's Cost Analysis still reads $0.

---

## 2. Kubernetes: two stale OpenBao ClusterRoleBindings

### Context

The `openbao` ArgoCD Application has shown **OutOfSync** since the chart
moved from 0.30.2 to 0.30.x: the chart's fullname changed, so the bindings
were re-created as `openbao-openbao-server-binding` and
`openbao-openbao-agent-injector-binding`, and the old ones were left
behind because the platform ApplicationSet runs with `prune: false`
(`gitops/bootstrap/applicationsets/platform.yaml`). ArgoCD marks them
`requiresPruning`; nothing is broken, but the app is never green, which
hides real drift.

Both stale objects (created 2026-05-05) are exact duplicates of the live
ones — same `roleRef`, same subject:

| stale name | roleRef | subject | live duplicate |
|---|---|---|---|
| `openbao-server-binding` | `system:auth-delegator` | `ServiceAccount openbao/openbao` | `openbao-openbao-server-binding` |
| `openbao-agent-injector-binding` | `openbao-agent-injector-clusterrole` | `ServiceAccount openbao/openbao-agent-injector` | `openbao-openbao-agent-injector-binding` |

Deleting the stale pair removes no permission: each subject keeps the same
role through the live binding.

### Do

```bash
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
# confirm the live duplicates exist first
kubectl get clusterrolebinding openbao-openbao-server-binding openbao-openbao-agent-injector-binding
kubectl delete clusterrolebinding openbao-server-binding openbao-agent-injector-binding
```

Do **not** flip `prune: true` on the platform ApplicationSet to get the
same effect: it would also prune anything else that is live-but-not-in-git
across every platform app (PVCs created by hand, the `openbao-oci-kms`
secret is unmanaged but untracked so it is safe, but check before relying on that).

### Verify

```bash
kubectl -n argocd get applications.argoproj.io openbao \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status   # Synced / Healthy
kubectl -n openbao exec openbao-0 -c openbao -- bao status | grep Sealed      # false
kubectl get clustersecretstore openbao -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'  # True
```

The agent injector's webhook keeps working as long as the
`openbao-agent-injector` deployment can still list pods; a quick test is to
restart one injected pod (none are injected today, so the CSS check above
is the real signal).

---

## Status log

- 2026-11-07: handoff written; neither item started.
