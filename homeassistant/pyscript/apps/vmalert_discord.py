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
