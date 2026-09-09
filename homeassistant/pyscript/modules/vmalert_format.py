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
