#!/usr/bin/env bash
# Renders the unattended_upgrades templates for two profiles (Proxmox host,
# Ubuntu LXC) via a local play and asserts the lines that matter.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

render() { # <profile> <outdir>
  mkdir -p "$2"
  ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    ansible-playbook -i localhost, -c local "$here/render.yml" \
      -e "out_dir=$2" -e "template_dir=$here/../templates" -e "@$here/profile_$1.yml" >"$2/play.log" 2>&1 \
    || { cat "$2/play.log"; fail "render $1: playbook failed"; }
}

render host "$tmp/host"
render lxc "$tmp/lxc"
host="$tmp/host/50unattended-upgrades"; lxc="$tmp/lxc/50unattended-upgrades"

host_profile_has_no_autoreboot() {
  grep -q '^Unattended-Upgrade::Automatic-Reboot "false";$' "$host" || fail "host: Automatic-Reboot must be false"
  grep -q '^Unattended-Upgrade::Remove-Unused-Dependencies "false";$' "$host" || fail "host: Remove-Unused-Dependencies must be false"
}
host_profile_origins() {
  grep -q '"origin=Debian,codename=${distro_codename}-security,label=Debian-Security";' "$host" || fail "host: Debian security origin missing"
  grep -q '"origin=Debian,codename=${distro_codename}-updates";' "$host" || fail "host: Debian updates origin missing"
  grep -q '"origin=Proxmox,codename=${distro_codename},label=Proxmox Debian Repository";' "$host" || fail "host: Proxmox origin missing"
  ! grep -q 'origin=Ubuntu' "$host" || fail "host: Ubuntu origin must not be present"
}
lxc_profile_reboots_at_time() {
  grep -q '^Unattended-Upgrade::Automatic-Reboot "true";$' "$lxc" || fail "lxc: Automatic-Reboot must be true"
  grep -q '^Unattended-Upgrade::Automatic-Reboot-Time "04:30";$' "$lxc" || fail "lxc: reboot time 04:30 missing"
}
lxc_profile_origins() {
  grep -q '"origin=Ubuntu,codename=${distro_codename}-security,label=Ubuntu";' "$lxc" || fail "lxc: Ubuntu security origin missing"
  grep -q '"origin=Plex Media Server Repository";' "$lxc" || fail "lxc: Plex origin missing"
  grep -q '"origin=Tailscale";' "$lxc" || fail "lxc: Tailscale origin missing"
}
periodic_file() {
  for f in "$tmp/host/20auto-upgrades" "$tmp/lxc/20auto-upgrades"; do
    grep -q '^APT::Periodic::Update-Package-Lists "1";$' "$f" || fail "periodic: Update-Package-Lists"
    grep -q '^APT::Periodic::Unattended-Upgrade "1";$' "$f" || fail "periodic: Unattended-Upgrade"
    grep -q '^APT::Periodic::AutocleanInterval "7";$' "$f" || fail "periodic: AutocleanInterval"
  done
}
origins_block_is_well_formed() {
  grep -q '^Unattended-Upgrade::Origins-Pattern {$' "$host" || fail "origins block open"
  grep -q '^};$' "$host" || fail "origins block close"
}

for t in host_profile_has_no_autoreboot host_profile_origins lxc_profile_reboots_at_time lxc_profile_origins periodic_file origins_block_is_well_formed; do
  "$t"; echo "ok $t"
done
echo PASS
