#!/usr/bin/env bash
# Restore drill: prove the newest vzdump archives are actually restorable.
#
# Runs ON pve1 as root (the restore-drill workflow copies it there):
#   restore-drill.sh [--vm <src>:<scratch>]... [--ct <src>:<scratch>]... [--verify-only <csv>]
# Defaults: --vm 250:9250 --ct 200:9200 --verify-only 101,100
#
# For each --vm/--ct pair the newest archive of <src> (searched across every
# storage that holds backups) is restored to the scratch VMID on local-lvm
# (never started), its config is checked for a disk, and it is destroyed —
# also on failure, via the EXIT trap. --verify-only archives only get a
# `zstd -t` integrity pass (TrueNAS has an HBA passed through and the
# Tailscale LXC is tiny; restoring them teaches nothing extra).
#
# Scratch VMIDs are the ONLY VMIDs this script ever destroys, and it refuses
# to start if one of them already exists. Any failure exits non-zero and no
# success metric is written.
set -euo pipefail

metrics_file="${DRILL_METRICS_FILE:-/var/lib/prometheus/node-exporter/restore-drill.prom}"
vm_pairs=() ct_pairs=() verify_only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --vm) vm_pairs+=("$2"); shift 2 ;;
    --ct) ct_pairs+=("$2"); shift 2 ;;
    --verify-only) verify_only=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ ${#vm_pairs[@]} -gt 0 ] || vm_pairs=(250:9250)
[ ${#ct_pairs[@]} -gt 0 ] || ct_pairs=(200:9200)
[ -n "$verify_only" ] || verify_only="101,100"

failures=0
log() { printf '[drill] %s\n' "$*"; }
err() { printf '[drill] ERROR: %s\n' "$*" >&2; failures=$((failures + 1)); }

# Scratch guests created in this run; destroyed by the trap no matter what.
created_vms=() created_cts=()
cleanup() {
  for id in "${created_vms[@]:-}"; do [ -n "$id" ] && { qm destroy "$id" --purge 1 || err "could not destroy scratch VM $id"; }; done
  for id in "${created_cts[@]:-}"; do [ -n "$id" ] && { pct destroy "$id" --purge 1 || err "could not destroy scratch CT $id"; }; done
  created_vms=() created_cts=()
}
trap cleanup EXIT

backup_storages() { pvesm status --content backup | awk 'NR > 1 {print $1}'; }

# newest_archive <vmid> -> prints the newest volid across all backup storages
newest_archive() {
  local vmid=$1 s
  for s in $(backup_storages); do
    pvesm list "$s" --vmid "$vmid" --content backup | awk 'NR > 1 {print $1}'
  done | awk -F/ '{print $NF " " $0}' | sort | tail -n 1 | cut -d' ' -f2-
}

# Pre-flight: refuse to touch a scratch VMID that exists.
for pair in "${vm_pairs[@]}"; do
  if qm status "${pair#*:}" >/dev/null 2>&1; then echo "[drill] ERROR: scratch VM ${pair#*:} already exists; refusing" >&2; exit 1; fi
done
for pair in "${ct_pairs[@]}"; do
  if pct status "${pair#*:}" >/dev/null 2>&1; then echo "[drill] ERROR: scratch CT ${pair#*:} already exists; refusing" >&2; exit 1; fi
done

for pair in "${vm_pairs[@]}"; do
  src=${pair%%:*}; scratch=${pair#*:}
  volid=$(newest_archive "$src")
  if [ -z "$volid" ]; then err "no backup archive found for VM $src"; continue; fi
  log "VM $src: restoring $volid to scratch $scratch"
  if ! qmrestore "$volid" "$scratch" --storage local-lvm --unique 1; then err "qmrestore of $volid failed"; created_vms+=("$scratch"); continue; fi
  created_vms+=("$scratch")
  # Make the clone inert immediately: no autostart, no startup order, no NIC.
  # If a later destroy fails, a lingering scratch guest must never boot with
  # the source's IP/hostname on the next host reboot.
  qm set "$scratch" --onboot 0 --delete startup,net0 || err "VM $src: could not neutralise scratch $scratch"
  if qm config "$scratch" | grep -qE '^(scsi|virtio|sata|ide)[0-9]+: .*(local-lvm|vm-)'; then
    log "VM $src: restored config has a disk — OK"
  else
    err "VM $src: restored config has no disk"
  fi
  cleanup
done

for pair in "${ct_pairs[@]}"; do
  src=${pair%%:*}; scratch=${pair#*:}
  volid=$(newest_archive "$src")
  if [ -z "$volid" ]; then err "no backup archive found for CT $src"; continue; fi
  log "CT $src: restoring $volid to scratch $scratch"
  if ! pct restore "$scratch" "$volid" --storage local-lvm --unique 1; then err "pct restore of $volid failed"; created_cts+=("$scratch"); continue; fi
  created_cts+=("$scratch")
  # Same neutralisation as for VMs; the Plex LXC has eth0 (static .224) and
  # the storage-subnet eth1.
  pct set "$scratch" --onboot 0 --delete startup,net0,net1 || err "CT $src: could not neutralise scratch $scratch"
  if pct config "$scratch" | grep -qE '^rootfs: '; then
    log "CT $src: restored config has rootfs — OK"
  else
    err "CT $src: restored config has no rootfs"
  fi
  cleanup
done

for vmid in ${verify_only//,/ }; do
  volid=$(newest_archive "$vmid")
  if [ -z "$volid" ]; then err "no backup archive found for guest $vmid"; continue; fi
  path=$(pvesm path "$volid")
  if zstd -t "$path"; then log "guest $vmid: $volid integrity OK"; else err "guest $vmid: $volid failed zstd -t"; fi
done

if [ "$failures" -ne 0 ]; then
  echo "[drill] FAILED with $failures error(s)" >&2
  exit 1
fi

dir=$(dirname "$metrics_file"); mkdir -p "$dir"
tmp=$(mktemp "$dir/.restore-drill.prom.XXXXXX")
{
  echo "# HELP pve_restore_drill_last_success_timestamp Unix time of the last fully successful restore drill."
  echo "# TYPE pve_restore_drill_last_success_timestamp gauge"
  echo "pve_restore_drill_last_success_timestamp $(date +%s)"
} > "$tmp"
chmod 0644 "$tmp"; mv -f "$tmp" "$metrics_file"
log "all checks passed"
