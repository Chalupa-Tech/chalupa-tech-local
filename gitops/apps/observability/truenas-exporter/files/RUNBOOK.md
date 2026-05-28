# truenas-exporter — Operator runbook

One-time setup after the chart syncs in ArgoCD. The two manual steps
both happen on the TrueNAS side; nothing else in the cluster needs
poking.

## Prereqs

- `truenas-exporter` Application is `Synced/Healthy` in ArgoCD.
- `kubectl -n truenas-exporter get svc truenas-exporter-graphite` shows
  `EXTERNAL-IP   192.168.1.161` (MetalLB-assigned).
- LAN access to the TrueNAS web UI at `https://192.168.1.40`.

## Step 1 — TrueNAS Reporting → Exporters

1. Open the TrueNAS UI → **Reporting** → click **Exporters** (top right).
2. Click **Add** (or **Edit** an existing graphite reporter).
3. Pick `Graphite` as the type, then fill:
   | Field | Value |
   |---|---|
   | Enable | checked |
   | Destination IP | `192.168.1.161` |
   | Destination Port | `9109` |
   | Prefix | `truenas` *(required — the mapping file keys off this)* |
   | Namespace | `truenas` *(populates the `instance` label on every metric; field was previously labeled "Hostname")* |
   | Update Every | leave blank *(netdata.conf sets `update_every = 10`, which is finer than the 30 s scrape — always a recent sample available)* |
   | Buffer On Failures | leave blank |
   | Send Names Instead Of Ids | leave blank *(defaults to true; explicitly setting false errors out on save)* |
   | Matching Charts | leave blank *(filter; blank = send everything, which is what the mapping file expects)* |
4. **Save**. TrueNAS starts pushing immediately.

## Step 2 — Drop the custom netdata.conf onto the TrueNAS host

TrueNAS 25.04 ships a stripped-down `/etc/netdata/netdata.conf` that
omits many of the metrics the upstream dashboards expect. The pinned
copy under `files/netdata.conf` (from Supporterino v2.2.1) restores
them.

SSH to TrueNAS (admin user with sudo) and:

```bash
scp gitops/apps/observability/truenas-exporter/files/netdata.conf \
    admin@192.168.1.40:/tmp/netdata.conf

ssh admin@192.168.1.40 <<'EOF'
sudo cp /tmp/netdata.conf /etc/netdata/netdata.conf
sudo chown root:root /etc/netdata/netdata.conf
sudo systemctl restart netdata
EOF
```

> **TrueNAS updates wipe `/etc/netdata/netdata.conf`.** Re-run this after
> each TrueNAS update until upstream lands a persistent fix
> ([tracking issue](https://github.com/Supporterino/truenas-graphite-to-prometheus/issues)).

## Verify

```bash
# Pod is receiving graphite samples and exposing them as Prometheus:
kubectl -n truenas-exporter port-forward svc/truenas-exporter-main 9108:9108 &
curl -s localhost:9108/metrics | grep -c 'job="truenas"'
# Expect: a few hundred lines

# vmagent is scraping them:
kubectl -n vm-system port-forward svc/vmagent-vmagent-chalupa 8429:8429 &
curl -s 'localhost:8429/api/v1/targets' | jq '.data.activeTargets[] | select(.scrapePool | contains("truenas"))'
# Expect: one entry, "health": "up"
```

In Grafana the five `TrueNAS Scale / ...` dashboards begin showing data
within one scrape interval (30 s).

## Files in this directory

- `graphite_mapping.conf` — Supporterino v2.2.1 mapping rules, mounted
  at `/etc/graphite-exporter/graphite_mapping.conf` inside the pod via
  the `truenas-exporter-mapping` ConfigMap.
- `netdata.conf` — operator-only artifact; the chart does **not** mount
  it. It's checked in here so the runbook above can `scp` from the repo
  without a separate download step.
- `RUNBOOK.md` — this file.
