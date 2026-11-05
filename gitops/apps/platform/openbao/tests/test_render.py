#!/usr/bin/env python3
"""Structural checks on the rendered openbao wrapper chart: the OCI KMS seal
plugin init container, its config/secret volumes, the extra -config flag and
the kms-init ConfigMap. Run: /usr/bin/python3 gitops/apps/platform/openbao/tests/test_render.py
"""
import re
import subprocess
import sys
from pathlib import Path

import yaml

CHART = Path(__file__).resolve().parent.parent
SCRIPT = CHART / "files" / "kms-init.sh"


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def render(*extra):
    out = subprocess.run(["helm", "template", "openbao", str(CHART), "--namespace", "openbao", *extra], capture_output=True, text=True)
    if out.returncode != 0:
        fail(f"helm template failed: {out.stderr.strip()[:400]}")
    docs = [d for d in yaml.safe_load_all(out.stdout) if d]
    by_kind = {}
    for d in docs:
        by_kind.setdefault(d["kind"], []).append(d)
    return by_kind


def sts(by_kind):
    s = [d for d in by_kind.get("StatefulSet", []) if d["metadata"]["name"] == "openbao"]
    if len(s) != 1:
        fail("expected one StatefulSet named openbao")
    return s[0]["spec"]["template"]["spec"]


def env_map(container):
    return {e["name"]: e.get("value") for e in container.get("env", [])}


values = yaml.safe_load((CHART / "values.yaml").read_text())
pin = values["global"]["ociKms"]["plugin"]
if not re.fullmatch(r"[0-9a-f]{64}", pin["sha256"]):
    fail("global.ociKms.plugin.sha256 must be a 64-char hex sha256")
if values["global"]["ociKms"]["enabled"] is not False:
    fail("global.ociKms.enabled must default to false (flipped only by the migration runbook)")

by_kind = render()
spec = sts(by_kind)
server = spec["containers"][0]
inits = {c["name"]: c for c in spec.get("initContainers") or []}
if "kms-init" not in inits:
    fail("initContainer kms-init missing")
init = inits["kms-init"]
if init["image"] != server["image"]:
    fail(f"kms-init image {init['image']} != server image {server['image']}")
env = env_map(init)
if env.get("OCI_KMS_ENABLED") != "false":
    fail(f"OCI_KMS_ENABLED default: {env.get('OCI_KMS_ENABLED')}")
if env.get("OCI_KMS_DISABLED") != "false":
    fail("OCI_KMS_DISABLED default must be false")
if env.get("PLUGIN_VERSION") != str(pin["version"]) or env.get("PLUGIN_SHA256") != pin["sha256"]:
    fail("PLUGIN_VERSION/PLUGIN_SHA256 must come from global.ociKms.plugin")
if env.get("KMS_DIR") != "/openbao/kms":
    fail("KMS_DIR must be /openbao/kms")
env_from = [e.get("secretRef", {}) for e in init.get("envFrom", [])]
if not any(s.get("name") == "openbao-oci-kms" and s.get("optional") is True for s in env_from):
    fail("kms-init must envFrom secret openbao-oci-kms (optional)")
if " ".join(init.get("command", []) + init.get("args", [])).find("/openbao/kms-init/kms-init.sh") < 0:
    fail("kms-init must run /openbao/kms-init/kms-init.sh")
init_mounts = {m["mountPath"]: m for m in init.get("volumeMounts", [])}
if "/openbao/kms" not in init_mounts or "/openbao/kms-init" not in init_mounts:
    fail(f"kms-init mounts: {sorted(init_mounts)}")
cache = init_mounts.get("/openbao/kms-cache")
if not cache or cache["name"] != "data" or cache.get("subPath") != "kms-cache":
    fail(f"kms-init must cache the plugin on the data PVC (volume data, subPath kms-cache): {cache}")
if env.get("PLUGIN_CACHE_DIR") != "/openbao/kms-cache":
    fail("PLUGIN_CACHE_DIR must point at the cache mount")
if init.get("securityContext", {}).get("allowPrivilegeEscalation") is not False:
    fail("kms-init must set allowPrivilegeEscalation: false like the server")

vols = {v["name"]: v for v in spec["volumes"]}
if "emptyDir" not in vols.get("kms", {}):
    fail("volume kms must be an emptyDir")
sec = vols.get("oci-config", {}).get("secret", {})
if sec.get("secretName") != "openbao-oci-kms" or sec.get("optional") is not True or sec.get("defaultMode") != 0o440:
    fail(f"volume oci-config: {sec}")
if vols.get("kms-init", {}).get("configMap", {}).get("name") != "openbao-kms-init":
    fail("volume kms-init must come from ConfigMap openbao-kms-init")
if vols["kms-init"]["configMap"].get("defaultMode") != 0o555:
    fail("kms-init ConfigMap volume must be executable (defaultMode 0555)")

mounts = {m["mountPath"]: m for m in server["volumeMounts"]}
if "/openbao/kms" not in mounts:
    fail("server must mount /openbao/kms")
oci = mounts.get("/home/openbao/.oci")
if not oci or oci.get("readOnly") is not True or oci["name"] != "oci-config":
    fail(f"server must mount the oci-config secret read-only at /home/openbao/.oci: {oci}")
if "-config=/openbao/kms/seal.hcl" not in " ".join(server["args"]):
    fail("server args must include -config=/openbao/kms/seal.hcl")

cms = {d["metadata"]["name"]: d for d in by_kind.get("ConfigMap", [])}
cm = cms.get("openbao-kms-init")
if not cm or cm["data"].get("kms-init.sh") != SCRIPT.read_text():
    fail("ConfigMap openbao-kms-init must carry files/kms-init.sh verbatim")
if cm["metadata"].get("namespace") != "openbao":
    fail("ConfigMap openbao-kms-init must be in namespace openbao")

on = env_map(inits_on := {c["name"]: c for c in sts(render("--set", "global.ociKms.enabled=true", "--set", "global.ociKms.disabled=true")).get("initContainers")}["kms-init"])
if on.get("OCI_KMS_ENABLED") != "true" or on.get("OCI_KMS_DISABLED") != "true":
    fail("global.ociKms.enabled/disabled must flow into the init container env")

chart = yaml.safe_load((CHART / "Chart.yaml").read_text())
if "Shamir" in chart.get("description", "") and "OCI" not in chart.get("description", ""):
    fail("Chart description still says manual Shamir unseal")
print("PASS")
