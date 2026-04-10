# 2026-04-10: Fix Two Stage 3 Blockers on Plex VM

## Overview
With [PR #38](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/38) unblocking Stage 2, the deploy pipeline reached Stage 3 for the first time with a working SSH key and no cloud-init drift. Stage 3 of [run 24222973220](https://github.com/Chalupa-Tech/chalupa-tech-local/actions/runs/24222973220) then failed on the `Create Plex media mount points` task:

```
TASK [plex_server : Create Plex media mount points]
changed: [plex] => (item={'src': '/mnt/PlexMedia/Movies', 'dest': '/mnt/plex/movies'})
[ERROR]: Task failed: Module failed: [Errno 1] Operation not permitted: b'/mnt/plex/tvshows'
```

Live state on the Plex VM (from a manual SSH investigation):

```
$ findmnt /mnt/plex/tvshows
TARGET            SOURCE                              FSTYPE OPTIONS
/mnt/plex/tvshows 192.168.1.40:/mnt/PlexMedia/TVShows nfs4   rw,relatime,...

$ stat /mnt/plex/movies  /mnt/plex/tvshows
Access: (0755/drwxr-xr-x)  ...  /mnt/plex/movies
Access: (0757/drwxr-xrwx)  ...  /mnt/plex/tvshows
```

Both paths are already active NFS mounts onto the TrueNAS shares. `movies` happens to already be `0755` so Ansible's chmod was a no-op; `tvshows` is `0757`, so `ansible.builtin.file` tried to chmod it — and the chmod passed through to the NFS share root on TrueNAS, which rejected it (`EPERM`). Hence `Operation not permitted`.

Once that was fixed, inspection of the VM showed a second blocker waiting:

```
$ sudo firewall-cmd --list-ports
sudo: firewall-cmd: command not found
```

Fedora cloud images don't ship firewalld. The role's `Open Plex port in firewalld` task uses `ansible.posix.firewalld`, which requires `firewall-cmd`. This would have been the *next* failure even after the mount-point fix landed. Bundling both fixes into one PR avoids a pointless extra iteration.

## Rationale

### Mount point mode
The `Create Plex media mount points` task's job is to create an empty directory so an NFS mount can be attached to it. Once the mount is live, the mode on the *mount point* is invisible — what callers see is the NFS share's mode on the server. Enforcing `mode: "0755"` there has two problems:

1. **Semantically wrong.** The local inode mode is never observed once a mount is overlaid.
2. **Actively breaks on re-runs.** Ansible chmods through to the NFS share root, which the server refuses, failing the play.

The fix is to drop `mode` from the task so `ansible.builtin.file` only ensures the directory exists. On first run the dir is created with root's umask (`0755`), which is what we wanted anyway. On re-runs over an active mount, the module is a pure no-op. The task is tagged `# noqa: risky-file-permissions` — normally dropping `mode` is worth flagging, but a soon-to-be-overlaid NFS mountpoint is exactly the case where it's correct.

### firewalld install
Fedora cloud images are minimal and do not include firewalld. `ansible.posix.firewalld` talks to `firewall-cmd`, so without the package the task can't even start. This mirrors the existing pattern in the same role — `nfs-utils` is installed before the mount tasks, and now `firewalld` is installed before the firewall task.

`systemd: enabled: true, state: started` runs in the same block so that `ansible.posix.firewalld`'s `immediate: true` can take effect in the running daemon. The Fedora default zone already permits SSH (`services: ssh dhcpv6-client mdns samba-client`), so starting firewalld mid-play will not lock the runner out.

## Changes
- **Ansible role** `ansible/roles/plex_server/tasks/main.yml`:
  - Removed `mode: "0755"` from `Create Plex media mount points` and added `# noqa: risky-file-permissions` plus an explanatory comment block.
  - Added two new tasks before `Open Plex port in firewalld`: `Install firewalld` (via dnf) and `Enable and start firewalld` (via systemd).

## Pull Request
[PR #39](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/39)
