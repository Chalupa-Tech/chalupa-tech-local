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
- **Workflow Update (Pulumi)**: Removed the `Clean up old Pulumi state` step (and its inline pulumi CLI install) from `.github/workflows/pulumi.yml`. The `Pulumi Preview` step now runs directly after the SSH/known_hosts setup steps.
- **Workflow Update (Ansible)**: Hardened the `Add Proxmox to known_hosts` step in `.github/workflows/ansible.yml`. The previous version invoked `ssh-keyscan` three times back-to-back (against the IP, the `proxmox` alias, and the `pve1` alias — all the same host). Proxmox sshd was rate-limiting/dropping the second batch with `Connection closed by remote host`, causing the step to exit non-zero. Since `inventory.yml` uses `ansible_host: 192.168.1.223`, only the IP entry is needed. The step now scans only the IP and retries up to 3 times with a 5s backoff. Run [24166803727](https://github.com/Chalupa-Tech/chalupa-tech-local/actions/runs/24166803727) was the first observed failure of this kind. The same flaky pattern still exists in `pulumi.yml` and `deploy.yml` and may need similar treatment in a follow-up.
- **Pulumi Code Update**: Pinned the `proxmoxve` provider plugin to `7.13.0` via `pulumi.Version("7.13.0")` in `pulumi/main.go`. The `muhlba91/pulumi-proxmoxve/sdk/v7@v7.13.0` Go SDK ships with `internal.SdkVersion` as the zero value (`semver.Version{}`), so the SDK's `PkgResourceDefaultOpts` helper never appends a version to resource options (`pulumiUtilities.go:165-173`). Without an explicit pin, Pulumi resolves the **latest** plugin in the registry — currently `v8.x` — which uses different resource type tokens than v7 and breaks every existing resource in state with `Resource type 'proxmoxve:VM/virtualMachine:VirtualMachine' not found`. The removed cleanup step had been masking this by force-writing `inputs.version = "7.13.0"` onto the provider in state via `jq`. Run [24167053794](https://github.com/Chalupa-Tech/chalupa-tech-local/actions/runs/24167053794) surfaced the underlying SDK bug. Resources that use this provider via `pulumi.Provider(pveProvider)` inherit the pinned version.

## Action Required
The orphaned VMID 200 must be destroyed manually on the Proxmox host before the next deploy can succeed. The Plex VM has never reached Stage 3 successfully and contains no Plex data:

```
qm stop 200 ; qm destroy 200 --purge
```

After that, the next merge to `main` should cleanly re-clone `plex-server` from the Fedora 43 template and record it in state. Subsequent PRs will no longer mutate the live stack.

## Pull Request
[PR #35](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/35)
