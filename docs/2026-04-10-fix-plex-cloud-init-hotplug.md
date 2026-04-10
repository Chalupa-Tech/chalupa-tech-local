# 2026-04-10: Ignore Cloud-Init Drift on Existing Plex VM

## Overview
After PR #37 added the CI runner SSH key to `pulumi/plex.go`, the next deploy ([run 24222515326](https://github.com/Chalupa-Tech/chalupa-tech-local/actions/runs/24222515326)) failed in Stage 2 with an HTTP 400 from Proxmox:

```
error updating VM: received an HTTP 400 response
Reason: Parameter verification failed. (ide2: hotplug problem - unable to change media type)
```

The Plex VM diff was `[diff: ~disks,initialization]`. The `initialization` change was the new key added in PR #37, which the provider tried to push by swapping the cloud-init ISO at `ide2`. Proxmox does not allow media-type changes on a running VM, so the update aborted before Stage 3 could even start.

## Rationale
This is a semantic mismatch between how Pulumi treats cloud-init and how cloud-init actually behaves.

- **Pulumi's view.** `initialization.UserAccount.Keys` is a desired-state field. Any diff should be reconciled by rewriting the cloud-init drive on the VM.
- **Cloud-init's reality.** The `users-groups` module is `per-instance` by default — it runs once, on first boot, and never again for the life of that instance. Rewriting the cloud-init ISO on an already-booted VM would have no effect on `~fedora/.ssh/authorized_keys`.

So even if Proxmox *did* allow the hotplug, the key injection would still not happen on the existing Plex VM. This is exactly why PR #37 had to be accompanied by a one-time manual bootstrap to append the runner key directly to `~fedora/.ssh/authorized_keys` — and why that bootstrap worked.

The right model is to treat `initialization` as *create-time only*: apply the full spec when the VM is first provisioned, then leave it alone. Pulumi supports this with `IgnoreChanges` — the list only affects updates, not create, so a future VM recreation (e.g. from a fresh template clone) will still boot with both SSH keys in its cloud-init config.

### Why not just shut down the VM and retry?
- Disruptive: Plex serves media 24/7, shutdown/boot cycles on every deploy are a non-starter.
- Doesn't solve the underlying semantic problem: even after a reboot, cloud-init still wouldn't re-run `users-groups` on the same instance.
- Adds a coupling between Pulumi runs and VM availability that we don't want.

### Why not ignore `disks` as well?
The `disks` diff has been showing up on every run for both VMs (see `[diff: ~disks]` in the truenas line of the same run log) and the provider successfully no-ops it. That is a separate cosmetic issue and is out of scope for this fix. This PR intentionally changes the minimum needed to unblock deploys.

## Changes
- **Pulumi**: `pulumi/plex.go` — added `"initialization"` to the Plex VM's `pulumi.IgnoreChanges` list, alongside the existing `"started"` entry. Added a code comment explaining the semantic (cloud-init is first-boot-only, spec still applies on Create).

## Pull Request
[PR #38](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/38)
