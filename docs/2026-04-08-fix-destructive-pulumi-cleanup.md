# 2026-04-08: Remove Destructive Pulumi State Cleanup Step

## Overview
Removed the `Clean up old Pulumi state` step from `.github/workflows/pulumi.yml`. It was a one-time helper for the proxmoxve `v7.13.0` migration but had been silently corrupting stack state on every PR run, causing deploys to fail after merge.

## Rationale
The step exported the live shared stack, ran a `jq` filter that only kept resources whose URN contained `truenas`, `pulumi:pulumi:Stack`, or `proxmox-provider`, then re-imported the truncated state via `pulumi stack import`. After `plex-server` was added in #28, the filter started silently stripping it from state on every PR.

The deploy failure surfaced as:

```
error cloning VM: received an HTTP 500 response - Reason:
unable to create VM 200: config file already exists
```

Sequence:
1. PR #33 merged → deploy ([run 24117744890](https://github.com/Chalupa-Tech/chalupa-tech-local/actions/runs/24117744890)) successfully cloned VMID 200 and recorded `plex-server` in stack state.
2. PR #34 opened → `pulumi.yml` cleanup step stripped `plex-server` from the live stack ([run 24118119415](https://github.com/Chalupa-Tech/chalupa-tech-local/actions/runs/24118119415) logs show only `truenas-scale` survived).
3. PR #34 merged → deploy ([run 24118233736](https://github.com/Chalupa-Tech/chalupa-tech-local/actions/runs/24118233736)) tried to create `plex-server` but VMID 200 still existed in Proxmox.

The proxmoxve `v7.13.0` version-pinning side effect of the cleanup step is no longer needed — the version is already pinned in `pulumi/go.mod`.

## Changes
- **Workflow Update**: Removed the `Clean up old Pulumi state` step (and its inline pulumi CLI install) from `.github/workflows/pulumi.yml`. The `Pulumi Preview` step now runs directly after the SSH/known_hosts setup steps.

## Action Required
The orphaned VMID 200 must be destroyed manually on the Proxmox host before the next deploy can succeed. The Plex VM has never reached Stage 3 successfully and contains no Plex data:

```
qm stop 200 ; qm destroy 200 --purge
```

After that, the next merge to `main` should cleanly re-clone `plex-server` from the Fedora 43 template and record it in state. Subsequent PRs will no longer mutate the live stack.

## Pull Request
[PR #35](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/35)
