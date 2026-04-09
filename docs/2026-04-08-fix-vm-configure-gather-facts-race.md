# 2026-04-08: Fix Stage 3 SSH Race By Disabling Implicit gather_facts

## Overview
After PR #35 unblocked Stages 1 and 2 of the deploy pipeline, Stage 3 (`VM Software Config`) started reaching the freshly-cloned Plex VM for the first time and immediately failed with `Permission denied (publickey)`. The cause was an implicit `gather_facts` race against cloud-init key injection.

## Rationale
The `vm-configure.yml` play did not set `gather_facts: false`, so Ansible's implicit fact-gathering task ran *before* any role task. The `plex_server` role's `tasks/main.yml:5` already starts with `wait_for_connection`, followed by an explicit `setup` task on `tasks/main.yml:13` — exactly the right shape for waiting on a freshly-cloned VM — but the implicit fact gathering never gave that pattern a chance to run.

Timeline from the failing run [24167845068](https://github.com/Chalupa-Tech/chalupa-tech-local/actions/runs/24167845068):

```
01:40:48.87  step started
01:40:49.69  PLAY [Configure Plex Media Server VM]
01:40:50.27  fatal: [plex]: UNREACHABLE
             Permission denied (publickey,gssapi-keyex,gssapi-with-mic)
```

The VM had been cloned ~3 minutes earlier in Stage 2, but cloud-init was almost certainly still finishing its first-boot work — Fedora cloud-init typically takes 30–90 seconds to inject SSH keys. Hitting SSH 1.4 seconds into the play was guaranteed to fail. The `fedora` user existed but its `~/.ssh/authorized_keys` had not been written yet, so sshd had no key to match against the runner's `secrets.PROXMOX_SSH_KEY`.

The cloud-init public key in `pulumi/plex.go:70` and the role default `plex_server_ssh_key` in `ansible/roles/plex_server/defaults/main.yml:8` are byte-identical, so the key wiring is correct end-to-end. The bug is purely a timing/play-structure issue.

## Changes
- **Playbook Update**: Added `gather_facts: false` to the play in `ansible/playbooks/vm-configure.yml`. The `plex_server` role's existing `wait_for_connection` → explicit `setup` sequence now actually runs in order, so Ansible waits for cloud-init to finish before attempting any SSH-dependent task.

## Pull Request
[PR #36](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/36)
