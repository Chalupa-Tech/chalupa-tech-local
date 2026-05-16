# 2026-05-15: Fix Plex NFS Shares Vanishing After Every LXC Reboot

## Overview

Plex reported that it could no longer find any media — both the Movies and
TV Shows libraries showed empty. Investigation on the live Plex LXC (VMID
200) found that the NFS shares from TrueNAS (`192.168.1.40`) were not
mounted at all:

```
$ mount | grep nfs
(empty)

$ ls /mnt/plex/movies
(empty)

$ ls -la /mnt/plex/
drwxr-xr-x 2 root root 4096 Apr 11 06:13 movies
drwxr-xr-x 2 root root 4096 Apr 11 06:13 tvshows
```

The mountpoint directories were from `Apr 11` — i.e. the original Ansible
run that set up the LXC — with no NFS overlay on them.

TrueNAS itself was healthy. From the Proxmox host:

```
$ showmount -e 192.168.1.40
Export list for 192.168.1.40:
/mnt/PlexMedia/frame/TVShows 192.168.1.0/24
/mnt/PlexMedia/frame/Movies  192.168.1.0/24
/mnt/PlexMedia/frame         192.168.1.0/24
```

Port 2049 was open. From inside the Plex LXC, a manual `mount -t nfs
192.168.1.40:/mnt/PlexMedia/frame/Movies /tmp/nfstest` succeeded and
listed the movie library. So NFS in the LXC works fine — the breakdown
was somewhere in how the shares were being mounted at boot.

## Root cause

`ansible/roles/plex_server/tasks/main.yml` wrote each NFS share into
`/etc/fstab` with these options:

```
_netdev,nofail,x-systemd.automount,x-systemd.device-timeout=10s,soft,timeo=150,retrans=5,nfsvers=4
```

`x-systemd.automount` is the key word. When `systemd-fstab-generator`
sees that option, it emits an `<escaped-path>.automount` unit alongside
the regular `.mount` unit; the `.automount` unit is supposed to sit in
`active (waiting)` state and trigger an on-demand mount the first time
anything accesses the path.

In a Linux LXC, that does not work. The container kernel does not
expose the `autofs` filesystem to userspace, and systemd refuses to
start automount units when the autofs backend is unavailable. The
journal makes this explicit:

```
$ journalctl -b -u mnt-plex-movies.automount
May 16 02:44:35 plex systemd[1]: Starting of mnt-plex-movies.automount unsupported.

$ cat /proc/filesystems | grep -E 'nfs|autofs'
nodev   nfs
nodev   nfs4
(no autofs)
```

The `.automount` units therefore stayed `inactive (dead)` for the
entire boot, so nothing was waiting on the mountpoints and nothing
triggered the actual NFS mount.

The reason this had appeared to work historically is that
`ansible.posix.mount` with `state: mounted` does two things in one
shot: it edits `/etc/fstab` *and* performs a live `mount(8)` of the
target right then. So the very first time the role ran, the shares
mounted directly and stayed mounted as long as the LXC kept running.
Once the LXC rebooted (it had restarted ~8 minutes before this
investigation), the only thing standing between Plex and its media
was the `x-systemd.automount`-generated units that systemd refused
to start — and the shares were gone.

## Secondary bug: silent retry safety net

`ansible/roles/plex_server/templates/nfs-mount-retry.service.j2` was
intended as a safety net: 15 s after `network-online.target`, run
`mount -a` to retry anything that failed at boot (e.g. TrueNAS slow
to come up). It read:

```
ExecStart=/bin/mount -a -t nfs4
```

The fstab entries are written with `fstype: nfs` (the modern, generic
type — `nfsvers=4` is a *mount option*, not the kernel filesystem
type). `mount -a -t nfs4` filters fstab to lines whose type column
literally reads `nfs4`. None of the Plex entries match that filter,
so the retry service has been a no-op every single boot since it was
added. It exits `0/SUCCESS` without trying to mount a thing, which
is why nothing in the journal hinted at the problem.

## Fix

Two changes in this PR:

1. **Drop `x-systemd.automount,x-systemd.device-timeout=10s` from the
   fstab options** in `ansible/roles/plex_server/tasks/main.yml`.
   The remaining `_netdev,nofail` options give the same boot-safety
   guarantee (defer until `network-online.target`, do not hang boot
   if the mount fails). Without the unsupported automount layer in
   the way, systemd's generated `.mount` units actually try to mount
   the shares at boot. Also added a `notify: Restart plexmediaserver`
   on the mount task so that when the role rewrites fstab in the
   first post-fix CI run, Plex restarts and re-scans the shares
   cleanly.

2. **Fix the retry filter** in
   `ansible/roles/plex_server/templates/nfs-mount-retry.service.j2`
   from `mount -a -t nfs4` to `mount -a -t nfs`, matching the
   `fstype: nfs` that Ansible actually writes into fstab. The
   service is now an actual safety net for the
   TrueNAS-down-at-boot case rather than a placebo.

The two changes are independent of each other, but they are the same
class of bug (mount machinery silently doing nothing) and are best
fixed together so a future reader sees the whole story in one diff.

## Why not run autofs properly in the LXC?

In principle the Plex LXC could be given `lxc.mount.entry =
/sys/fs/cgroup` plus the autofs `cgroup_v1` shim and the right
`/dev/autofs` passthrough — but doing that on the host side leaks
container-specific machinery into the privileged Proxmox config and
buys nothing the simpler fstab approach doesn't already provide for
this use case. There are only two NFS shares, they live on the same
TrueNAS box, they are needed by exactly one consumer, and lazy
on-demand mounting was never the goal — the original comment ("so
the LXC won't hang at boot if TrueNAS is temporarily unreachable")
is already satisfied by `_netdev,nofail`.

## PR

[#195](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/195)
