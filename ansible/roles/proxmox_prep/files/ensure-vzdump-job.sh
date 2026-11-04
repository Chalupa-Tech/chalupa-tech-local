#!/usr/bin/env bash
# Declaratively manage one Proxmox vzdump job via `pvesh`, idempotently.
#
#   ensure-vzdump-job.sh --id <jobid> --schedule <s> --vmids <csv> \
#       --storage <name> --prune <keep-spec> [--delete-id <legacy-id>]... [--check]
#
# Prints CHANGED or UNCHANGED as the last line; --check reports without
# mutating (used by `ansible-playbook --check`). Fixed job settings: snapshot
# mode, zstd, enabled, notification-system, notes {{guestname}}.
set -euo pipefail

id="" schedule="" vmids="" storage="" prune="" check=0
delete_ids=()
while [ $# -gt 0 ]; do
  case "$1" in
    --id) id=$2; shift 2 ;;
    --schedule) schedule=$2; shift 2 ;;
    --vmids) vmids=$2; shift 2 ;;
    --storage) storage=$2; shift 2 ;;
    --prune) prune=$2; shift 2 ;;
    --delete-id) delete_ids+=("$2"); shift 2 ;;
    --check) check=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
for v in id schedule vmids storage prune; do
  [ -n "${!v}" ] || { echo "--${v} is required" >&2; exit 2; }
done

jobs=$(pvesh get /cluster/backup --output-format json)
changed=0

run() { if [ "$check" -eq 1 ]; then return 0; fi; pvesh "$@"; }

# 1. Remove legacy jobs (e.g. the one pointing at a storage that never existed).
for legacy in "${delete_ids[@]:-}"; do
  [ -n "$legacy" ] || continue
  if jq -e --arg id "$legacy" 'map(select(.id == $id)) | length > 0' <<<"$jobs" >/dev/null; then
    run delete "/cluster/backup/$legacy"
    changed=1
  fi
done

# 2. Desired state, normalised for comparison: vmid as a sorted set, prune as
#    a sorted "k=v,k=v" string.
norm_vmids() { tr ',' '\n' <<<"$1" | sed '/^$/d' | sort -n | paste -sd, -; }
norm_prune_str() { tr ',' '\n' <<<"$1" | sed '/^$/d' | sort | paste -sd, -; }
want_vmids=$(norm_vmids "$vmids")
want_prune=$(norm_prune_str "$prune")

current=$(jq -c --arg id "$id" 'map(select(.id == $id)) | .[0] // empty' <<<"$jobs")
fixed_args=(--mode snapshot --compress zstd --enabled 1 --notification-mode notification-system --notes-template '{{guestname}}')
set_args=(--schedule "$schedule" --vmid "$want_vmids" --storage "$storage" --prune-backups "$prune" "${fixed_args[@]}")

if [ -z "$current" ]; then
  run create /cluster/backup --id "$id" "${set_args[@]}"
  changed=1
else
  have_vmids=$(norm_vmids "$(jq -r '.vmid // ""' <<<"$current")")
  have_prune=$(norm_prune_str "$(jq -r '(.["prune-backups"] // {}) | to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$current")")
  have_schedule=$(jq -r '.schedule // ""' <<<"$current")
  have_storage=$(jq -r '.storage // ""' <<<"$current")
  have_mode=$(jq -r '.mode // ""' <<<"$current")
  have_compress=$(jq -r '.compress // ""' <<<"$current")
  have_enabled=$(jq -r '.enabled // 0' <<<"$current")
  if [ "$have_vmids" != "$want_vmids" ] || [ "$have_prune" != "$want_prune" ] \
     || [ "$have_schedule" != "$schedule" ] || [ "$have_storage" != "$storage" ] \
     || [ "$have_mode" != snapshot ] || [ "$have_compress" != zstd ] || [ "$have_enabled" != 1 ]; then
    run set "/cluster/backup/$id" "${set_args[@]}"
    changed=1
  fi
fi

if [ "$changed" -eq 1 ]; then echo CHANGED; else echo UNCHANGED; fi
