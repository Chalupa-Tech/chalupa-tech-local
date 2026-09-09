# vmalert alerting — one-time manual setup

The alerting pipeline is GitOps-managed except for four secrets/steps
that must be performed by hand once. Order matters.

## 1. Create the Discord alerts channel

In the Discord server, create `#homelab-alerts` (or similar). Right-click
→ Copy Channel ID (enable Developer Mode if needed). Call it CHANNEL_ID.
Make sure the Home Assistant Discord bot (the one behind
`notify.homeassistant_tejon_frame`) can view and post in the new
channel — a fresh channel may not inherit the bot's role permissions.

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

**Do this (and §1–3) BEFORE merging the PR.** The vmalert app's
ExternalSecret is sync-wave 0: if it can't resolve the OpenBao secret,
ArgoCD marks the app Degraded, exhausts its retry budget (~20 min), and
will NOT retry on its own. If the PR merged first anyway, seed the
secret and then force a sync: `kubectl -n argocd annotate application
vmalert argocd.argoproj.io/refresh=hard --overwrite` (or `argocd app
sync vmalert`).

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
