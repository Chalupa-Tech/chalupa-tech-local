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
#   PLUGIN_CACHE_DIR     optional persistent dir (data PVC subPath) caching the verified tarball
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
  # Secret values created with --from-file carry a trailing newline; a quote
  # or backslash would break the HCL string far from here (server crash-loop).
  val=$(printf '%s' "$val" | tr -d '\r\n')
  [ -n "$val" ] || die "$v is not set (secret openbao-oci-kms missing a key, or values.yaml incomplete)"
  case "$val" in *'"'* | *"\\"*) die "$v contains a quote or backslash" ;; esac
  eval "$v=\$val"
done

sha_ok() { echo "$PLUGIN_SHA256  $1" | sha256sum -c - >/dev/null 2>&1; }

url="${PLUGIN_URL:-https://github.com/openbao/openbao-plugins/releases/download/kms-oci-v${PLUGIN_VERSION}/${asset}.tar.gz}"
rm -rf "$plugin_dir"
mkdir -p "$plugin_dir"
tgz="$KMS_DIR/plugin.tgz"
# The data PVC keeps a verified copy so restarts (node reboot, drain, power
# cut) do not depend on github.com being reachable; only the first start
# after a version bump or on a rebuilt PVC downloads.
cached=""
[ -n "${PLUGIN_CACHE_DIR:-}" ] && cached="$PLUGIN_CACHE_DIR/${bin_name}_${PLUGIN_VERSION}_linux_amd64_v1.tar.gz"
if [ -n "$cached" ] && [ -f "$cached" ] && sha_ok "$cached"; then
  log "using cached plugin tarball $cached (sha256 verified)"
  cp "$cached" "$tgz"
else
  [ -n "$cached" ] && [ -f "$cached" ] && log "cached tarball $cached fails its sha256 check; re-downloading"
  log "downloading $url"
  i=0
  until wget -q -O "$tgz" "$url"; do
    i=$((i + 1)); [ "$i" -lt 5 ] || die "download failed after $i attempts: $url"
    log "download failed (attempt $i); retrying in 5s"; sleep 5
  done
  sha_ok "$tgz" || die "sha256 mismatch for $url (expected $PLUGIN_SHA256, got $(sha256sum "$tgz" | cut -d' ' -f1))"
  if [ -n "$cached" ]; then
    if mkdir -p "$PLUGIN_CACHE_DIR" && cp "$tgz" "$cached.tmp" && mv "$cached.tmp" "$cached"; then
      log "cached verified tarball at $cached"
    else
      log "warning: could not write the plugin cache at $cached (continuing without cache)"
    fi
  fi
fi
tar xzf "$tgz" -C "$plugin_dir" "$asset"
mv "$plugin_dir/$asset" "$plugin_dir/$bin_name"
chmod 0755 "$plugin_dir/$bin_name"
rm -f "$tgz"

disabled_line=""
[ "${OCI_KMS_DISABLED:-false}" = true ] && disabled_line='  disabled = "true"'
# shellcheck disable=SC2154  # key_id and the endpoints arrive via envFrom the secret
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
