# 2026-04-09: Fix Plex VM Cloud-Init SSH Key Mismatch

## Overview
Stage 3 (`VM Software Config`) of the deploy pipeline failed again in run [24168602709](https://github.com/Chalupa-Tech/chalupa-tech-local/actions/runs/24168602709) with `Permission denied (publickey)` when Ansible tried to SSH as `fedora@192.168.1.224`. Unlike the previous gather_facts race (PR #36), this was not a timing problem — the runner's key was never on the VM in the first place.

## Rationale
`pulumi/plex.go:70` hardcoded a single public key in the cloud-init `UserAccount.Keys` list:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINvR9jYqq/EEuoMyJEloxILC6XfNAGHwoaMP4fMNk7ca
```

That key is the maintainer's personal MacBook key (`tbigelow@Mac`), not the CI runner key. GitHub Actions authenticates with the `PROXMOX_SSH_KEY` secret, which is the `pulumi_proxmox_runner` keypair — its public half is:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII8mSi1hjt/MpS6JtS06rwI1pWHMF9hBet6rKHADCiUp
```

Stage 1 (Proxmox host prep) always worked because `root@pve1`'s `authorized_keys` contains both public keys. But on the Plex VM, cloud-init's `users-groups` module only injected the personal key, so the runner had no matching key on the VM and sshd rejected it.

This had been masked by every previous Stage 3 failure — #34, #36, etc. — because Stage 3 was never actually getting past earlier blockers to hit the real SSH auth step cleanly.

### Why updating `plex.go` alone didn't fix the live VM
Cloud-init's `users-groups` module runs once per instance by default. Stage 2 of the failing run showed the Plex VM was `~disks`-updated, not recreated, so regenerating the cloud-init drive would not have re-injected keys on the existing VM. The live VM was unblocked with a one-time manual bootstrap:

```bash
ssh -i ~/.ssh/ssh_key fedora@192.168.1.224 \
  "echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII8mSi1hjt/MpS6JtS06rwI1pWHMF9hBet6rKHADCiUp pulumi_proxmox_runner' >> ~/.ssh/authorized_keys"
```

After that, Stage 3 of the next deploy ran to completion. This PR ensures any future VM recreation boots with the correct key set from the start, so the manual bootstrap never has to be repeated.

## Changes
- **Pulumi**: `pulumi/plex.go` — added the CI runner public key as a second entry in the Plex VM cloud-init `UserAccount.Keys` array, with comments explaining the purpose of each key. Personal key left in place so manual SSH from the maintainer's Mac continues to work.

## Pull Request
[PR #37](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/37)
