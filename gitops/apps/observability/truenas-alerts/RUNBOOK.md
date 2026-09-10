# truenas-alerts — one-time manual setup

Everything is GitOps-managed except the TrueNAS API key. **Do §1–§2
BEFORE merging the PR** — the ExternalSecret is sync-wave 0: if it
can't resolve the OpenBao secret, ArgoCD marks the app Degraded,
exhausts its retry budget (~20 min), and will NOT retry on its own.
Recovery if merged first anyway: seed the secret, then
`kubectl -n argocd annotate application truenas-alerts
argocd.argoproj.io/refresh=hard --overwrite`.

## 1. Create the TrueNAS API key

1. Log in at `https://192.168.1.40` (admin user).
2. Click the user/settings icon (top right) → **API Keys** → **Add**.
3. Name: `json-exporter-alerts` → **Add** → copy the key NOW (it is
   shown once). Call it API_KEY.
4. Smoke-test from the Mac (self-signed cert, hence `-k`):

```bash
curl -sk -H "Authorization: Bearer $API_KEY" \
  https://192.168.1.40/api/v2.0/alert/list | jq 'length, .[0] | {level, klass, dismissed}'
```

Expected: a number (may be 0) and, if any alert exists, an object with
`level`/`klass`/`dismissed` fields. A 401 means the key is wrong; an
empty array `[]` is fine (no active alerts).

## 2. Seed OpenBao

OpenBao seals on every reboot — check status first and unseal if
needed (`./scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json`).

```bash
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
OPENBAO_TOKEN=$(jq -r '.root_token' ~/secure/openbao-init.json)
export OPENBAO_TOKEN

# Grant external-secrets read on secret/data/truenas-alerts/* (the
# policy .hcl in this PR is the source of truth; no role rebind needed):
./scripts/openbao/apply-policy.sh observability-read

# Write the key. kv-put REPLACES the whole record — this path holds a
# single key, so that's fine:
./scripts/openbao/kv-put.sh truenas-alerts/api-key key="$API_KEY"
```

## 3. Verify after the PR merges

```bash
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
kubectl -n truenas-alerts get externalsecret truenas-alerts-api-key   # READY True
kubectl -n truenas-alerts get pods                                    # 1/1 Running
kubectl -n argocd get app truenas-alerts \
  -o jsonpath='{.status.sync.status} {.status.health.status}'         # Synced Healthy
# (also check .status.operationState for admission-webhook denials if not Synced)

# Probe end-to-end through the exporter:
kubectl -n truenas-alerts port-forward svc/truenas-alerts 7979:7979 &
curl -s 'localhost:7979/probe?module=truenas&target=https://192.168.1.40/api/v2.0/alert/list'
# Expect: HTTP 200 with `truenas_alert_active{...} 1` lines (or no
# truenas_alert lines at all when TrueNAS has zero active alerts —
# that plus 200 still proves auth + parse work).
kill %1
```

In VictoriaMetrics (Grafana → Explore, or the vmalert UI):
`up{job="truenas-alerts"} == 1` within one scrape interval.

## 4. End-to-end alert test

Cheapest real test: TrueNAS raises a `ScrubStarted`/`ScrubFinished`
one-shot alert on the next scheduled scrub, and any pool/SMART issue
appears immediately. To force one instead of waiting: in the TrueNAS
UI, **Storage → Scrub** the boot-pool (harmless, quick) and watch for
`truenas_alert_active{klass=~"Scrub.*"}` followed by a Discord message
from the TrueNASAlert rule. Dismissing the alert in the TrueNAS UI
resolves the series → `✅ resolved` message (send_resolved is on).

Optional hardening while you're in the UI: **Storage → Disks → Edit**
each HDD and set SMART temperature thresholds (e.g. Critical 50) —
overheating then surfaces through this same pipeline as a SMART alert
(there is no disk-temperature *metric* in VictoriaMetrics; see
docs/2026-09-09-add-truenas-health.md).
