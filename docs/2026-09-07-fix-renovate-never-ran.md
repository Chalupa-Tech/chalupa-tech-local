# Fix: self-hosted Renovate never ran (sealed OpenBao + missing policy)

**Date:** 2026-09-07
**PR:** _link added on open_

## Symptom

Renovate was deployed in PR #244 (merged 2026-06-22) but never opened a
single dependency-update PR. The `renovate` namespace on the cluster was
empty — no CronJob, no ConfigMaps.

## Root causes (three, stacked)

1. **OpenBao was sealed for 74 days.** The Proxmox host rebooted around
   2026-06-28; all three OpenBao raft replicas came back sealed and the
   manual unseal routine (`scripts/openbao/unseal.sh`) was never run.
   Every ExternalSecret in the cluster (15 of them — cert-manager,
   external-dns, grafana, all of media, renovate) had been in
   `SecretSyncedError` since then, which also explains the long-standing
   `Degraded` health on those ArgoCD apps.

2. **No OpenBao policy granted the renovate path.** Even after unsealing,
   `renovate-github-app` still failed with 403: the `external-secrets`
   Kubernetes auth role was bound to `cloudflare-read`, `media-read`, and
   `observability-read` only. PR #244 seeded `secret/renovate/github-app`
   into OpenBao but never added a policy for it. This PR adds
   `scripts/openbao/policies/renovate-read.hcl` (applied live via
   `apply-policy.sh` and bound to the role).

3. **GitHub Issues were disabled on the repo.** `renovate.json` extends
   `:dependencyDashboard` and gates all major updates behind
   `dependencyDashboardApproval` — both require Issues. Enabled via
   `gh api -X PATCH ... has_issues=true` (2026-09-07).

Because the initial ArgoCD sync of the renovate app failed on the
ExternalSecret hook, and syncPolicy retries had been exhausted, the app
sat `OutOfSync/Degraded` indefinitely (selfHeal does not retry a failed
sync — same behavior documented previously).

## Fix procedure (runbook if this recurs)

```bash
export KUBECONFIG=~/.kube/chalupa-cluster.yaml

# 1. Unseal OpenBao after any host reboot
./scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json

# 2. Apply + bind the policy (one-time; done 2026-09-07)
OPENBAO_TOKEN=$(jq -r '.root_token' ~/secure/openbao-init.json) \
  ./scripts/openbao/apply-policy.sh renovate-read
OPENBAO_TOKEN=... # then bind:
kubectl -n openbao exec openbao-0 -- env BAO_TOKEN="$OPENBAO_TOKEN" \
  bao write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    token_policies="cloudflare-read,media-read,observability-read,renovate-read"

# 3. Nudge the store + secrets instead of waiting the 1h refreshInterval
kubectl annotate clustersecretstore openbao force-sync=$(date +%s) --overwrite
kubectl annotate externalsecret renovate-github-app -n renovate force-sync=$(date +%s) --overwrite

# 4. Retry the failed ArgoCD sync, then kick a manual Renovate run
kubectl patch application renovate -n argocd --type merge \
  -p '{"operation":{"sync":{},"initiatedBy":{"username":"manual-retry"}}}'
kubectl create job --from=cronjob/renovate renovate-manual -n renovate
```

## Follow-ups

- Consider alerting on `externalsecret` Ready=False or OpenBao sealed
  status (vmalert rule) so a sealed vault doesn't go unnoticed for weeks
  again.
- Renovate's daily 6am run will now surface ~2.5 months of pending
  updates; platform-chart PRs land grouped on Mondays per renovate.json.
