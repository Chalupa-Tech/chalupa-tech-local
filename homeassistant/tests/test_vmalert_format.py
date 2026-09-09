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


def test_non_dict_labels_and_annotations_do_not_raise():
    payload = {"alerts": [
        {"status": "firing", "labels": "bad", "annotations": 7},
    ]}
    msgs = format_alerts(payload)
    assert len(msgs) == 1
    assert "**UnknownAlert**" in msgs[0]


def test_non_string_annotation_values_do_not_raise():
    payload = {"alerts": [{
        "status": "firing",
        "labels": {"alertname": "Weird", "severity": "warning"},
        "annotations": {"summary": 123, "description": None},
    }]}
    msgs = format_alerts(payload)
    assert len(msgs) == 1
    assert "123" in msgs[0]
