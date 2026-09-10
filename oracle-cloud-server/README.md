# Oracle Cloud Server

## What this is

An always-free Oracle Cloud Infrastructure (OCI) Ampere A1 instance — `VM.Standard.A1.Flex`, 4 OCPU / 24 GB RAM / 150 GB boot volume, Ubuntu 24.04 ARM — running a modded [Valheim](https://www.valheimgame.com/) dedicated server. The Valheim server binary is x86_64-only, so it runs under [Box64](https://github.com/ryanfortner/box64-debs) on the ARM host. This is the first of several workloads planned for this box; see the [design spec](../docs/superpowers/specs/2026-09-09-oracle-valheim-design.md) for the full rationale (why Box64 over Docker/qemu, why DepotDownloader over steamcmd, etc).

Provisioning is Terraform (`terraform/`), configuration is Ansible (`ansible/`), and both are applied exclusively by GitHub Actions on merge to `main` — matching the rest of this repo's PR-only convention. There are no local applies.

## One-time bootstrap checklist

Work through these in order before the first PR against this directory can merge successfully.

1. **OCI API key.** OCI console → Identity & Security → Users → your user → API keys → Add API Key → generate a key pair. Record the **tenancy OCID**, **user OCID**, **key fingerprint**, and your **region** (e.g. `us-ashburn-1`).
2. **Object Storage state backend.** OCI console → Storage → Object Storage & Archive Storage → Buckets → create a bucket named `terraform-state` (Standard tier). Then Identity & Security → Users → your user → Customer Secret Keys → Generate Secret Key — this yields the S3-compatible access key / secret key pair used by Terraform's `s3` backend. Also record the Object Storage **namespace** shown at the top of the bucket details page.
3. **If capacity errors happen.** Always-free A1 shapes intermittently return "Out of host capacity" on `terraform apply`. If that happens, upgrade the account to Pay-As-You-Go (Billing & Cost Management → Upgrade and Manage Payment). Always-free A1 usage remains $0 after upgrading — it just unlocks capacity that free-tier-only accounts are denied.
4. **Tailscale.** In the Tailscale admin console: add ACL tag `tag:oracle-server` (owner `autogroup:admin`), add an ACL rule allowing `tag:github-runner` → `tag:oracle-server:22` (so the CI runner can SSH over the tailnet), then Keys → Generate auth key: reusable, pre-approved, tagged `tag:oracle-server`. Auth keys expire after at most 90 days — regenerating and updating the `ORACLE_TAILSCALE_AUTH_KEY` secret is only needed if the instance is destroyed and recreated (cloud-init only runs the join on first boot).
5. **Dedicated SSH keypair.** Generate a keypair used only for CI → instance access (never exposed publicly by the security list, but still worth isolating):
   ```bash
   ssh-keygen -t ed25519 -f oracle_server_key -C oracle-cloud-server -N ""
   ```
6. **GitHub secrets.** Add the following repository secrets:

   | Secret | Value |
   |---|---|
   | `OCI_TENANCY_OCID` | Tenancy OCID from step 1 |
   | `OCI_USER_OCID` | User OCID from step 1 |
   | `OCI_KEY_FINGERPRINT` | API key fingerprint from step 1 |
   | `OCI_PRIVATE_KEY` | The private key half of the API key pair from step 1 (PEM contents) |
   | `OCI_REGION` | Region from step 1 (e.g. `us-ashburn-1`) |
   | `OCI_NAMESPACE` | Object Storage namespace from step 2 |
   | `OCI_COMPARTMENT_OCID` | Compartment OCID for resources (tenancy root OCID is fine) |
   | `OCI_S3_ACCESS_KEY` | Customer secret access key from step 2 |
   | `OCI_S3_SECRET_KEY` | Customer secret key from step 2 |
   | `ORACLE_SSH_PUBLIC_KEY` | Public half (`.pub`) of the keypair from step 5 — becomes the `ubuntu` user's `authorized_keys` |
   | `ORACLE_SSH_PRIVATE_KEY` | Private half of the keypair from step 5 — used by CI's SSH agent for Ansible |
   | `ORACLE_TAILSCALE_AUTH_KEY` | Tailscale auth key from step 4 |
   | `VALHEIM_PASSWORD` | Server join password (must be 5+ characters and must not be a substring of the server name `Chalupa Valheim`, or the dedicated server refuses to start) |

   Note: `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` already exist in this repo (used to bring CI runners onto the tailnet as `tag:github-runner`) and are reused here — they are not part of the 13 secrets above.

## How deploys work

- **Pull requests** trigger `.github/workflows/oracle.yml`: `terraform fmt -check -recursive` + `terraform validate` + `terraform plan`, with the plan output posted as a PR comment; and `ansible-lint` against `oracle-cloud-server/ansible/`. Each job only runs if its path (`terraform/` or `ansible/`) changed.
- **Merges to `main`** trigger `.github/workflows/oracle-deploy.yml`: `terraform apply -auto-approve`, then an Ansible run that joins the CI runner to the tailnet (`tag:github-runner`), resolves the instance's Tailscale IP for host `oracle-server`, and runs `ansible-playbook -i inventory.yml site.yml` over that tailnet connection.
- There is no local `terraform apply` or unchecked `ansible-playbook` run — CI is the source of truth, same as the rest of this repo.

## Players: how to join

The server advertises itself in the Steam/Valheim in-game community server list as **`Chalupa Valheim`**. You can also direct-connect to `<public_ip>:2456` — the IP is the Terraform output `public_ip` (visible in the `terraform apply` logs from the deploy workflow, or via `terraform output` if you have credentials and run it locally). The join password is shared out-of-band (it is not documented here).

Crossplay is **off** — Steam only.

**Required client mods** (must match the server's pinned versions or you will fail to connect / desync):

| Mod | Version |
|---|---|
| `denikson-BepInExPack_Valheim` | 5.4.2350 |
| `Azumatt-AzuCraftyBoxes` | 1.8.15 |
| `Azumatt-AAA_Crafting` | 2.1.6 |
| `Azumatt-AzuAutoStore` | 3.0.14 |

The easiest way to get these matched up is an [r2modman](https://github.com/ebkr/r2modmanPlus) profile with exactly these four mods at exactly these versions.

## Operations

- **SSH:** `ssh ubuntu@oracle-server` (over Tailscale; the host has no public SSH ingress at all).
- **Logs:** `journalctl -u valheim -f`
- **Confirm BepInEx/mods loaded:** `journalctl -u valheim | grep -i 'Loading \['`
- **Restart the server:** `sudo systemctl restart valheim`
- **Backups:** a systemd timer (`valheim-backup.timer`) runs daily, archiving the world save (`worlds_local`) to `/opt/valheim/backups`, keeping the newest 14 archives.
- **Mod/BepInEx upgrades:** bump the relevant version pin in `roles/valheim/defaults/main.yml` (`bepinex_version`, or the entry under `valheim_mods`) via a normal PR — the role removes the old versioned plugin directory and installs the new one, and restarts the `valheim` service.

## Troubleshooting

- **"Out of host capacity" on apply** — see bootstrap step 3 (upgrade to Pay-As-You-Go; free usage is unaffected).
- **Nobody can connect** — check the host firewall first, then the cloud NSG:
  1. `sudo iptables -L INPUT -n | head` on the instance (over SSH/Tailscale) — confirm the UDP 2456:2457 ACCEPT rule from the `valheim` role is present.
  2. Then check the OCI NSG (`valheim-nsg`, in `terraform/network.tf`) actually allows UDP 2456-2457 ingress from `0.0.0.0/0`.
- **Instance unreachable over Tailscale** — check the Tailscale admin console for a node named `oracle-server` (is it online, has its auth key expired?). If the instance was recreated, cloud-init only joins the tailnet on first boot, so a stale/expired `ORACLE_TAILSCALE_AUTH_KEY` will silently prevent it from ever appearing.
- **Box64 sanity checks:**
  ```bash
  box64 --version
  update-binfmts --display | grep box64
  ```

## Future workloads

This box is meant to host more than Valheim over time. To add a workload:

1. Add a new role beside `ansible/roles/valheim/` (e.g. `ansible/roles/<newthing>/`).
2. List it under `roles:` in `ansible/site.yml`.
3. Open whatever ports it needs in **both** places: the OCI NSG in `terraform/network.tf` (cloud-level) and the host iptables rules in the new role's own tasks (host-level) — the same defense-in-depth pattern the `valheim` role uses.
