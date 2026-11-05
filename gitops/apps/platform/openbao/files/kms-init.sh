#!/bin/sh
# Init container for the OpenBao server pods: installs the pinned OCI KMS
# seal plugin (an external KMS plugin since OpenBao 2.6 — the binary does
# not ship with it) and writes the seal configuration the server loads via
# `-config=$KMS_DIR/seal.hcl` (chart value server.extraArgs).
#
# Env (set by values.yaml / the openbao-oci-kms secret):
#   OCI_KMS_ENABLED      true|false  false = write a comment-only seal.hcl, touch nothing else
#   OCI_KMS_DISABLED     true|false  true  = add `disabled = "true"` (migration back to Shamir)
#   PLUGIN_VERSION       e.g. 0.1.1  (release tag kms-oci-v<version> of openbao/openbao-plugins)
#   PLUGIN_SHA256        sha256 of openbao-plugin-kms-oci_linux_amd64_v1.tar.gz
#   PLUGIN_URL           optional override of the download URL (tests, mirrors)
#   KMS_DIR              emptyDir shared with the server (default /openbao/kms)
#   key_id, crypto_endpoint, management_endpoint   from the secret (envFrom)
#
# Runs with the server image (Alpine: wget, sha256sum, tar) as the openbao
# user. Any failure exits non-zero so the pod stays in Init instead of
# starting a server with a half-configured seal.
set -eu

KMS_DIR="${KMS_DIR:-/openbao/kms}"
plugin_dir="$KMS_DIR/plugins"
hcl="$KMS_DIR/seal.hcl"
bin_name=openbao-plugin-kms-oci
asset="${bin_name}_linux_amd64_v1"

log() { printf '[kms-init] %s\n' "$*"; }
die() { printf '[kms-init] ERROR: %s\n' "$*" >&2; exit 1; }

if [ "${OCI_KMS_ENABLED:-false}" != true ]; then
  mkdir -p "$KMS_DIR"
  printf '# ociKms.enabled is false: no seal stanza (Shamir / manual unseal).\n' > "$hcl"
  log "OCI KMS seal disabled; wrote empty $hcl"
  exit 0
fi

for v in PLUGIN_VERSION PLUGIN_SHA256 key_id crypto_endpoint management_endpoint; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || die "$v is not set (secret openbao-oci-kms missing a key, or values.yaml incomplete)"
done

url="${PLUGIN_URL:-https://github.com/openbao/openbao-plugins/releases/download/kms-oci-v${PLUGIN_VERSION}/${asset}.tar.gz}"
rm -rf "$plugin_dir"
mkdir -p "$plugin_dir"
tgz="$KMS_DIR/plugin.tgz"
log "downloading $url"
i=0
until wget -q -O "$tgz" "$url"; do
  i=$((i + 1)); [ "$i" -lt 5 ] || die "download failed after $i attempts: $url"
  log "download failed (attempt $i); retrying in 5s"; sleep 5
done
echo "$PLUGIN_SHA256  $tgz" | sha256sum -c - >/dev/null 2>&1 || die "sha256 mismatch for $url (expected $PLUGIN_SHA256, got $(sha256sum "$tgz" | cut -d' ' -f1))"
tar xzf "$tgz" -C "$plugin_dir" "$asset"
mv "$plugin_dir/$asset" "$plugin_dir/$bin_name"
chmod 0755 "$plugin_dir/$bin_name"
rm -f "$tgz"

disabled_line=""
[ "${OCI_KMS_DISABLED:-false}" = true ] && disabled_line='  disabled = "true"'
# shellcheck disable=SC2154  # key_id cat > "$hcl" <<HCL co. arrive via envFrom the secret
cat > "$hcl" <<HCL
# Written by kms-init (files/kms-init.sh); do not edit in the pod.
plugin_directory = "$plugin_dir"

plugin "kms" "ocikms" {
  command = "$bin_name"
  version = "v${PLUGIN_VERSION}"
}

seal "ocikms" {
  key_id              = "$key_id"
  crypto_endpoint     = "$crypto_endpoint"
  management_endpoint = "$management_endpoint"
  auth_type_api_key   = "true"
$disabled_line
}
HCL
log "installed $bin_name v${PLUGIN_VERSION}; seal config at $hcl${disabled_line:+ (seal DISABLED: migration mode)}"
