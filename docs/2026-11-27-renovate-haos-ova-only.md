# Renovate: only offer HAOS releases that ship the OVA qcow2

**Date:** 2026-11-27
**PR:** [#492](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/492)

## What

- Added a `custom.haos-ova` Renovate datasource in `renovate.json`. It reads
  the GitHub releases API for `home-assistant/operating-system` and keeps only
  non-draft, non-prerelease releases whose assets include both
  `haos_ova-<ver>.qcow2.xz` and `SHA256SUMS`.
- Pointed the HAOS regex manager (Pulumi `haosVersion` + Ansible
  `haos_version`) at that datasource instead of `github-releases`.
- Pinned HAOS back from `18.5` to `18.4` in `pulumi/Pulumi.proxmox.yaml` and
  `ansible/group_vars/all.yml`.

## Why

Renovate auto-merged the bump to 18.5 (#457). HAOS 18.5 is a **Raspberry Pi-only**
security release. Its assets are only `rpi3/4/5` and `yellow` images, with no
`haos_ova-18.5.qcow2.xz` and no `SHA256SUMS`. The next deploy failed in Stage 1
(run 45825533099):

```
TASK [proxmox_prep : Ensure HAOS qcow2 image (compressed) is present on host]
fatal: [pve1]: FAILED! => {"msg": "Request failed with msg HTTP Error 404: Not Found",
  "url": ".../releases/download/18.5/SHA256SUMS"}
```

The plain `github-releases` datasource treats every tagged release as a valid
upgrade. The new datasource checks the assets proxmox_prep actually downloads,
so board-specific releases never reach a PR. Requiring `SHA256SUMS` also
matches the checksum lookup in `haos_image_checksum`, which is only valid from
18.4 onward.

## Safety

The pin only affects fresh provisioning. The HA VM (250) has
`IgnoreChanges(["disks"])` + `Protect(true)` and updates itself, so moving the
pin back to 18.4 is a no-op for the running VM. 18.4 is already the version
staged on pve1 under `/var/lib/vz/import/`.

## Notes

- The datasource reads only the first page (100 releases), which covers years
  of HAOS history.
- To check the filter locally, run the `transformTemplates` JSONata against
  `gh api 'repos/home-assistant/operating-system/releases?per_page=100'`.
  On 2026-11-27 it returned only `18.4` among the 18.x releases.
