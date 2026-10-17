# Handoff: PR 3 — TrueNAS Health (cluster-monitoring, final PR)

**For:** a fresh agent with no context of the prior sessions.
**Your first move:** read the approved design spec
`docs/superpowers/specs/2026-09-08-cluster-monitoring-design.md` (PR 3 =
"Components §4 TrueNAS health collector" + the `truenas.yaml` rows in
"Initial rule set" + the TrueNAS lines in "Secrets"), then use
`superpowers:writing-plans` to produce
`docs/superpowers/plans/2026-09-09-cluster-monitoring-pr3-truenas-health.md`,
then execute it with `superpowers:subagent-driven-development` in a fresh
worktree branched from **origin/main**. Suggested branch:
`feat/truenas-health`.

## State of the world (verified live, 2026-09-09)

- **PR 1 (#300 + #301) and PR 2 (#303 + #304) are merged and verified
  end-to-end.** The alerting pipeline works: vmalert + VMAlertmanager
  (`chalupa` CRs, vm-system ns) → HA webhook → pyscript app
  `vmalert_discord` → Discord `#grafana-alerts`. Firing AND resolved
  messages confirmed with real alerts.
- Rule files live in `gitops/apps/observability/vmalert/templates/rules/`
  (plex, arrs, meta, proxmox-host). The `VMAlert` CR uses
  `selectAllByDefault: true` — a new VMRule in vm-system needs no
  selector labels. **PR 3's `truenas.yaml` goes in this same directory.**
- Existing TrueNAS metrics (job `truenas`, via the separate
  `truenas-exporter` app's netdata→graphite path): `disk_temperature`,
  `cpu_temperature` etc. already in VictoriaMetrics. PR 3 adds *health/
  SMART* data, which only TrueNAS itself can see (HBA passed through).
- The `meta.yaml` TargetDown rule (`up == 0`, 10m, warning)
  automatically covers any new scrape job.
- OpenBao is seeded/unsealed; `observability-read` policy (file:
  `scripts/openbao/policies/observability-read.hcl`, source of truth)
  currently grants `secret/data/grafana/*` + `secret/data/vmalert/*` and
  is bound to the `external-secrets` auth role — extending the .hcl +
  `./scripts/openbao/apply-policy.sh observability-read` is all a new
  path needs (no role rebind).

## What PR 3 builds (from the spec — read it for full detail)

1. **`gitops/apps/observability/truenas-alerts`** — new app dir:
   prometheus-community **json_exporter** polling
   `https://192.168.1.40/api/v2.0/alert/list`, exposing
   `truenas_alert_active{level, klass}` (one series per active TrueNAS
   alert). Auth: TrueNAS API key as bearer token, OpenBao →
   ExternalSecret → Secret. Plus a VMServiceScrape so vmagent picks it
   up, and a `RUNBOOK.md` documenting the manual steps (mirror
   `gitops/apps/observability/vmalert/RUNBOOK.md`'s style).
2. **`templates/rules/truenas.yaml`** in the **vmalert** app:
   - TrueNASAlert — `truenas_alert_active > 0`; TrueNAS level CRITICAL →
     severity critical, everything else → warning (two `- alert:` blocks
     with level matchers is the clean way).
   - TrueNASDiskTempHigh — `disk_temperature > 45` for 15m, warning
     (metric already exists, job `truenas`).
   - TrueNASMetricsStale — no fresh netdata samples 5m, e.g.
     `(time() - max(timestamp(cpu_temperature{job="truenas"}))) > 300`,
     warning.
   - **Add an absent-guard for the new job** (e.g.
     `absent(up{job="truenas-alerts"})`) — not in the spec's table, but
     the pattern (PlexExporterAbsent, ProxmoxMetricsAbsent) caught a
     real broken-scrape on day one of PR 2. Precedent is established.
3. **Secrets/policy:** OpenBao path `secret/truenas-alerts/api-key`
   (or similar) + one line in `observability-read.hcl`; ExternalSecret
   references ClusterSecretStore `name: openbao, kind: ClusterSecretStore`,
   apiVersion `external-secrets.io/v1` (pattern:
   `gitops/apps/observability/grafana/templates/grafana-admin-externalsecret.yaml`).
4. **Docs entry** `docs/2026-09-0X-add-truenas-health.md` with rationale
   + PR link (repo rule; `#TBD` until PR exists, fill before merge).

## Manual steps (need the user, or live systems — plan them like PR 1's runbook)

- Create the TrueNAS API key in the TrueNAS UI (user does this, or
  guide them) — TrueNAS at `https://192.168.1.40` (mgmt) — and seed
  OpenBao. **Seed BEFORE merging** (see landmine #4).
- OpenBao seeding pattern (single-key path):
  `OPENBAO_TOKEN=$(jq -r '.root_token' ~/secure/openbao-init.json) KUBECONFIG=~/.kube/chalupa-cluster.yaml ./scripts/openbao/kv-put.sh truenas-alerts/api-key key=<VALUE>`
  — `kv put` REPLACES the whole record; pass all keys in one call.
  Check `bao status` first: **OpenBao seals on every reboot**
  (`./scripts/openbao/unseal.sh --keys-file ~/secure/openbao-init.json`).

## Landmines this project already stepped on — don't repeat them

1. **Image tags:** standing feedback — do NOT infer the json_exporter
   image tag from release names. Probe the registry manifest endpoint
   (e.g. quay.io/prometheuscommunity/json-exporter tags API) before
   pinning in values.yaml.
2. **Schemaless vm-operator CRDs:** helm/yamllint/kubeconform pass on
   field-name typos; the operator's **admission webhook** rejects them at
   apply time and **one rejected resource blocks that entire ArgoCD app's
   sync**. Endpoint-level scrape interval field is `interval`, NOT
   `scrapeInterval` (broke PR 2, fixed in #304). After merge, check
   `kubectl -n argocd get app <name> -o jsonpath='{.status.operationState}'`
   for webhook denials. New kinds used in templates must be added to
   `SKIP_KINDS` in `.github/workflows/gitops.yml` (~line 91) —
   `VMServiceScrape` is already in it.
3. **Helm-escape Prometheus templating** in VMRule annotations:
   `{{ "{{ $labels.klass }}" }}` → literal `{{ $labels.klass }}`. Bare
   `{{ $labels... }}` breaks the required render check. Verify by
   grepping `helm template` output for the literal.
4. **ArgoCD + missing secrets:** an ExternalSecret that can't resolve
   its OpenBao path makes the app Degraded; the sync retry budget
   (limit 5, ~20 min) exhausts and does NOT restart itself. Seed OpenBao
   before merging; recovery if merged first:
   `kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite`.
   Note ArgoCD polls the repo itself but has sometimes lagged — a
   `refresh=normal` annotate nudges it.
5. **Sync waves:** don't wave-order a config CR before the CR that
   consumes it — ArgoCD health-gates each wave and the operator only
   sets status on consumed configs (deadlocked PR 1's first sync, fixed
   in #301). For a fresh app dir the safest shape is: namespace wave -1
   (if any), ExternalSecret 0, workload 10, VMServiceScrape 30.
6. **ApplicationSet namespaces:** the observability ApplicationSet
   deploys each dir with destination namespace = dir basename +
   `CreateNamespace=true`. `truenas-exporter` sets its own
   `templates/namespace.yaml` with baseline PSA labels — follow that
   pattern for `truenas-alerts` (json_exporter needs no privileges).
   The VMRule file, however, goes in the **vmalert** app (vm-system).
7. **TrueNAS API over HTTPS:** 192.168.1.40 serves a self-signed cert —
   json_exporter's HTTP client config needs `tls_config.insecure_skip_verify: true`
   (verify the exact json_exporter config schema for the pinned version).
8. **TrueNAS NFS/exports memory notes are irrelevant here** — this is
   read-only REST polling; no storage mounts.

## Repo conventions (enforced by CI and by review in PRs 1–2)

- All changes via PR; never push to main; no local `kubectl apply` for
  GitOps state (the one sanctioned pattern: ephemeral e2e test objects,
  applied and deleted by hand, never committed). TrueNAS VM itself is
  protected — PR 3 touches only k8s + rules, NOT `pulumi/`.
- Chart style: local wrapper charts; `truenas-exporter/Chart.yaml` shows
  the bjw-s `app-template` dependency pattern for small deployments —
  follow it for json_exporter. yamllint (relaxed, `.yamllint.yml`) runs
  on raw templates: keep Helm directives inside quoted YAML scalars.
- Commits: conventional style ending with
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. PR bodies end
  with the Claude Code attribution line. Squash-merge; fill the docs
  entry's PR number before merge (check PR still open first).
- Verification loop: `helm template <name> <dir>`, `yamllint gitops/`,
  full checks green before PR. Post-merge: query VictoriaMetrics
  (Grafana MCP datasource uid `P4169E866C3094E38`) for
  `up{job="<new-job>"} == 1` and `truenas_alert_active` presence; e2e =
  fire a harmless TrueNAS test alert (TrueNAS UI has "send test alert")
  or confirm zero-value scrape success, per the spec's Testing section.
- Track progress in `.superpowers/sdd/progress.md` in your worktree.
  History of PRs 1–2 (for reference): the old worktree's ledger at
  `.claude/worktrees/alerting-core/.superpowers/sdd/progress.md`.

## Access cheat-sheet

- kubectl: `--kubeconfig ~/.kube/chalupa-cluster.yaml` (works without sudo).
- Grafana MCP tools are connected (Prometheus queries against
  VictoriaMetrics).
- OpenBao scripts: `scripts/openbao/{unseal.sh,kv-put.sh,apply-policy.sh}`;
  token/keys at `~/secure/openbao-init.json`.
- TrueNAS UI: `https://192.168.1.40` (user handles UI steps).
- Discord alerts channel exists (`#grafana-alerts`); delivery needs no
  changes for PR 3.
- Note if debugging HA-side (shouldn't be needed): HA's log APIs are
  gone — see memory `ha-log-apis-removed`; state-entity debugging works.

## Out of scope (deliberate, per spec)

- smartctl_exporter raw SMART attributes; pve-exporter; new dashboards.
- Dead-man's-switch for the pipeline itself — noted as a future monitor;
  mention it in the docs entry's follow-ups, don't build it.
