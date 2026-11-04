#!/usr/bin/env python3
"""Structural checks on the rendered pvc-backups chart.

One ReplicationSource per expected PVC (in its namespace, named after it),
Direct copy method only, per-source restic secrets whose repository URL ends
in /<namespace>-<pvc>, schedules/retention from values.
"""
import subprocess
import sys
from pathlib import Path

import yaml

CHART = Path(__file__).resolve().parent.parent
EXPECTED = {
    ("openbao", "data-openbao-0"): "0 * * * *",
    ("openbao", "data-openbao-1"): "0 * * * *",
    ("openbao", "data-openbao-2"): "0 * * * *",
    ("grafana", "grafana"): "15 * * * *",
    ("media", "audiobookshelf-config"): "15 * * * *",
    ("media", "audiobookshelf-metadata"): "15 * * * *",
    ("media", "readmebook-config"): "15 * * * *",
    ("media", "readmebook-cache"): "15 * * * *",
    ("vm-system", "vmsingle-vmsingle-chalupa"): "30 2 * * *",
    ("vl-system", "server-volume-vl-system-victoria-logs-single-server-0"): "30 2 * * *",
}


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


out = subprocess.run(
    ["helm", "template", "pvc-backups", str(CHART), "--api-versions", "external-secrets.io/v1"],
    capture_output=True, text=True,
)
if out.returncode != 0:
    fail(f"helm template failed: {out.stderr.strip()[:400]}")
docs = [d for d in yaml.safe_load_all(out.stdout) if d]
by_kind = {}
for d in docs:
    by_kind.setdefault(d["kind"], []).append(d)

sources = {(d["metadata"]["namespace"], d["metadata"]["name"]): d for d in by_kind.get("ReplicationSource", [])}
if set(sources) != set(EXPECTED):
    fail(f"ReplicationSources mismatch: missing={set(EXPECTED) - set(sources)} extra={set(sources) - set(EXPECTED)}")

secrets = {(d["metadata"]["namespace"], d["metadata"]["name"]): d for d in by_kind.get("ExternalSecret", [])}
for (ns, name), schedule in EXPECTED.items():
    rs = sources[(ns, name)]["spec"]
    if rs["sourcePVC"] != name:
        fail(f"{ns}/{name}: sourcePVC is {rs['sourcePVC']}")
    if rs["trigger"]["schedule"] != schedule:
        fail(f"{ns}/{name}: schedule {rs['trigger']['schedule']} != {schedule}")
    restic = rs["restic"]
    if restic["copyMethod"] != "Direct":
        fail(f"{ns}/{name}: copyMethod {restic['copyMethod']} (local-path has no CSI snapshots)")
    if restic["repository"] != f"restic-{name}":
        fail(f"{ns}/{name}: repository secret {restic['repository']}")
    if restic.get("pruneIntervalDays") != 7:
        fail(f"{ns}/{name}: pruneIntervalDays {restic.get('pruneIntervalDays')}")
    if restic["retain"] != {"hourly": 24, "daily": 14, "weekly": 8}:
        fail(f"{ns}/{name}: retain {restic['retain']}")
    es = secrets.get((ns, f"restic-{name}"))
    if es is None:
        fail(f"{ns}/{name}: ExternalSecret restic-{name} missing")
    repo = es["spec"]["target"]["template"]["data"]["RESTIC_REPOSITORY"]
    if not repo.endswith(f"/{ns}-{name}") or not repo.startswith("rest:http://restic-rest.backups.svc.cluster.local:8000/"):
        fail(f"{ns}/{name}: RESTIC_REPOSITORY {repo}")
    if es["spec"]["data"][0]["remoteRef"] != {"key": "backups/restic", "property": "password"}:
        fail(f"{ns}/{name}: password remoteRef {es['spec']['data'][0]['remoteRef']}")

for d in docs:
    text = yaml.safe_dump(d)
    if "copyMethod: Snapshot" in text or "copyMethod: Clone" in text:
        fail("Snapshot/Clone copyMethod present")
print("PASS")
