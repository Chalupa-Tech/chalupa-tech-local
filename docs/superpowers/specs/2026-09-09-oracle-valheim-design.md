# Oracle Cloud Server — Valheim Dedicated Server (Design)

**Date:** 2026-09-09
**Status:** Approved design, pending implementation plan
**PR:** _added at merge time_

## Goal

Stand up an always-free Oracle Cloud (OCI) Ampere A1 instance managed from this
repo, and run a modded Valheim dedicated server on it as the first of several
workloads. Provisioning is Terraform, connectivity is Tailscale, configuration
is Ansible — all applied by GitHub Actions on merge to `main`, matching this
repo's PR-only convention.

## Key constraint: x86 game on ARM hardware

The Valheim dedicated server binary is x86_64-only. OCI's always-free x86 shape
(VM.Standard.E2.1.Micro, 1 GB RAM) cannot run it; the always-free Ampere A1
allowance (4 OCPU / 24 GB) can, via the Box64 x86_64-on-ARM translation layer.
Box64 runs both steamcmd and `valheim_server.x86_64`, and BepInEx works under it
(it is a preloader on the same x86 binary). This is the settled approach —
Docker was rejected because Valheim images are x86-only (qemu binfmt is far too
slow) and ARM-native community images are less maintained than a native Box64
install.

## Architecture

```
GitHub Actions (merge to main)
  ├── terraform apply ──► OCI: VCN, subnet, IGW, NSG, A1 instance
  │                          └── cloud-init: install Tailscale, join tailnet
  └── ansible-playbook ─(runner joins tailnet, SSH over Tailscale)─► instance
        ├── role: base     (updates, host firewall, unattended-upgrades)
        └── role: valheim  (Box64, steamcmd, Valheim, BepInEx, mods,
                            systemd unit, backup timer)
```

## Directory layout

```
oracle-cloud-server/
├── terraform/            # OCI: network, NSG, A1 instance, cloud-init
├── ansible/
│   ├── inventory.yml     # oracle server via its Tailscale hostname/IP
│   ├── site.yml
│   └── roles/
│       ├── base/
│       └── valheim/
└── README.md             # one-time bootstrap checklist, player instructions
```

Future services on this box become new roles beside `valheim/`; the Terraform
and CI layers do not change.

## Terraform (OCI infra)

- **Instance:** `VM.Standard.A1.Flex`, 4 OCPU / 24 GB RAM, Ubuntu 24.04 (aarch64),
  ~150 GB boot volume (always-free block storage totals 200 GB).
- **Network:** one VCN, public subnet, internet gateway, route table. An NSG
  allows only **UDP 2456–2457** from `0.0.0.0/0`. **Port 22 is never opened to
  the internet**; SSH is over Tailscale only.
- **cloud-init:** deliberately minimal — install Tailscale, join the tailnet
  with a tagged auth key (`tag:oracle-server`). Everything else is Ansible.
- **State backend:** OCI Object Storage via its S3-compatible API (always-free
  20 GB). One-time manual bootstrap: create the bucket and customer secret keys
  in the OCI console before the first CI run.
- **Capacity caveat:** trial accounts frequently hit "Out of host capacity" for
  A1 shapes. Documented fix: upgrade the account to Pay-As-You-Go (still $0
  within always-free limits) and re-run the apply.

## CI workflows

Mirrors existing repo conventions (`pulumi.yml` / `deploy.yml`):

- **PR:** `terraform fmt -check`, `terraform validate`, `terraform plan`
  (posted to the PR), plus `ansible-lint`.
- **Merge to main:** `terraform apply`, then `ansible-playbook`. The runner
  joins the tailnet via the existing Tailscale OAuth flow (`tag:github-runner`).
  A Tailscale ACL must allow `tag:github-runner → tag:oracle-server:22`.
- **New GitHub secrets:** OCI API key material (tenancy OCID, user OCID,
  fingerprint, private key, region), S3-compatible state credentials, a
  Tailscale auth key for the server, and the Valheim server password.

## Ansible — `valheim` role

1. **Box64** installed from its arm64 APT repository.
2. **steamcmd** as the x86_64 tarball (not apt), run under Box64, installs
   Valheim Dedicated Server (Steam app `896660`) to `/opt/valheim` owned by a
   dedicated `valheim` system user.
3. **BepInExPack_Valheim** (denikson pack) unpacked over the server directory;
   the systemd unit sets the Doorstop environment variables BepInEx requires.
4. **Mods**, pinned by exact version in role vars, downloaded from Thunderstore
   into `BepInEx/plugins/` (dependencies from their manifests are pinned during
   implementation):
   - `Azumatt-AzuCraftyBoxes`
   - `Azumatt-AAA_Crafting`
   - `Azumatt-AzuAutoStore`

   Upgrading a mod = bump a version var in a PR.
5. **systemd unit:** `box64 ./valheim_server.x86_64 -name … -world … -password …
   -public 1` with crossplay **off** (Steam-only). Password flows from GitHub
   secret → Ansible var; never committed.
6. **Host firewall:** OCI Ubuntu images ship default-REJECT iptables rules baked
   into the image. The role must explicitly open UDP 2456–2457 on the host and
   persist the rules — the NSG alone is not sufficient.
7. **Backups:** systemd timer, nightly tar of the worlds directory, retain 14.
   Off-box backup to Object Storage is a documented later add, not built now.

## Player side

Players join `<public-ip>:2456` with the password. All three mods are required
client-side as well; the README documents the pinned mod list and recommends
sharing an r2modman profile code.

## Error handling

- **A1 out-of-capacity:** apply fails cleanly; README documents the PAYG fix.
- **Tailscale join failure:** instance is unreachable by Ansible; auth-key
  expiry/tagging is the first thing the README troubleshooting section covers.
- **Box64/steamcmd flakiness:** steamcmd under Box64 occasionally segfaults on
  exit after a successful install; the install task treats a verified app
  manifest as success, not steamcmd's exit code alone.
- **Server crash:** systemd `Restart=on-failure` with a rate limit.

## Testing / verification

- PR: terraform plan diff + ansible-lint.
- Post-merge verification: BepInEx console log lists all three plugins loaded;
  server joinable by IP from a modded client; world persists across a
  `systemctl restart valheim`.
- Backup timer verified by inspecting the archive after first scheduled run.

## Implementation process

- **Worktrees:** all implementation happens in an isolated git worktree
  (`.claude/worktrees/…`) on a feature branch, never on an existing checkout —
  per the `superpowers:using-git-worktrees` skill.
- **Subagents:** the implementation plan is executed with
  `superpowers:subagent-driven-development` — independent tasks (Terraform
  stack, base role, valheim role, CI workflows, README) are dispatched to
  subagents with review checkpoints between them.
- The implementation plan itself is produced by `superpowers:writing-plans`
  after this spec is approved.

## One-time manual bootstrap (README checklist)

1. Create OCI API key for the automation user; note tenancy/user OCIDs,
   fingerprint, region.
2. Create the Object Storage bucket for Terraform state + customer secret keys.
3. (If capacity-blocked) upgrade account to Pay-As-You-Go.
4. Create Tailscale auth key tagged `tag:oracle-server`; add ACL
   `tag:github-runner → tag:oracle-server:22`.
5. Add the GitHub secrets listed above.
