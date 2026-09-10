# Cluster Monitoring PR 2 — Proxmox Host Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collect CPU/memory/temperature metrics from the Proxmox host (pve1) via node-exporter and alert on them — PR 2 of the design in `docs/superpowers/specs/2026-09-08-cluster-monitoring-design.md`.

**Architecture:** Ansible (`proxmox_prep` role) installs Debian's `prometheus-node-exporter` on pve1 (`:9100`, LAN-only). A `VMStaticScrape` in the existing vm-system app points vmagent at `192.168.1.223:9100` as job `proxmox-host` with instance relabeled to `pve1`. A new `proxmox-host.yaml` VMRule in the vmalert app (PR 1) defines the five host alerts; delivery rides the already-verified pipeline. No new secrets, no HA-side changes.

**Tech Stack:** Ansible (apt/systemd modules), VictoriaMetrics operator CRs, PromQL over node-exporter metrics.

## Global Constraints

- **All changes via PRs**; CI applies them. Merging to main runs the deploy pipeline whose Stage 1 executes `site.yml` (the `proxmox_prep` role) against pve1 — that is how the exporter gets installed. Only `--check` runs are allowed locally.
- Branch from **origin/main** (PR 1 + sync-wave fix are merged; do not branch from the old feat/alerting-core).
- All k8s resources carry explicit `namespace: vm-system`.
- **Helm-escape Prometheus template syntax** in VMRule annotations: `{{ "{{ $value }}" }}` renders to the literal `{{ $value }}`. Bare `{{ $value }}` breaks the required "Lint and dry-render gitops/" CI check.
- **vm-operator CRDs are schemaless** — `VMStaticScrape` must be added to kubeconform's SKIP_KINDS in `.github/workflows/gitops.yml` (same reason VMAlertmanagerConfig was: the datreeio catalog is stale/absent for vm-operator kinds).
- vmagent already selects all scrape CRDs (`staticScrapeSelector: {}` + `selectAllByDefault: true` in `vm-system/templates/vmagent.yaml`) — no vmagent change needed.
- node-exporter is NOT a target-shaped exporter (it reports about itself), so no `honorLabels` is needed (standing feedback memory applies only to KSM/blackbox/snmp/pushgateway-style exporters).
- The vmalert app's `VMAlert` uses `selectAllByDefault: true` — a new VMRule needs no selector labels. Rule files use sync-wave "30" like the existing ones.
- Ansible style: FQCN modules (`ansible.builtin.*`), task names start with a capital, registered vars prefixed `proxmox_prep_`. CI runs `ansible-lint` then `ansible-playbook -i inventory.yml site.yml --check --diff` against the live host.
- Commit style: conventional commits, ending with a blank line then `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Temperature metric caveat:** k10temp readings surface as `node_hwmon_temp_celsius{chip=...}` where the chip label is a bus path, not "k10temp"; the human-readable name lives in the companion series `node_hwmon_chip_names{chip=..., chip_name="k10temp"} 1`. The rules therefore use the standard join (shown in Task 3). The exact labels are unverifiable until the exporter runs on this hardware — Task 6 verifies live and tunes if the join matches nothing.

## Repo facts the implementer needs

| Fact | Value |
|---|---|
| Ansible role to extend | `ansible/roles/proxmox_prep/tasks/main.yml` (append at end; sectioned with `# --- ... ---` comment headers) |
| Scrape CR location | `gitops/apps/observability/vm-system/templates/vmstaticscrape-proxmox-host.yaml` (peer files use sync-wave "30") |
| Rules location | `gitops/apps/observability/vmalert/templates/rules/proxmox-host.yaml` |
| SKIP_KINDS line | `.github/workflows/gitops.yml:91` — comma list currently ends `...,VMAlertmanagerConfig,VMAlert,VMCluster,VMAuth` |
| Proxmox host | `192.168.1.223` (pve1), AMD Strix Halo (k10temp) |
| Render/lint commands | `helm template <name> <chart-dir>`, `yamllint gitops/`, `cd ansible && ansible-lint` (all installed locally) |
| Alert set (design) | ProxmoxHostDown (critical, 5m), ProxmoxHighCPU >90% 15m (warning), ProxmoxHighMemory >92% 10m (warning), ProxmoxHighTemp >85°C 10m (warning), ProxmoxCriticalTemp >95°C 5m (critical) |

---

### Task 1: Ansible — node-exporter on pve1

**Files:**
- Modify: `ansible/roles/proxmox_prep/tasks/main.yml` (append at end)

**Interfaces:**
- Produces: `prometheus-node-exporter` service on pve1 listening on `0.0.0.0:9100` — the target Task 2's VMStaticScrape points at.

- [ ] **Step 1: Append the task section**

At the end of `ansible/roles/proxmox_prep/tasks/main.yml`, append:

```yaml

# --- node-exporter (host CPU/mem/temp metrics for the vmalert stack) ---
# Scraped by vmagent via the VMStaticScrape in
# gitops/apps/observability/vm-system/ (job proxmox-host). Listens on
# :9100; LAN-only host, no auth needed. Debian's package ships a
# systemd unit that is enabled+started on install; the explicit state
# task below makes the desired state idempotent and self-healing.
- name: Install prometheus-node-exporter
  ansible.builtin.apt:
    name: prometheus-node-exporter
    state: present

- name: Ensure prometheus-node-exporter is enabled and running
  ansible.builtin.systemd_service:
    name: prometheus-node-exporter
    enabled: true
    state: started
  # In --check runs (the CI "Check & Diff (PR)" job) the apt task above
  # doesn't actually install, so this unit doesn't exist yet and the
  # module would hard-fail. Standard guard: tolerate errors only in
  # check mode; real runs still fail loudly.
  ignore_errors: "{{ ansible_check_mode }}"
```

- [ ] **Step 2: Lint**

Run: `cd ansible && ansible-lint`
Expected: exit 0, no new violations (pre-existing state is clean).

- [ ] **Step 3: Dry-run against the live host**

Run: `cd ansible && ansible-playbook -i inventory.yml site.yml --check --diff 2>&1 | tail -20`
Expected: play completes with **no unignored failures**; the apt task shows `changed` (package not yet installed), and the systemd task either shows `changed`/`ok` or is **ignored** (its `ignore_errors: "{{ ansible_check_mode }}"` guard — the unit can't exist until the package really installs). (`--check` is the sanctioned local mode; the real apply happens via CI on merge.)

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/proxmox_prep/tasks/main.yml
git commit -m "feat(ansible): install node-exporter on pve1 for host metrics"
```

---

### Task 2: VMStaticScrape + CI skip-list

**Files:**
- Create: `gitops/apps/observability/vm-system/templates/vmstaticscrape-proxmox-host.yaml`
- Modify: `.github/workflows/gitops.yml` (SKIP_KINDS line only)

**Interfaces:**
- Consumes: the `:9100` exporter from Task 1 (target address `192.168.1.223:9100`).
- Produces: series labeled `job="proxmox-host", instance="pve1"` — Task 3's rules and the existing `TargetDown` safety net key off exactly these labels.

- [ ] **Step 1: Create the VMStaticScrape**

`gitops/apps/observability/vm-system/templates/vmstaticscrape-proxmox-host.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMStaticScrape
metadata:
  name: proxmox-host
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  # jobName becomes the `job` label — the proxmox-host.yaml VMRules and
  # the TargetDown safety net both match on it.
  jobName: proxmox-host
  targetEndpoints:
    - targets:
        - 192.168.1.223:9100
      scrapeInterval: 30s
      relabelConfigs:
        # `instance` would default to the raw address; pve1 reads better
        # in alerts and dashboards.
        - targetLabel: instance
          replacement: pve1
```

- [ ] **Step 2: Add VMStaticScrape to kubeconform SKIP_KINDS**

In `.github/workflows/gitops.yml` line 91, the list

```
SKIP_KINDS='VMSingle,VMAgent,VMServiceScrape,VMPodScrape,VMNodeScrape,VMRule,VMUser,VMAlertmanager,VMAlertmanagerConfig,VMAlert,VMCluster,VMAuth'
```

becomes

```
SKIP_KINDS='VMSingle,VMAgent,VMServiceScrape,VMPodScrape,VMNodeScrape,VMStaticScrape,VMRule,VMUser,VMAlertmanager,VMAlertmanagerConfig,VMAlert,VMCluster,VMAuth'
```

(Only this line changes; same stale-catalog rationale as the surrounding comment.)

- [ ] **Step 3: Render + lint**

```bash
helm template vm-system gitops/apps/observability/vm-system > /dev/null && echo RENDER-OK
yamllint gitops/apps/observability/vm-system .github/workflows/gitops.yml
```

Expected: RENDER-OK; yamllint exit 0. (`helm dependency update` may be needed first if `charts/` is absent: `helm dependency update gitops/apps/observability/vm-system`.)

- [ ] **Step 4: Commit**

```bash
git add gitops/apps/observability/vm-system/templates/vmstaticscrape-proxmox-host.yaml .github/workflows/gitops.yml
git commit -m "feat(gitops): scrape pve1 node-exporter as job proxmox-host"
```

---

### Task 3: proxmox-host alert rules

**Files:**
- Create: `gitops/apps/observability/vmalert/templates/rules/proxmox-host.yaml`

**Interfaces:**
- Consumes: `job="proxmox-host"` series from Task 2 (`up`, `node_cpu_seconds_total`, `node_memory_*`, `node_hwmon_temp_celsius`, `node_hwmon_chip_names`).
- Produces: alerts PlexDown-style through the PR-1 pipeline; names ProxmoxHostDown, ProxmoxHighCPU, ProxmoxHighMemory, ProxmoxHighTemp, ProxmoxCriticalTemp.

- [ ] **Step 1: Create the rule file**

`gitops/apps/observability/vmalert/templates/rules/proxmox-host.yaml` — note every `{{ "{{ ... }}" }}` is Helm escaping producing a literal Prometheus template:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: proxmox-host
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  groups:
    - name: proxmox-host
      rules:
        - alert: ProxmoxHostDown
          expr: 'up{job="proxmox-host"} == 0'
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: Proxmox host pve1 is down
            description: node-exporter on 192.168.1.223:9100 has been unreachable for 5+ minutes — host or exporter is down.
        - alert: ProxmoxHighCPU
          expr: '(1 - avg by (instance) (rate(node_cpu_seconds_total{job="proxmox-host",mode="idle"}[5m]))) * 100 > 90'
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: Proxmox host CPU above 90%
            description: 'pve1 CPU usage is {{ "{{ $value | printf \"%.0f\" }}" }}% averaged over 5m, sustained 15m.'
        - alert: ProxmoxHighMemory
          expr: '(1 - node_memory_MemAvailable_bytes{job="proxmox-host"} / node_memory_MemTotal_bytes{job="proxmox-host"}) * 100 > 92'
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: Proxmox host memory above 92%
            description: 'pve1 memory usage is {{ "{{ $value | printf \"%.0f\" }}" }}% — VMs + LXC + host overhead are close to the physical limit.'
        # k10temp readings: the chip label on node_hwmon_temp_celsius is a
        # bus path; the human-readable chip name lives in the companion
        # node_hwmon_chip_names series — hence the join. Verified against
        # live labels post-merge (plan Task 6).
        - alert: ProxmoxHighTemp
          expr: 'max by (instance) (node_hwmon_temp_celsius{job="proxmox-host"} * on(instance, chip) group_left(chip_name) node_hwmon_chip_names{job="proxmox-host",chip_name="k10temp"}) > 85'
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: Proxmox host CPU temperature above 85°C
            description: 'pve1 k10temp reads {{ "{{ $value | printf \"%.0f\" }}" }}°C for 10+ minutes — check airflow/load.'
        - alert: ProxmoxCriticalTemp
          expr: 'max by (instance) (node_hwmon_temp_celsius{job="proxmox-host"} * on(instance, chip) group_left(chip_name) node_hwmon_chip_names{job="proxmox-host",chip_name="k10temp"}) > 95'
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: Proxmox host CPU temperature above 95°C
            description: 'pve1 k10temp reads {{ "{{ $value | printf \"%.0f\" }}" }}°C — thermal throttling/shutdown territory.'
```

- [ ] **Step 2: Render and verify escaping**

```bash
helm template vmalert gitops/apps/observability/vmalert | grep -c 'kind: VMRule'
helm template vmalert gitops/apps/observability/vmalert | grep 'printf' | head -4
yamllint gitops/apps/observability/vmalert
```

Expected: `4` VMRules (plex, arrs, meta + proxmox-host); the grep prints literal `{{ $value | printf "%.0f" }}` lines (Helm passed them through); yamllint exit 0. A `function "printf" not defined`-style helm error means an escape was missed.

- [ ] **Step 3: Commit**

```bash
git add gitops/apps/observability/vmalert/templates/rules/proxmox-host.yaml
git commit -m "feat(gitops): add proxmox host CPU/memory/temperature alert rules"
```

---

### Task 4: Docs

**Files:**
- Create: `docs/2026-09-09-add-proxmox-host-metrics.md`
- Modify: `homeassistant/CLAUDE.md` (stale log-API guidance from the PR 1 debugging session)

- [ ] **Step 1: Create the docs entry**

`docs/2026-09-09-add-proxmox-host-metrics.md`:

```markdown
# Add Proxmox host metrics + alerts (node-exporter on pve1)

**Date:** 2026-09-09
**PR:** #TBD <!-- fill in at PR time -->
**Design:** docs/superpowers/specs/2026-09-08-cluster-monitoring-design.md (PR 2 of 3)

## What

- Ansible (`proxmox_prep`): install Debian's `prometheus-node-exporter`
  on pve1, enabled + started, listening on :9100 (LAN-only host).
- `VMStaticScrape` (vm-system app) targeting 192.168.1.223:9100 as job
  `proxmox-host`, instance relabeled to `pve1`. vmagent needed no
  changes (`staticScrapeSelector: {}` + selectAllByDefault were already
  set).
- `proxmox-host.yaml` VMRule in the vmalert app: ProxmoxHostDown
  (critical, 5m), ProxmoxHighCPU (>90% for 15m), ProxmoxHighMemory
  (>92% for 10m), ProxmoxHighTemp (k10temp >85°C for 10m),
  ProxmoxCriticalTemp (>95°C for 5m). Delivery rides the PR-1
  vmalert → Alertmanager → HA → Discord pipeline.
- CI: `VMStaticScrape` added to the kubeconform skip list (schemaless
  vm-operator CRD, same rationale as the existing entries).

## Why this shape

- node-exporter over pve-exporter: covers the asked-for CPU/mem/temps
  with one Ansible task-set; pve-exporter's per-VM API view adds no
  temperature data (design decision 3).
- Temperature rules join `node_hwmon_temp_celsius` with
  `node_hwmon_chip_names{chip_name="k10temp"}` because the chip label
  on the temperature series is a bus path, not a name.
- The host stays outside the cluster, so a static scrape (not a
  ServiceMonitor) is the natural fit; the exporter's death is covered
  both by ProxmoxHostDown and the PR-1 TargetDown safety net.

## Follow-ups

- PR 3: TrueNAS health (json_exporter polling /api/v2.0/alert/list).
```

- [ ] **Step 2: Refresh homeassistant/CLAUDE.md log guidance**

In `homeassistant/CLAUDE.md`, in the "## REST API" code block, replace the error-log comment and command:

```bash
# Tail the live error log (this is the ONLY way to see current HA logs —
# /config/home-assistant.log is rotated; the active log lives inside the
# supervisor container, not on disk)
curl -s -H "Authorization: Bearer $TOK" "$HA/api/error_log" | tail -50
```

with:

```bash
# NOTE (2026-09): /api/error_log and /api/error/all now return 404 on
# this HA build, and the live log is not on disk either. To debug
# pyscript, write progress to a state entity from the script
# (state.set("pyscript.<name>", value)) and read it back:
curl -s -H "Authorization: Bearer $TOK" "$HA/api/states/pyscript.vmalert_debug"
```

And in the "## Deploy + verify loop" section, replace the verification lines

```bash
curl -s -H "Authorization: Bearer $TOK" http://192.168.1.234:8123/api/error_log \
  | grep -i climate_balance | tail -10
```

with

```bash
# (error_log API removed — see REST API section; verify via entity state)
```

Keep the following `sensor.climate_balance_mode` check as is, and update the sentence below the block from "If `/api/error_log` is clean and `sensor.climate_balance_mode` updated, the deploy is healthy." to "If `sensor.climate_balance_mode` updated (and any debug state entities look right), the deploy is healthy."

- [ ] **Step 3: Lint check**

```bash
yamllint gitops/
```

Expected: exit 0 (guards against accidental chart damage; .md files are ignored).

- [ ] **Step 4: Commit**

```bash
git add docs/2026-09-09-add-proxmox-host-metrics.md homeassistant/CLAUDE.md
git commit -m "docs: proxmox host metrics entry; refresh stale HA log-API guidance"
```

---

### Task 5: PR

**Files:** none.

- [ ] **Step 1: Full local verification**

```bash
cd ansible && ansible-lint && cd ..
yamllint gitops/ .github/workflows/gitops.yml
helm template vm-system gitops/apps/observability/vm-system > /dev/null && echo VM-SYSTEM-OK
helm template vmalert gitops/apps/observability/vmalert > /dev/null && echo VMALERT-OK
```

Expected: all green.

- [ ] **Step 2: Push + PR** (superpowers:finishing-a-development-branch)

PR body: what/why, link to design + docs entry, note that merge triggers the deploy pipeline whose Ansible stage installs the exporter — no manual steps this time. Fill the docs entry's `#TBD` with the PR number once created (verify PR still open before pushing the fixup).

- [ ] **Step 3: Required checks**

Expect "Lint Ansible" + "Check & Diff (PR)" + "Lint and dry-render gitops/" to run and pass (this PR touches both ansible/ and gitops/).

---

### Task 6: Post-merge verification (live)

**Files:** none (read-only live checks; one contingency).

- [ ] **Step 1:** Watch the deploy workflow on main until Stage 1 (Ansible) succeeds: `gh run list --repo Chalupa-Tech/chalupa-tech-local --branch main --limit 1` then `gh run watch <id>` (or poll `gh run view <id>`).
- [ ] **Step 2:** Exporter up: `curl -s http://192.168.1.223:9100/metrics | head -3` from the Mac (LAN) returns metric text.
- [ ] **Step 3:** Scrape live: query VictoriaMetrics for `up{job="proxmox-host"}` — expect value 1 with `instance="pve1"` (ArgoCD must have synced vm-system first; it auto-syncs within ~3 min of merge).
- [ ] **Step 4:** Temperature labels: query `node_hwmon_chip_names{job="proxmox-host"}` and confirm a series with `chip_name="k10temp"` exists; then query the full ProxmoxHighTemp join expr (without the `> 85`) and confirm it returns a plausible °C value. **Contingency:** if `chip_name="k10temp"` doesn't exist (different sensor naming on Strix Halo), list the actual `chip_name` values and open a one-line PR adjusting the two temp rules' matcher.
- [ ] **Step 5:** Rules loaded: `kubectl -n vm-system get vmrule proxmox-host` shows STATUS `operational`; vmalert's `/api/v1/rules` lists the 5 new rules with no `lastError`.
- [ ] **Step 6:** Report results. No AlwaysFiring-style e2e needed — the pipeline itself was proven in PR 1; ProxmoxHostDown firing correctly is covered by the TargetDown-style semantics already verified.
