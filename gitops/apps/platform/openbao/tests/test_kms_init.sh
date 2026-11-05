#!/usr/bin/env bash
# Unit tests for files/kms-init.sh (the OCI KMS seal plugin init container)
# with a stubbed `wget`. The stub copies a fixture tarball built here and
# logs the URL it was asked for; STUB_WGET_FAIL=1 makes it fail like a
# network error.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../files/kms-init.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/fixture"
export CALL_LOG="$tmp/calls.log"

# Fixture tarball shaped like the real release asset: LICENSE + the binary.
printf '#!/bin/sh\necho stub-plugin\n' > "$tmp/fixture/openbao-plugin-kms-oci_linux_amd64_v1"
echo "MPL-2.0" > "$tmp/fixture/LICENSE"
tar czf "$tmp/plugin.tgz" -C "$tmp/fixture" LICENSE openbao-plugin-kms-oci_linux_amd64_v1
if command -v sha256sum >/dev/null; then good_sha=$(sha256sum "$tmp/plugin.tgz" | cut -d' ' -f1)
else good_sha=$(shasum -a 256 "$tmp/plugin.tgz" | cut -d' ' -f1)
  printf '#!/usr/bin/env bash\nexec shasum -a 256 "$@"\n' > "$tmp/bin/sha256sum"; chmod +x "$tmp/bin/sha256sum"; fi
export STUB_TARBALL="$tmp/plugin.tgz"
cat > "$tmp/bin/wget" <<'STUB'
#!/usr/bin/env bash
printf 'wget %s\n' "$*" >> "$CALL_LOG"
[ "${STUB_WGET_FAIL:-0}" = 1 ] && { echo "stub: network down" >&2; exit 4; }
out=""; while [ $# -gt 0 ]; do case "$1" in -O) out=$2; shift 2 ;; -qO) out=$2; shift 2 ;; *) shift ;; esac; done
cp "$STUB_TARBALL" "$out"
STUB
chmod +x "$tmp/bin/wget"
export PATH="$tmp/bin:$PATH"

fail() { echo "FAIL: $1"; exit 1; }
reset() {
  : > "$CALL_LOG"; rm -rf "$tmp/kms"; mkdir -p "$tmp/kms"
  export KMS_DIR="$tmp/kms" PLUGIN_VERSION=0.1.1 PLUGIN_SHA256="$good_sha" OCI_KMS_ENABLED=true OCI_KMS_DISABLED=false
  export key_id=ocid1.key.oc1..aaa crypto_endpoint=https://crypto.example management_endpoint=https://mgmt.example
  unset STUB_WGET_FAIL PLUGIN_URL
}
run() { sh "$script" > "$tmp/out" 2>&1; }
bin="$tmp/kms/plugins/openbao-plugin-kms-oci"
hcl="$tmp/kms/seal.hcl"

disabled_writes_empty_config_without_network() {
  reset; export OCI_KMS_ENABLED=false
  run || fail "disabled: rc $?"
  [ -f "$hcl" ] || fail "disabled: seal.hcl missing"
  ! grep -q '^seal ' "$hcl" || fail "disabled: seal stanza present"
  ! grep -q '^plugin ' "$hcl" || fail "disabled: plugin stanza present"
  [ ! -s "$CALL_LOG" ] || fail "disabled: wget called: $(cat "$CALL_LOG")"
  [ ! -e "$bin" ] || fail "disabled: binary installed"
}
enabled_installs_plugin_and_writes_seal() {
  reset
  run || fail "enabled: rc $? $(cat "$tmp/out")"
  [ -x "$bin" ] || fail "enabled: binary missing or not executable"
  [ "$($bin)" = stub-plugin ] || fail "enabled: binary content"
  grep -q 'github.com/openbao/openbao-plugins/releases/download/kms-oci-v0.1.1/openbao-plugin-kms-oci_linux_amd64_v1.tar.gz' "$CALL_LOG" || fail "enabled: url: $(cat "$CALL_LOG")"
  grep -q "^plugin_directory = \"$tmp/kms/plugins\"" "$hcl" || fail "enabled: plugin_directory"
  grep -q '^plugin "kms" "ocikms"' "$hcl" || fail "enabled: plugin stanza"
  grep -q 'command = "openbao-plugin-kms-oci"' "$hcl" || fail "enabled: command"
  grep -q 'version = "v0.1.1"' "$hcl" || fail "enabled: version"
  grep -q '^seal "ocikms"' "$hcl" || fail "enabled: seal stanza"
  grep -q 'key_id *= "ocid1.key.oc1..aaa"' "$hcl" || fail "enabled: key_id"
  grep -q 'crypto_endpoint *= "https://crypto.example"' "$hcl" || fail "enabled: crypto_endpoint"
  grep -q 'management_endpoint *= "https://mgmt.example"' "$hcl" || fail "enabled: management_endpoint"
  grep -q 'auth_type_api_key *= "true"' "$hcl" || fail "enabled: auth_type_api_key"
  ! grep -q 'disabled' "$hcl" || fail "enabled: disabled present"
  [ ! -e "$tmp/kms/plugin.tgz" ] || fail "enabled: tarball left behind"
}
bad_sha_fails_and_installs_nothing() {
  reset; zeros=$(printf "0%.0s" $(seq 64)); export PLUGIN_SHA256=$zeros
  rc=0; run || rc=$?; [ $rc -ne 0 ] || fail "bad_sha: rc 0"
  [ ! -e "$bin" ] || fail "bad_sha: binary installed"
  grep -qi 'sha256' "$tmp/out" || fail "bad_sha: message: $(cat "$tmp/out")"
}
missing_seal_values_fail_before_download() {
  reset; unset key_id
  rc=0; run || rc=$?; [ $rc -ne 0 ] || fail "missing: rc 0"
  [ ! -s "$CALL_LOG" ] || fail "missing: downloaded anyway"
  grep -q 'key_id' "$tmp/out" || fail "missing: message: $(cat "$tmp/out")"
}
download_failure_fails() {
  reset; export STUB_WGET_FAIL=1
  rc=0; run || rc=$?; [ $rc -ne 0 ] || fail "download: rc 0"
  [ ! -e "$bin" ] || fail "download: binary installed"
}
disabled_flag_writes_disabled_seal() {
  reset; export OCI_KMS_DISABLED=true
  run || fail "flag: rc $?"
  grep -q 'disabled = "true"' "$hcl" || fail "flag: disabled line missing"
  grep -q '^seal "ocikms"' "$hcl" || fail "flag: seal stanza missing"
}
plugin_url_override_is_used() {
  reset; export PLUGIN_URL=https://mirror.example/plugin.tgz
  run || fail "override: rc $?"
  grep -q 'https://mirror.example/plugin.tgz' "$CALL_LOG" || fail "override: url: $(cat "$CALL_LOG")"
}

for t in disabled_writes_empty_config_without_network enabled_installs_plugin_and_writes_seal bad_sha_fails_and_installs_nothing missing_seal_values_fail_before_download download_failure_fails disabled_flag_writes_disabled_seal plugin_url_override_is_used; do
  $t; echo "ok $t"
done
echo PASS
