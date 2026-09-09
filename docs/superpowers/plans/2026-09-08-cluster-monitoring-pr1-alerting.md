# Cluster Monitoring PR 1 — Alerting Core + Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy vmalert + Alertmanager via VictoriaMetrics-operator CRs, a Pyscript webhook→Discord bridge in Home Assistant, and the first alert rules (Plex, *arrs, TargetDown safety net) — PR 1 of the approved design in `docs/superpowers/specs/2026-09-08-cluster-monitoring-design.md`.

**Architecture:** A new templates-only GitOps app `gitops/apps/observability/vmalert` deploys `VMAlert`, `VMAlertmanager`, `VMAlertmanagerConfig`, an `ExternalSecret` (HA webhook URL from OpenBao), and per-concern `VMRule` files into the existing `vm-system` namespace. Alertmanager POSTs to an HA webhook; a Pyscript **app** (`vmalert_discord`) formats alerts and sends them to a dedicated Discord channel via `notify.homeassistant_tejon_frame`. PRs 2 (Proxmox host) and 3 (TrueNAS health) get their own plans later.

**Tech Stack:** Helm (templates-only chart), victoria-metrics-operator v0.69.0 CRs, External Secrets Operator + OpenBao, Pyscript (HAOS), pytest.

## Global Constraints

- **All changes via PRs** — never push to `main`; CI applies changes. No local `kubectl apply` to change GitOps-managed state. (Sole sanctioned exception: the ephemeral `AlwaysFiring` e2e VMRule in Task 7, applied and deleted by hand per the spec's Testing section — it is never committed.)
- **TrueNAS VM untouched** — this PR touches nothing under `pulumi/`.
- Every vmalert-app resource carries explicit `namespace: vm-system` — the observability ApplicationSet's destination namespace is the dir basename (`vmalert`), which would be wrong. Do NOT add a `templates/namespace.yaml` (the `vm-system` app already owns that Namespace). Side effect: ArgoCD's `CreateNamespace=true` creates an empty `vmalert` namespace; accepted, noted in the docs entry.
- **Helm-escape all Prometheus template syntax** in VMRule annotations: `{{ "{{ $labels.x }}" }}` — bare `{{ $labels.x }}` is a Helm parse error that breaks the required "Lint and dry-render gitops/" check.
- **Prometheus label facts (verified live 2026-09-08):** `plex_up` exists from BOTH `job="plex-exporter"` and `job="tautulli-exporter"` — Plex rules MUST filter `{job="plex-exporter"}`. `scraparr_services_up` carries the per-service name in the `alias` label (e.g. `alias="sonarr"`).
- **vm-operator CRDs are schemaless** (`x-kubernetes-preserve-unknown-fields: true`, verified against the live cluster) — field-name typos surface only at operator runtime. `VMAlertmanagerConfig` uses Alertmanager-style snake_case (`group_by`, `webhook_configs`, `url_secret`, `send_resolved`); `VMAlert`/`VMAlertmanager` use camelCase (`replicaCount`, `selectAllByDefault`, `disableNamespaceMatcher`). Task 7 verifies via CR `.status` after deploy.
- **Pyscript runtime quirks** (all `.py` under `homeassistant/pyscript/` runs in the Pyscript interpreter): no generator expressions, no `@property`, no lambdas closing over enclosing-function params, `service.call(...)` for dynamic service names. List comprehensions and f-strings are fine. Plain `pytest` won't catch violations — follow the rules by construction.
- **Secrets out of Git** (the repo is public): the HA webhook ID and Discord channel ID live only in HAOS `secrets.yaml` (read via `pyscript.app_config`) and OpenBao (read via ExternalSecret). *Documented deviation from the spec:* the spec sketched `@webhook_trigger("<webhook-id>")` with a hardcoded ID, which would put the shared secret in the public repo and nullify the spec's own "webhook ID never lands in Git" requirement. Resolution: Pyscript **app** + `!secret` config. The Discord channel ID rides the same mechanism instead of being hardcoded (spec said hardcode; channel IDs aren't secret, but one mechanism beats two and keeps the committed file placeholder-free).
- **OpenBao:** seed new paths with `scripts/openbao/kv-put.sh` passing ALL keys in one call (KV v2 put replaces the whole record). The `observability-read` policy is already bound to the `external-secrets` auth role — extending the policy body is enough, no role rebind.
- Commit messages follow conventional-commit style (`feat(gitops): …`, `feat(ha): …`, `docs: …`) and end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Cluster/Repo facts the implementer needs

| Fact | Value |
|---|---|
| vmsingle URL (from vmagent's remoteWrite) | `http://vmsingle-vmsingle-chalupa.vm-system.svc.cluster.local:8429` |
| Alertmanager service (operator naming: `vmalertmanager-<cr-name>`) | `http://vmalertmanager-chalupa.vm-system.svc.cluster.local:9093` |
| ClusterSecretStore | `name: openbao, kind: ClusterSecretStore` (pattern: `gitops/apps/observability/grafana/templates/grafana-admin-externalsecret.yaml`) |
| ExternalSecret apiVersion | `external-secrets.io/v1` |
| OpenBao KV path for the webhook URL | `secret/vmalert/ha-webhook`, property `url` |
| HA webhook endpoint shape | `http://192.168.1.234:8123/api/webhook/<webhook-id>` |
| Discord notify service | `notify.homeassistant_tejon_frame`, `target: [<channel-id>]` |
| CI render loop | `.github/workflows/gitops.yml` runs `helm dependency update` + `helm template` + kubeconform on every `gitops/apps/*/*/` dir with a Chart.yaml (`helm dependency update` on a dependency-less chart exits 0 — verified) |
| yamllint config | `.yamllint.yml`: relaxed profile, line-length disabled |
| pytest | run from `homeassistant/` (`tests/conftest.py` already puts `pyscript/modules/` on `sys.path`) |

---

### Task 1: vmalert chart — core CRs

**Files:**
- Create: `gitops/apps/observability/vmalert/Chart.yaml`
- Create: `gitops/apps/observability/vmalert/values.yaml`
- Create: `gitops/apps/observability/vmalert/templates/externalsecret.yaml`
- Create: `gitops/apps/observability/vmalert/templates/vmalertmanager.yaml`
- Create: `gitops/apps/observability/vmalert/templates/vmalertmanagerconfig.yaml`
- Create: `gitops/apps/observability/vmalert/templates/vmalert.yaml`

**Interfaces:**
- Consumes: existing `VMSingle` service URL, `openbao` ClusterSecretStore, `vm-system` namespace (all pre-existing).
- Produces: Secret `vmalert-ha-webhook` (key `url`) in `vm-system`; Alertmanager at `vmalertmanager-chalupa.vm-system.svc.cluster.local:9093`; a `VMAlert` named `chalupa` that selects **all** VMRules (Task 2 relies on `selectAllByDefault: true`); receiver name `discord`.

- [ ] **Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: vmalert-wrapper
description: |
  Alerting core: vmalert (rule evaluation) + Alertmanager (routing) as
  VictoriaMetrics-operator CRs, plus the VMRule alert definitions under
  templates/rules/.

  Everything deploys into the existing vm-system namespace (explicit
  metadata.namespace on every resource — the ApplicationSet's default
  destination would be a new `vmalert` namespace, which we don't want).
  The operator + CRDs come from the vm-system app; this chart has no
  Helm dependencies.

  Delivery path: vmalert -> Alertmanager -> HA webhook (URL from OpenBao
  via ExternalSecret; the webhook ID is the shared secret and never
  lands in Git) -> pyscript app vmalert_discord -> Discord alerts
  channel. See RUNBOOK.md for the one-time manual steps.

  Adding a future monitor = adding one file (or one more `- alert:`
  block) under templates/rules/ and merging a PR.
type: application
version: 0.1.0
appVersion: "v0.69.0"
```

- [ ] **Step 2: Create values.yaml**

```yaml
# Templates-only chart — resources are defined directly in templates/
# (same style as the vm-system CRs). Nothing is parameterized yet.
{}
```

- [ ] **Step 3: Create templates/externalsecret.yaml**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: vmalert-ha-webhook
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: vmalert-ha-webhook
    creationPolicy: Owner
  data:
    - secretKey: url
      remoteRef:
        key: secret/vmalert/ha-webhook
        property: url
```

- [ ] **Step 4: Create templates/vmalertmanager.yaml**

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMAlertmanager
metadata:
  name: chalupa
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "10"
spec:
  replicaCount: 1
  # Pick up every VMAlertmanagerConfig in the cluster (there is exactly
  # one, in this namespace).
  selectAllByDefault: true
  # CRITICAL: without this, the operator adds a `namespace="vm-system"`
  # matcher to the route generated from our VMAlertmanagerConfig, and
  # alerts on metrics from other namespaces (plex_up is in `media`)
  # would never reach the Discord receiver.
  disableNamespaceMatcher: true
  # No persistent storage: silences and notification-log state are
  # lost on pod restart. Accepted for homelab (worst case: one
  # duplicate notification after a restart).
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 128Mi
```

- [ ] **Step 5: Create templates/vmalertmanagerconfig.yaml**

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMAlertmanagerConfig
metadata:
  name: discord
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  # Field names here are Alertmanager-config snake_case — that is what
  # the VMAlertmanagerConfig CRD uses (unlike the camelCase VM CRs).
  route:
    receiver: discord
    group_by: [alertname]
    group_wait: 30s
    group_interval: 5m
    # A stuck alert re-pings ~2x/day instead of spamming.
    repeat_interval: 12h
  receivers:
    - name: discord
      webhook_configs:
        # url_secret keeps the webhook ID (the shared secret) out of
        # Git — the Secret is synced from OpenBao by the
        # ExternalSecret in this chart.
        - url_secret:
            name: vmalert-ha-webhook
            key: url
          send_resolved: true
```

- [ ] **Step 6: Create templates/vmalert.yaml**

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMAlert
metadata:
  name: chalupa
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "20"
spec:
  replicaCount: 1
  evaluationInterval: 30s
  # Evaluate every VMRule in the cluster (rules live in this
  # namespace; new rule files under templates/rules/ are picked up
  # with no further wiring).
  selectAllByDefault: true
  datasource:
    url: http://vmsingle-vmsingle-chalupa.vm-system.svc.cluster.local:8429
  # remoteWrite persists ALERTS/ALERTS_FOR_STATE series; remoteRead
  # restores `for:` timers across vmalert restarts.
  remoteWrite:
    url: http://vmsingle-vmsingle-chalupa.vm-system.svc.cluster.local:8429
  remoteRead:
    url: http://vmsingle-vmsingle-chalupa.vm-system.svc.cluster.local:8429
  notifiers:
    - url: http://vmalertmanager-chalupa.vm-system.svc.cluster.local:9093
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 256Mi
```

- [ ] **Step 7: Render + lint**

```bash
cd /Users/tbigelow/Documents/code/chalupa-tech-local
helm dependency update gitops/apps/observability/vmalert
helm template vmalert gitops/apps/observability/vmalert
yamllint gitops/apps/observability/vmalert || pip install yamllint==1.35.1 && yamllint gitops/apps/observability/vmalert
```

Expected: `helm template` prints all 4 resources, each with `namespace: vm-system`; yamllint exits 0 (warnings from the relaxed profile are OK, errors are not).

- [ ] **Step 8: Commit**

```bash
git add gitops/apps/observability/vmalert
git commit -m "feat(gitops): add vmalert + alertmanager alerting core"
```

---

### Task 2: VMRule files + CI skip-kinds fix

**Files:**
- Create: `gitops/apps/observability/vmalert/templates/rules/plex.yaml`
- Create: `gitops/apps/observability/vmalert/templates/rules/arrs.yaml`
- Create: `gitops/apps/observability/vmalert/templates/rules/meta.yaml`
- Modify: `.github/workflows/gitops.yml` (the `SKIP_KINDS` line, currently line 91)

**Interfaces:**
- Consumes: `VMAlert` with `selectAllByDefault: true` (Task 1) — rules need no selector labels.
- Produces: alert names `PlexDown`, `PlexExporterAbsent`, `ArrServiceDown`, `ScraparrAbsent`, `TargetDown`, each with `severity` label and `summary`/`description` annotations (this text is what lands in Discord via Task 3's formatter).

- [ ] **Step 1: Create templates/rules/plex.yaml**

Note the `{job="plex-exporter"}` filter — `plex_up` is ALSO exported by tautulli-exporter (verified live); without the filter, `absent()` would never fire and Down would double-fire.

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: plex
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  groups:
    - name: plex
      rules:
        - alert: PlexDown
          expr: 'plex_up{job="plex-exporter"} == 0'
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: Plex is down
            description: plex-exporter has reported Plex unreachable for 5+ minutes.
        - alert: PlexExporterAbsent
          expr: 'absent(plex_up{job="plex-exporter"})'
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: plex-exporter metrics are missing
            description: No plex_up series from job plex-exporter for 10+ minutes — the exporter itself is down or unscraped, so Plex is unmonitored.
```

- [ ] **Step 2: Create templates/rules/arrs.yaml**

`{{ "{{ $labels.alias }}" }}` is Helm-escaping: it renders to the literal `{{ $labels.alias }}` that vmalert templates at fire time. The per-service name lives in the `alias` label (verified live: `alias="sonarr"` etc.).

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: arrs
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  groups:
    - name: arrs
      rules:
        - alert: ArrServiceDown
          expr: 'scraparr_services_up == 0'
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: '{{ "{{ $labels.alias }}" }} is down'
            description: 'scraparr reports {{ "{{ $labels.alias }}" }} unreachable for 5+ minutes.'
        - alert: ScraparrAbsent
          expr: 'absent(scraparr_services_up)'
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: scraparr metrics are missing
            description: No scraparr_services_up series for 10+ minutes — the *arr stack is unmonitored.
```

- [ ] **Step 3: Create templates/rules/meta.yaml**

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: meta
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  groups:
    - name: meta
      rules:
        # Safety net: catches ANY current or future scrape target dying
        # without needing a dedicated rule.
        - alert: TargetDown
          expr: 'up == 0'
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: 'Scrape target {{ "{{ $labels.job }}" }} is down'
            description: 'Target {{ "{{ $labels.instance }}" }} of job {{ "{{ $labels.job }}" }} has been unreachable for 10+ minutes.'
```

- [ ] **Step 4: Add VMAlertmanagerConfig to kubeconform skip list**

In `.github/workflows/gitops.yml`, the existing skip line:

```
SKIP_KINDS='VMSingle,VMAgent,VMServiceScrape,VMPodScrape,VMNodeScrape,VMRule,VMUser,VMAlertmanager,VMAlert,VMCluster,VMAuth'
```

becomes (same rationale as the surrounding comment — the datreeio catalog's vm-operator schemas are stale; the operator validates at runtime):

```
SKIP_KINDS='VMSingle,VMAgent,VMServiceScrape,VMPodScrape,VMNodeScrape,VMRule,VMUser,VMAlertmanager,VMAlertmanagerConfig,VMAlert,VMCluster,VMAuth'
```

- [ ] **Step 5: Render and verify escaping**

```bash
cd /Users/tbigelow/Documents/code/chalupa-tech-local
helm template vmalert gitops/apps/observability/vmalert | grep -c 'kind: VMRule'
helm template vmalert gitops/apps/observability/vmalert | grep '{{ \$labels'
```

Expected: `3` VMRules; the grep prints lines containing the LITERAL `{{ $labels.alias }}` / `{{ $labels.job }}` / `{{ $labels.instance }}` (proving Helm passed them through). If `helm template` errors with `function "$labels" not defined`, an escape was missed.

- [ ] **Step 6: yamllint the workflow + chart**

```bash
yamllint .github/workflows/gitops.yml gitops/apps/observability/vmalert
```

Expected: exit 0.

- [ ] **Step 7: Commit**

```bash
git add gitops/apps/observability/vmalert/templates/rules .github/workflows/gitops.yml
git commit -m "feat(gitops): add plex, arrs and target-down alert rules"
```

---

### Task 3: Discord formatter module (TDD)

**Files:**
- Create: `homeassistant/tests/test_vmalert_format.py`
- Create: `homeassistant/pyscript/modules/vmalert_format.py`

**Interfaces:**
- Consumes: nothing (pure function over an Alertmanager webhook-payload dict: `{"alerts": [{"status", "labels", "annotations"}, …]}`).
- Produces: `format_alerts(payload) -> list[str]` — one Discord-ready message string per alert, each ≤ 1900 chars. Task 4 imports exactly `from vmalert_format import format_alerts`.

- [ ] **Step 1: Write the failing tests**

`homeassistant/tests/test_vmalert_format.py`:

```python
"""Tests for the Alertmanager -> Discord message formatter.

vmalert_format is a pure module (no pyscript/HA imports) so plain pytest
covers it; conftest.py puts pyscript/modules/ on sys.path.
"""
from vmalert_format import format_alerts


def _alert(status="firing", labels=None, annotations=None):
    return {
        "status": status,
        "labels": labels or {},
        "annotations": annotations or {},
    }


def test_firing_critical_has_fire_siren_name_and_text():
    payload = {"alerts": [_alert(
        labels={"alertname": "PlexDown", "severity": "critical"},
        annotations={"summary": "Plex is down",
                     "description": "unreachable for 5+ minutes"},
    )]}
    msgs = format_alerts(payload)
    assert len(msgs) == 1
    assert "🔥" in msgs[0]
    assert "🚨" in msgs[0]
    assert "**PlexDown**" in msgs[0]
    assert "Plex is down" in msgs[0]
    assert "unreachable for 5+ minutes" in msgs[0]


def test_firing_warning_uses_warning_emoji():
    payload = {"alerts": [_alert(
        labels={"alertname": "TargetDown", "severity": "warning"},
        annotations={"summary": "Scrape target scraparr is down"},
    )]}
    msgs = format_alerts(payload)
    assert "⚠️" in msgs[0]
    assert "🚨" not in msgs[0]


def test_resolved_uses_checkmark_and_skips_fire():
    payload = {"alerts": [_alert(
        status="resolved",
        labels={"alertname": "PlexDown", "severity": "critical"},
        annotations={"summary": "Plex is down"},
    )]}
    msgs = format_alerts(payload)
    assert "✅" in msgs[0]
    assert "**PlexDown**" in msgs[0]
    assert "🔥" not in msgs[0]


def test_one_message_per_alert():
    payload = {"alerts": [
        _alert(labels={"alertname": "ArrServiceDown", "alias": "sonarr",
                       "severity": "critical"}),
        _alert(labels={"alertname": "ArrServiceDown", "alias": "radarr",
                       "severity": "critical"}),
    ]}
    assert len(format_alerts(payload)) == 2


def test_no_annotations_falls_back_to_labels():
    payload = {"alerts": [_alert(
        labels={"alertname": "ArrServiceDown", "alias": "sonarr",
                "severity": "critical"},
    )]}
    msgs = format_alerts(payload)
    assert "alias=sonarr" in msgs[0]


def test_long_message_truncated_under_discord_limit():
    payload = {"alerts": [_alert(
        labels={"alertname": "Big", "severity": "warning"},
        annotations={"summary": "x" * 5000},
    )]}
    msgs = format_alerts(payload)
    assert len(msgs[0]) <= 1900


def test_garbage_payloads_return_empty_list():
    assert format_alerts(None) == []
    assert format_alerts("not a dict") == []
    assert format_alerts({}) == []
    assert format_alerts({"alerts": "nope"}) == []
    assert format_alerts({"alerts": [42]}) == []
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd /Users/tbigelow/Documents/code/chalupa-tech-local/homeassistant && source .venv/bin/activate && pytest tests/test_vmalert_format.py -v
```

Expected: collection error `ModuleNotFoundError: No module named 'vmalert_format'`.

- [ ] **Step 3: Implement the module**

`homeassistant/pyscript/modules/vmalert_format.py`:

```python
"""Format Alertmanager webhook payloads into Discord message strings.

Pure logic, no pyscript/HA imports — unit-testable with plain pytest.
In production this file runs under the Pyscript interpreter, so it must
follow the Pyscript rules in homeassistant/CLAUDE.md: no generator
expressions, no @property, no lambdas closing over enclosing-function
params. List comprehensions and f-strings are fine.
"""

_MAX_LEN = 1900  # Discord caps messages at 2000 chars; leave headroom.

_SEVERITY_EMOJI = {
    "critical": "🚨",
    "warning": "⚠️",
}


def _format_one(alert):
    labels = alert.get("labels") or {}
    annotations = alert.get("annotations") or {}
    name = labels.get("alertname", "UnknownAlert")

    if alert.get("status") == "resolved":
        head = f"✅ **{name}** resolved"
    else:
        severity = labels.get("severity", "unknown")
        emoji = _SEVERITY_EMOJI.get(severity, "ℹ️")
        head = f"🔥 {emoji} **{name}** ({severity})"

    lines = [head]
    summary = annotations.get("summary")
    if summary:
        lines.append(summary)
    description = annotations.get("description")
    if description and description != summary:
        lines.append(description)
    if len(lines) == 1:
        # No annotations at all — show the labels so the message still
        # identifies what fired.
        extras = [
            f"{key}={labels[key]}"
            for key in sorted(labels)
            if key not in ("alertname", "severity")
        ]
        if extras:
            lines.append(", ".join(extras))

    message = "\n".join(lines)
    if len(message) > _MAX_LEN:
        message = message[: _MAX_LEN - 1] + "…"
    return message


def format_alerts(payload):
    """Alertmanager webhook payload dict -> list of Discord messages.

    One message per alert; malformed input yields [] rather than raising
    (the webhook must never crash the bridge).
    """
    if not isinstance(payload, dict):
        return []
    alerts = payload.get("alerts")
    if not isinstance(alerts, list):
        return []
    messages = []
    for alert in alerts:
        if isinstance(alert, dict):
            messages.append(_format_one(alert))
    return messages
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd /Users/tbigelow/Documents/code/chalupa-tech-local/homeassistant && source .venv/bin/activate && pytest -v
```

Expected: all `test_vmalert_format.py` tests PASS, and the pre-existing climate-balance tests still pass.

- [ ] **Step 5: Commit**

```bash
git add homeassistant/tests/test_vmalert_format.py homeassistant/pyscript/modules/vmalert_format.py
git commit -m "feat(ha): add Alertmanager->Discord message formatter"
```

---

### Task 4: Pyscript webhook app

**Files:**
- Create: `homeassistant/pyscript/apps/vmalert_discord.py`
- Modify: `homeassistant/CLAUDE.md` (the "What lives in this directory" table + Pyscript layout section)

**Interfaces:**
- Consumes: `format_alerts` from Task 3; `pyscript.app_config` keys `webhook_id` and `channel_id` (supplied on HAOS, Task 7).
- Produces: an HA webhook at `/api/webhook/<webhook_id>` that posts each alert to Discord. The OpenBao `url` value (Task 7) must use the SAME webhook id.

- [ ] **Step 1: Create the app**

`homeassistant/pyscript/apps/vmalert_discord.py`:

```python
"""Alertmanager -> Discord bridge (Pyscript app).

Receives Alertmanager webhook POSTs from the vmalert stack and forwards
each firing/resolved alert to the Discord alerts channel via
notify.homeassistant_tejon_frame.

This is a Pyscript *app*: it only loads when configuration.yaml carries
a `pyscript: apps: vmalert_discord:` block supplying `webhook_id` and
`channel_id` (both via !secret — they stay out of Git; the webhook id
doubles as the shared secret since HA webhooks are unauthenticated).
See gitops/apps/observability/vmalert/RUNBOOK.md for setup.
"""
from vmalert_format import format_alerts

_NOTIFY_SERVICE = "homeassistant_tejon_frame"  # notify.<service> for Discord

_WEBHOOK_ID = pyscript.app_config["webhook_id"]
_CHANNEL_ID = str(pyscript.app_config["channel_id"])


@webhook_trigger(_WEBHOOK_ID, methods=["POST"])
def vmalert_webhook(**kwargs):
    payload = kwargs.get("webhook_data") or {}
    messages = format_alerts(payload)
    log.info(f"vmalert webhook received {len(messages)} alert(s)")
    for message in messages:
        # service.call so the dynamic service name resolves at runtime
        # (attribute-style notify.<name> is a parse-time lookup that
        # silently drops for custom service names — see CLAUDE.md).
        service.call("notify", _NOTIFY_SERVICE,
                     message=message, target=[_CHANNEL_ID])
```

- [ ] **Step 2: Syntax check (the only static check Pyscript files get)**

```bash
python3 -m py_compile /Users/tbigelow/Documents/code/chalupa-tech-local/homeassistant/pyscript/apps/vmalert_discord.py && echo OK
```

Expected: `OK` (py_compile checks syntax only; `pyscript`, `webhook_trigger`, `log`, `service` are Pyscript runtime globals).

- [ ] **Step 3: Update homeassistant/CLAUDE.md**

In the "Pyscript layout" section, after the `modules/*.py` bullet, add:

```markdown
- `/config/pyscript/apps/*.py` — **apps**: like trigger scripts, but only
  loaded when `configuration.yaml` has a matching `pyscript: apps: <name>:`
  entry; that config is exposed to the app as `pyscript.app_config`. Used
  to keep secrets (webhook IDs) in HAOS `secrets.yaml` instead of Git.
```

In the "What lives in this directory" table, add rows:

```markdown
| `pyscript/apps/vmalert_discord.py` | Alertmanager→Discord webhook bridge (config via `pyscript.app_config`) | yes → `/config/pyscript/apps/` |
| `pyscript/modules/vmalert_format.py` | Alert → Discord message formatting | yes → `/config/pyscript/modules/` |
```

- [ ] **Step 4: Commit**

```bash
git add homeassistant/pyscript/apps/vmalert_discord.py homeassistant/CLAUDE.md
git commit -m "feat(ha): add vmalert Discord webhook bridge app"
```

---

### Task 5: OpenBao policy, runbook, docs entry

**Files:**
- Create: `scripts/openbao/policies/observability-read.hcl`
- Create: `gitops/apps/observability/vmalert/RUNBOOK.md`
- Create: `docs/2026-09-08-add-cluster-alerting.md`

**Interfaces:**
- Consumes: alert/receiver names and paths exactly as defined in Tasks 1–4.
- Produces: the runbook Task 7 executes verbatim.

- [ ] **Step 1: Create the policy file**

The `observability-read` policy exists live (created by `seed-grafana-admin.sh`, granting only `secret/data/grafana/*`) and is already bound to the `external-secrets` auth role. This file makes it repo-tracked (the media-read convention: the .hcl is the source of truth) and adds the vmalert path.

`scripts/openbao/policies/observability-read.hcl`:

```hcl
# OpenBao policy: observability-read
#
# Grants read on the KV v2 paths used by apps in observability
# namespaces (grafana, vm-system). Bound to the `external-secrets`
# Kubernetes auth role alongside `cloudflare-read`, `media-read`, and
# `renovate-read` — the binding already exists (seed-grafana-admin.sh),
# so extending this file + apply-policy.sh is all a new path needs.
#
# Apply with: ./scripts/openbao/apply-policy.sh observability-read
#
# This file is the source of truth — `bao policy read observability-read`
# should match it byte-for-byte after a successful apply. (Until first
# apply, the live policy is the seed-grafana-admin.sh one-liner covering
# only grafana/*.)

path "secret/data/grafana/*" { capabilities = ["read"] }
path "secret/data/vmalert/*" { capabilities = ["read"] }
```

- [ ] **Step 2: Create the runbook**

`gitops/apps/observability/vmalert/RUNBOOK.md`:

````markdown
# vmalert alerting — one-time manual setup

The alerting pipeline is GitOps-managed except for four secrets/steps
that must be performed by hand once. Order matters.

## 1. Create the Discord alerts channel

In the Discord server, create `#homelab-alerts` (or similar). Right-click
→ Copy Channel ID (enable Developer Mode if needed). Call it CHANNEL_ID.

## 2. Generate the webhook ID

```bash
WEBHOOK_ID=$(openssl rand -hex 32)
```

This long random string is the shared secret: HA webhooks are
unauthenticated by design, LAN-only exposure. It must never be committed.

## 3. Configure Home Assistant (HAOS, 192.168.1.234)

Prereq: pyscript ≥ 1.5 (webhook_trigger support) — check
`/config/custom_components/pyscript/manifest.json`.

Append to `/config/secrets.yaml` (values quoted):

```yaml
vmalert_webhook_id: "<WEBHOOK_ID>"
vmalert_discord_channel_id: "<CHANNEL_ID>"
```

Merge into `/config/configuration.yaml` (create or extend the existing
`pyscript:` block — if pyscript was set up via the UI config flow there
may be none yet; the `apps:` map must live in YAML either way):

```yaml
pyscript:
  apps:
    vmalert_discord:
      webhook_id: !secret vmalert_webhook_id
      channel_id: !secret vmalert_discord_channel_id
```

Deploy the two Python files (SFTP is blocked; cat-pipe + sudo mv):

```bash
cd homeassistant
for f in pyscript/modules/vmalert_format.py pyscript/apps/vmalert_discord.py; do
  cat "$f" | ssh -i ~/.ssh/pulumi_proxmox_runner tayvenbigelow@192.168.1.234 "cat > /tmp/$(basename $f)"
done
ssh -i ~/.ssh/pulumi_proxmox_runner tayvenbigelow@192.168.1.234 "
  sudo mkdir -p /config/pyscript/apps &&
  sudo mv /tmp/vmalert_format.py /config/pyscript/modules/ &&
  sudo mv /tmp/vmalert_discord.py /config/pyscript/apps/
"
```

Reload pyscript (config changes need it; file changes alone auto-reload):

```bash
TOK="${HOMEASSISTANT_TOKEN:-$(cat ~/.config/ha/llat)}"
curl -s -X POST -H "Authorization: Bearer $TOK" -d '{}' \
  http://192.168.1.234:8123/api/services/pyscript/reload
curl -s -H "Authorization: Bearer $TOK" \
  http://192.168.1.234:8123/api/error_log | grep -i vmalert
```

Expected: no errors mentioning vmalert.

Smoke-test the bridge directly (before the cluster side exists):

```bash
curl -s -X POST "http://192.168.1.234:8123/api/webhook/$WEBHOOK_ID" \
  -H 'Content-Type: application/json' \
  -d '{"alerts":[{"status":"firing","labels":{"alertname":"BridgeSmokeTest","severity":"warning"},"annotations":{"summary":"pyscript bridge smoke test"}}]}'
```

Expected: `🔥 ⚠️ **BridgeSmokeTest** (warning)` appears in #homelab-alerts.

## 4. Seed OpenBao

OpenBao seals on every reboot — check `bao status` / unseal first if
needed (`scripts/openbao/unseal.sh`).

```bash
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
OPENBAO_TOKEN=$(jq -r '.root_token' ~/secure/openbao-init.json)
export OPENBAO_TOKEN

# Extend the observability-read policy (adds secret/data/vmalert/*):
./scripts/openbao/apply-policy.sh observability-read

# Write the webhook URL (single key, so kv-put's replace semantics are fine):
./scripts/openbao/kv-put.sh vmalert/ha-webhook \
  url="http://192.168.1.234:8123/api/webhook/$WEBHOOK_ID"
```

## 5. Verify after the PR merges

```bash
export KUBECONFIG=~/.kube/chalupa-cluster.yaml
kubectl -n vm-system get externalsecret vmalert-ha-webhook   # READY True
kubectl -n vm-system get pods | grep -E 'vmalert|vmalertmanager'  # both Running
kubectl -n vm-system get vmalertmanagerconfig discord \
  -o jsonpath='{.status}'                                    # no parse errors
kubectl -n vm-system get vmrule                              # plex, arrs, meta
```

## 6. End-to-end test (ephemeral, never committed)

```bash
kubectl apply -f - <<'EOF'
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: e2e-always-firing
  namespace: vm-system
spec:
  groups:
    - name: e2e
      rules:
        - alert: AlwaysFiring
          expr: vector(1)
          labels:
            severity: warning
          annotations:
            summary: End-to-end alerting pipeline test
EOF
```

Within ~2 min (30s eval + 30s group_wait): `🔥 ⚠️ **AlwaysFiring**` in
Discord. Then delete to verify the resolved path:

```bash
kubectl delete vmrule -n vm-system e2e-always-firing
```

Within ~5 min (group_interval): `✅ **AlwaysFiring** resolved`.

ArgoCD does not prune this object (it was never tracked); deleting it by
hand is the cleanup.
````

- [ ] **Step 3: Create the docs entry**

`docs/2026-09-08-add-cluster-alerting.md`:

```markdown
# Add cluster alerting: vmalert + Alertmanager + Discord delivery

**Date:** 2026-09-08
**PR:** #TBD <!-- fill in at PR time -->
**Design:** docs/superpowers/specs/2026-09-08-cluster-monitoring-design.md (PR 1 of 3)

## What

- New GitOps app `gitops/apps/observability/vmalert`: VMAlert +
  VMAlertmanager + VMAlertmanagerConfig CRs (operator CRDs already
  installed by vm-system), an ExternalSecret for the HA webhook URL,
  and VMRule files for Plex, the *arr stack, and a TargetDown safety
  net. Adding a future monitor = one file under `templates/rules/`.
- Delivery: Alertmanager → HA webhook → pyscript app
  `vmalert_discord` → Discord alerts channel (via the existing
  `notify.homeassistant_tejon_frame` bot).
- One-time manual setup (webhook ID, Discord channel, OpenBao seed,
  HAOS config) documented in the app's RUNBOOK.md.

## Why this shape

- Rules as VMRule YAML in Git: PR-reviewed, rebuildable, no alert
  state outside the repo (vs Grafana unified alerting / Uptime Kuma).
- Discord via the existing HA bot (user choice); Alertmanager can't
  speak HA's notify format, so a pyscript webhook bridges it — in Git,
  unlike a UI automation. If HA is down, alerts don't deliver;
  accepted for homelab (Alertmanager retries cover HA restarts).
- The webhook ID is the shared secret: it lives in HAOS secrets.yaml
  and OpenBao only (public repo). The spec sketched hardcoding it in
  the pyscript file; that contradicted its own "never lands in Git"
  requirement, so the bridge is a pyscript *app* configured via
  `pyscript.app_config` + `!secret`.
- `disableNamespaceMatcher: true` on VMAlertmanager: without it the
  operator scopes the Discord route to alerts labeled
  namespace=vm-system, silently dropping alerts about media-namespace
  metrics.
- Side effect: ArgoCD's CreateNamespace creates an empty `vmalert`
  namespace (ApplicationSet destination = dir basename) while all
  resources explicitly target vm-system. Harmless; revisit if the
  ApplicationSet ever grows per-app destination overrides.

## Follow-ups

- PR 2: Proxmox host node-exporter + rules.
- PR 3: TrueNAS health (json_exporter polling /api/v2.0/alert/list).
- Future: dead-man's-switch for the pipeline itself (HA-side heartbeat
  timer) — deliberately out of scope in the design.
```

- [ ] **Step 4: yamllint + full-tree render check (what CI will run)**

```bash
cd /Users/tbigelow/Documents/code/chalupa-tech-local
yamllint gitops/
helm template vmalert gitops/apps/observability/vmalert > /dev/null && echo RENDER-OK
```

Expected: exit 0, `RENDER-OK`.

- [ ] **Step 5: Commit**

```bash
git add scripts/openbao/policies/observability-read.hcl \
        gitops/apps/observability/vmalert/RUNBOOK.md \
        docs/2026-09-08-add-cluster-alerting.md
git commit -m "docs: add vmalert runbook, observability-read policy file, alerting docs entry"
```

---

### Task 6: PR

**Files:** none (branch → PR).

- [ ] **Step 1: Full local verification**

```bash
cd /Users/tbigelow/Documents/code/chalupa-tech-local
yamllint gitops/ .github/workflows/gitops.yml
helm template vmalert gitops/apps/observability/vmalert > /dev/null && echo RENDER-OK
cd homeassistant && source .venv/bin/activate && pytest -v && cd ..
```

Expected: all green.

- [ ] **Step 2: Push branch + open PR** (use superpowers:finishing-a-development-branch)

PR body: what/why summary, link to the design spec and `docs/2026-09-08-add-cluster-alerting.md`, note that merge only deploys the cluster half — the RUNBOOK manual steps + e2e test follow post-merge. Update the `#TBD` PR number in the docs entry before merge (amend or follow-up commit — check the PR is still open first, per standing feedback).

- [ ] **Step 3: Watch required checks**

`Lint and dry-render gitops/` must pass (it renders the new chart with kubeconform; VMAlertmanagerConfig is now in SKIP_KINDS). Ansible/Pulumi checks skip (no files touched).

---

### Task 7: Post-merge deployment + end-to-end test

**Files:** none (live operations; every command already written in `gitops/apps/observability/vmalert/RUNBOOK.md` — execute it top to bottom).

- [ ] **Step 1:** RUNBOOK §1–2 — create Discord channel, generate webhook ID. (Needs the user for the Discord-channel step if not pre-created.)
- [ ] **Step 2:** RUNBOOK §3 — HAOS secrets.yaml + configuration.yaml + deploy the two files + pyscript reload + direct-curl smoke test. Pre-check: SSH add-on was refusing connections on 2026-09-08 — the user may need to start it (HA UI → Settings → Add-ons → SSH & Web Terminal).
- [ ] **Step 3:** RUNBOOK §4 — unseal check, apply observability-read policy, seed `secret/vmalert/ha-webhook`.
- [ ] **Step 4:** Merge-dependent — after ArgoCD syncs the `vmalert` app, RUNBOOK §5 verification (ExternalSecret READY, pods Running, no config parse errors, 3 VMRules).
- [ ] **Step 5:** RUNBOOK §6 — AlwaysFiring e2e: firing message, then delete, then resolved message.
- [ ] **Step 6:** Report results; if the webhook never fires, debug order: vmalert UI targets → Alertmanager logs → HA error_log → Discord.
