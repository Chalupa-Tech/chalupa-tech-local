# Home Automation (#6) — Design

**Date:** 2026-05-12
**Status:** Approved (pending implementation plan)
**Sub-project:** #6 of the multi-cycle ArgoCD/GitOps rollout. Standalone — no upstream dependency on sub-projects #1–#5b's K8s scope; HA runs *outside* the cluster on its own Proxmox VM. Light coupling to #2 (uses the existing Traefik LB + wildcard cert + Unifi DNS override) and #4–#5 patterns (Pulumi resource conventions, PR/verification posture).

## Context

The homelab today runs five workloads on `pve1`: TrueNAS VM (storage), Plex LXC (media playback), Talos K8s cluster (3 CP + 3 worker, hosting platform/media/observability tiers), and nothing for home automation. The "Home automation" line item in the roadmap memory was originally hand-waved as "Home Assistant + Z-Wave in a new privileged LXC" — that framing turned out to be wrong during this brainstorm because it anchored on a container model that loses the entire Home Assistant add-on ecosystem (Z-Wave JS UI, Mosquitto, ESPHome, Frigate, Music Assistant, etc.). The actual install methods on Proxmox are HAOS-in-VM, HA Container in LXC, HA Supervised on Debian-in-VM, or HA-on-K8s; this spec selects **HAOS in a Proxmox VM** (Decision 1).

There is an **existing Home Assistant instance still running** on a previous host (HA Container or Supervised flavor) with a Z-Wave network already bonded to an **Aeotec Z-Stick 10 Pro** (combo Zigbee 3.0 + Z-Wave 800 series) that physically migrates to `pve1`. The Z-Wave network state (paired node IDs, security keys, mesh routes) lives in the dongle's NVM and survives the move; HA's `/config` (automations, dashboards, integrations, HACS state, user accounts, recorder history) gets carried over by file-level restore. The dongle's Zigbee radio is **deferred** — no Zigbee devices to onboard at launch.

Sub-project #6 ships the code to stand up the empty HAOS VM and wire its HTTPS ingress through Traefik. The *cutover* — exporting from the old HA, restoring into the new HAOS, importing the Z-Wave NVM, reconciling integrations — is documented as a one-shot runbook executed manually after the code PR lands. This split keeps the GitOps/PR surface small and idempotent; the cutover is operational work that doesn't belong in CI.

## Roadmap (carry forward)

1. **ArgoCD foundation** — DONE 2026-05-04.
2. **Secrets + TLS Ingress** — DONE 2026-05-07.
3. **Media stack** — DONE 2026-05-08.
4. **CloudNativePG + arr-stack PostgreSQL** — DONE 2026-05-08.
5. **Metrics & Visualization** — DONE 2026-05-10.
5b. **Log aggregation** — DONE 2026-05-11.
5c. **Alerting** — vmalert + Alertmanager + notification destination.
6. **Home automation** *(this spec)* — HAOS VM on Proxmox with Aeotec Z-Stick 10 Pro USB passthrough, Traefik ingress, backup-restore from existing HA.
7. **Backups** — Velero + TrueNAS target. Coordinates with CNPG's WAL archiving and HA's snapshot mechanism (which ships local-only in #6, off-host in #7).

## Goals

- Provision a new **Home Assistant OS** VM on `pve1` (VMID 250, IP 192.168.1.234, 4 vCPU, 8192 MB RAM, 60 GB qcow2 on `local-lvm`) via Pulumi in the existing `chalupa-infra` stack.
- USB passthrough of the Aeotec Z-Stick 10 Pro using a named Proxmox **Resource Mapping** (`aeotec-zstick-10`), referenced from Pulumi by name. Same pattern as TrueNAS HBA PCI mappings (`hba_part_1`, `hba_part_2`).
- Idempotent host-side preparation: an Ansible task in the existing `proxmox_prep` role downloads the pinned HAOS qcow2 image to `/var/lib/vz/template/iso/` so Pulumi can `ImportFrom` it as the VM's scsi0 disk.
- HTTPS ingress via the established Traefik pattern: `https://homeassistant.frame.chalupatech.com` resolved on LAN by the Unifi wildcard override (sub-project #2), terminated at Traefik (LB IP 192.168.1.230, wildcard cert from cert-manager), proxied via a K8s `ExternalName` Service to `http://192.168.1.234:8123`.
- One PR (Decision 10): Pulumi VM + Ansible image download + Traefik IngressRoute manifest bundled and merged together. Data-plane verification gates the PR per `verification-before-completion`.
- Z-Wave network continuity at cutover: dongle NVM transferred physically, controller backup imported into the new Z-Wave JS UI add-on, devices reconnect without re-pairing.
- HA configuration continuity: `/config` from old HA restored into new HAOS, including automations, dashboards, HACS state, user accounts, and recorder history. Integration audit pass reconciles any references that broke (the old HA was on the same LAN, so most should still resolve).
- `Protect(true)` on the HAOS VM in Pulumi state, matching TrueNAS posture — HA holds Z-Wave network state and accumulating history; accidental teardown is high-cost.

## Non-Goals (explicitly out of scope)

- **Zigbee at launch.** The Aeotec's Zigbee radio stays dormant. No ZHA, no Zigbee2MQTT, no Mosquitto. Adding Zigbee later is a separate sub-project: install one HA add-on + re-pair each Zigbee device. (Decision 2b.)
- **Postgres recorder.** Default SQLite at `/config/home-assistant_v2.db` is sized for years of homelab-scale Z-Wave history. Migrating to the `arrs-pg` CNPG cluster adds a network hop, an ESO sync, an ApplicationSet ignoreDifferences entry, and a new failure mode (HA hangs on startup if CNPG is degraded). HA documents a documented SQLite→PG migration path if/when scale demands it. (Decision 5.)
- **OIDC / SSO.** HA uses its built-in user database (with TOTP recommended). The OpenBao OIDC provider is a deliberate future sub-project (its own discovery endpoints, RP clients, group claims, coherent story across ArgoCD UI + Grafana + HA + future tools) and is not bolted in during #6. (Decision 7.)
- **New integrations.** No proactive day-1 integrations beyond what the restored `/config` already contains. Each new integration becomes a small follow-up PR (or even just a runbook entry) as a real use case emerges; YAGNI-spec'ing them now would commit to credential plumbing for automations not yet written. (Decision 8.)
- **NFS/off-host backups in #6.** HAOS's built-in snapshot mechanism writes locally to the qcow2 disk only at #6 ship. Off-host destinations (TrueNAS NFS share, Velero coordination) are sub-project #7's call — designing them now would either pre-decide #7 or land an inconsistent half-solution. (Decision 11.)
- **ESO sync of HA secrets.** HA runs outside the K8s cluster, so the ESO → K8s Secret flow doesn't apply. Secrets that HA needs (HACS GitHub PAT, integration credentials) live in OpenBao at `secret/homeassistant/*` and are entered into HA's UI manually during the runbook. There is no programmatic sync from OpenBao into HAOS in this spec.
- **Configuration-as-code for HA.** Automations, dashboards, integrations live in HAOS's `/config` directory and are managed through HA's web UI. They are not checked into this repo. The decision is upstream: HA-as-code via packages.yaml is a viable but heavyweight pattern, intentionally out of scope here.
- **Bringing the old HA host into chalupa-tech inventory.** The previous HA instance is archived or decommissioned after cutover; it is not adopted as a chalupa-tech managed resource.

## Architecture

### Position in the homelab

```
                 ┌─────────────────────────────────────────────────────────────┐
                 │                       pve1 (Proxmox host)                   │
                 │                                                             │
  ┌──────────┐   │   ┌─────────────────┐  ┌─────────────────┐                  │
  │  Unifi   │   │   │   TrueNAS VM    │  │    Plex LXC     │                  │
  │ Gateway  │   │   │  192.168.1.40   │  │  192.168.1.224  │                  │
  │  .1.1    │   │   │  VMID 100,      │  │  VMID 200,      │                  │
  └────┬─────┘   │   │  HBA PCI        │  │  GPU passthru   │                  │
       │         │   │  passthru       │  └─────────────────┘                  │
       │         │   └─────────────────┘                                       │
       │         │                                                             │
       │         │   ┌─────────────────┐  ┌─────────────────────────────────┐  │
       │         │   │    NEW: HAOS    │  │  Talos K8s (6 nodes)            │  │
       │         │   │   VMID 250      │  │  CPs:    .225 .228 .229         │  │
       │         │   │   .1.234        │  │  Worker: .226 .227 .232         │  │
       │         │   │   USB passthru: │  │  VIP:    .231                   │  │
       │         │   │   aeotec-zstick │  │  Traefik LB:    .230            │  │
       │         │   │   -10           │  │                                 │  │
       │         │   └────────┬────────┘  │  ┌───────────────────────────┐  │  │
       │         │            │           │  │  IngressRoute              │  │  │
       │         │            │           │  │  homeassistant.frame...    │  │  │
       │         │            │           │  │  ─→ ExternalName Service   │  │  │
       │         │            │           │  │  ─→ 192.168.1.234:8123     │  │  │
       │         │            │           │  └───────────────────────────┘  │  │
       │         │            │           └─────────────────────────────────┘  │
       │         │            │                                                │
       │         │   Aeotec Z-Stick 10 Pro (USB)                               │
       │         │   └─→ Z-Wave 800 LR mesh @ 908.4 MHz                        │
       │         │      (Zigbee radio dormant)                                 │
       │         └─────────────────────────────────────────────────────────────┘
       │
       ▼  LAN client browsers → DNS *.frame.chalupatech.com → 192.168.1.230 (Traefik)
                                                            → ExternalName → .234:8123
```

The HAOS VM has no upstream runtime dependency on the K8s cluster — it functions as a standalone service on the LAN. The only path through K8s is *inbound* HTTPS via Traefik for browser/external access. Z-Wave control flow never touches K8s.

### Repository layout (additions / modifications)

```
ansible/
├── group_vars/
│   └── all.yml                                    MODIFIED
│       └── haos_version: "13.2"                   NEW key (verify against GitHub releases at spec/PR time)
└── roles/
    └── proxmox_prep/
        └── tasks/
            └── main.yml                           MODIFIED
                └── name: Download HAOS qcow2      NEW task (get_url + unxz)

pulumi/
├── main.go                                        MODIFIED
│   └── createHomeAssistantVM(ctx, pveProvider)    NEW call
└── homeassistant.go                               NEW
    └── createHomeAssistantVM()
        └── one vm.NewVirtualMachine, USB mapping, ImportFrom, Protect(true)

gitops/
└── apps/
    └── infra-tools/
        └── homeassistant/                         NEW
            ├── Chart.yaml                         # wrapper chart (no upstream dep — just renders our manifests)
            ├── values.yaml                        # placeholder for any tunables
            ├── .helmignore                        # must NOT exclude charts/ (lessons-from-#3)
            └── templates/
                ├── namespace.yaml                 # baseline PSA (no privileged workload — ExternalName + IngressRoute only)
                ├── externalname.yaml              # Service of type ExternalName → 192.168.1.234
                ├── middleware-redirect-https.yaml # HTTP→HTTPS redirect (Traefik Middleware CRD)
                └── ingressroute.yaml              # IngressRoute, websecure entrypoint, wildcard TLS
```

The `gitops/apps/infra-tools/homeassistant/` directory is picked up by the existing `infra-tools` ApplicationSet (Decision 9 + repo structure). The placement reflects HA's role: it's a homelab service that sits outside the cluster, not a platform tier and not a media-stack member. The wrapper-chart pattern matches sub-projects #3/#4/#5 conventions even though there's no upstream Helm chart involved here.

> **Implementer note (placement):** before writing the manifests, read `gitops/bootstrap/applicationsets/` to confirm the `infra-tools` ApplicationSet exists and how it globs `gitops/apps/infra-tools/*`. If the ApplicationSet shape is different from this spec's assumption, adjust placement to match the actual structure — this spec was written without re-reading the ApplicationSet at write time.

### Components

#### Pulumi VM (`pulumi/homeassistant.go`)

| Field | Value | Why |
|---|---|---|
| `VmId` | 250 | Free slot between Plex LXC (200) and Talos VMs (300–305) |
| `NodeName` | `proxmox` | Single-node cluster name |
| `Name` | `homeassistant` | Lowercased, matches hostname convention |
| `Description` | `"Home Assistant OS (Managed by Pulumi)"` | Same convention as TrueNAS / Talos |
| `Bios` | `ovmf` | HAOS supports both BIOS/UEFI; UEFI matches the rest of the fleet (TrueNAS, Talos). If first-boot has issues, swap to `seabios` and revert. |
| `Machine` | `q35` | Matches TrueNAS / Talos |
| `Cpu.Cores` | 4 | Decision: 4 vCPU |
| `Cpu.Type` | `host` | Matches fleet pattern |
| `Memory.Dedicated` | 8192 | Decision: 8 GB |
| `NetworkDevices[0].Bridge` | `vmbr0` | Same LAN as the rest |
| `Disks[0].DatastoreId` | `local-lvm` | Same pattern as Talos worker disks |
| `Disks[0].Interface` | `scsi0` | Boot disk |
| `Disks[0].Size` | 60 | Decision: 60 GB |
| `Disks[0].FileFormat` | `raw` | Pulumi imports raw; the qcow2 source gets converted on import |
| `Disks[0].ImportFrom` | `/var/lib/vz/template/iso/haos_ova_<ver>.qcow2` (variable interpolated from env or Pulumi config) | Pre-staged by Ansible |
| `Usbs[0].Mapping` | `aeotec-zstick-10` | Named Proxmox Resource Mapping created manually before merge |
| `Usbs[0].Usb3` | `true` | Aeotec Z-Stick 10 Pro is USB 3.0 capable; can leave false too — confirm at implementation time |
| `Started` | `true` | Same convention |
| `OnBoot` | `true` | Restart on host reboot |
| `Startup.Order` | 6 | Last in startup queue (HAOS has no upstream deps) |
| `BootOrders` | `["scsi0"]` | No CD-ROM in this VM |
| `OperatingSystem.Type` | `l26` | Linux 2.6+ kernel — HAOS is Linux underneath |
| `Vga.Type` | `vmware` | Same as Talos / TrueNAS |
| `IgnoreChanges` | `["started"]` | Project pattern; avoids restart drift |
| Resource option | `pulumi.Protect(true)` | Decision: protect like TrueNAS |

#### Ansible HAOS image download (`ansible/roles/proxmox_prep/tasks/main.yml`)

A new task block under `proxmox_prep` (the role already runs against `pve1`):

```yaml
- name: Ensure HAOS qcow2 image is present on Proxmox host
  ansible.builtin.get_url:
    url: "https://github.com/home-assistant/operating-system/releases/download/{{ haos_version }}/haos_ova-{{ haos_version }}.qcow2.xz"
    dest: "/var/lib/vz/template/iso/haos_ova-{{ haos_version }}.qcow2.xz"
    mode: "0644"
    checksum: "{{ haos_qcow2_checksum }}"  # sha256 from the GitHub release page
  register: haos_download

- name: Decompress HAOS qcow2
  ansible.builtin.command:
    cmd: "xz -d --keep /var/lib/vz/template/iso/haos_ova-{{ haos_version }}.qcow2.xz"
    creates: "/var/lib/vz/template/iso/haos_ova-{{ haos_version }}.qcow2"
```

Both tasks are idempotent. `get_url` skips on existing file (with checksum match); the decompress task's `creates:` guards re-runs.

`haos_version` and `haos_qcow2_checksum` are declared in `ansible/group_vars/all.yml`. The version pin **must be verified against `https://api.github.com/repos/home-assistant/operating-system/releases/tags/<ver>`** before merging (per `feedback_verify_image_tag_on_registry.md` — the relevant memory says "don't infer image tags from release names; probe the registry").

Pulumi reads the version from a Pulumi config key set in `pulumi/Pulumi.proxmox.yaml`:

```yaml
config:
  chalupa-infra:haosVersion: "13.2"
```

The CI workflow `pulumi.yml` exports the same value as an env var so a single source of truth lives in the repo. The implementer keeps the Ansible `group_vars/all.yml` value and the Pulumi config value in sync; a brief comment in both files cross-references the other.

#### Traefik ingress (`gitops/apps/infra-tools/homeassistant/templates/`)

Three manifests, all in the `homeassistant` namespace:

1. **`namespace.yaml`** — `kind: Namespace`, `name: homeassistant`, baseline PSA labels (`pod-security.kubernetes.io/enforce: baseline`). No privileged workloads here.
2. **`externalname.yaml`** — `kind: Service`, `type: ExternalName`, `externalName: 192.168.1.234`, `ports: [{name: http, port: 8123}]`. Routes K8s-level traffic to the off-cluster HA.
3. **`middleware-redirect-https.yaml`** — `kind: Middleware` (Traefik CRD), `redirectScheme: {scheme: https, permanent: true}`. Reuses the established NzbGet redirect pattern from sub-project #3.
4. **`ingressroute.yaml`** — `kind: IngressRoute`:
   - Annotation `external-dns.alpha.kubernetes.io/target: "192.168.1.230"` (per the relevant memory — external-dns silently skips IngressRoutes without this).
   - Entrypoint `websecure`.
   - `routes[0].match: Host(\`homeassistant.frame.chalupatech.com\`)`.
   - `routes[0].services: [{name: homeassistant, port: 8123}]` (referencing the ExternalName Service).
   - `tls.secretName: wildcard-frame-chalupatech-com-tls` (the existing wildcard cert from cert-manager).

Plus a second IngressRoute on the `web` entrypoint for HTTP→HTTPS redirect via the middleware.

### Data flow

#### Inbound HTTPS

```
browser
    │  GET https://homeassistant.frame.chalupatech.com
    ▼
Unifi DNS (LAN wildcard override) → 192.168.1.230
    ▼
Traefik (Talos pod, LB IP 192.168.1.230)
    │  matches Host() rule, terminates TLS with wildcard cert (sub-project #2)
    │  applies redirect middleware on `web` entrypoint (302 → https)
    ▼
ExternalName Service `homeassistant.homeassistant.svc.cluster.local`
    │  resolves to 192.168.1.234 (off-cluster)
    ▼
HAOS at 192.168.1.234:8123
    │  http.use_x_forwarded_for: true
    │  http.trusted_proxies: [10.244.0.0/16 (Talos pod CIDR), 192.168.1.230]
    ▼
HA core handles request
```

#### Z-Wave control (no K8s involvement)

```
HA core (in HAOS VM)
    │  WebSocket → ws://localhost:3000
    ▼
Z-Wave JS server (in Z-Wave JS UI add-on, same HAOS)
    │  opens /dev/serial/by-id/usb-Silicon_Labs_*-* (Aeotec dongle)
    ▼
Aeotec Z-Stick 10 Pro (USB passthrough'd from host)
    │  908.4 MHz Z-Wave 800 LR mesh
    ▼
Z-Wave device (switch / sensor / lock)
```

#### State locations

| Data | Location | Lifecycle |
|---|---|---|
| HA configuration (`/config`, automations, dashboards) | HAOS qcow2 disk on `local-lvm` | Restored from backup at cutover; persists across reboots |
| Recorder DB (history, statistics) | SQLite at `/config/home-assistant_v2.db` | Restored from backup; default purge after 10 days |
| Z-Wave network state (paired devices, security keys, mesh) | Dongle NVM (Aeotec hardware) | Survives dongle reseat; survives HA reinstall; physical-only |
| Z-Wave JS UI metadata (friendly names, device DB) | `/config/zwave-js-ui/store.db` inside the add-on's data dir | Imported from old setup's Z-Wave JS export |
| HACS state (installed integrations metadata) | `/config/.storage/hacs/` + `/config/custom_components/` | Restored from backup; HACS picks up after add-on reinstall |
| GitHub PAT (for HACS rate-limit + repo access) | OpenBao at `secret/homeassistant/github-pat` | Manual entry into HA UI at HACS setup time; HA outside cluster → no ESO sync |
| HA built-in user accounts | `/config/.storage/auth` | Restored from backup; old credentials work |
| Daily local snapshots | HAOS local filesystem (qcow2) | Local-only at #6 ship; #7 takes this off-host |

### HA-side configuration touchpoints (entered via UI during runbook)

| Setting | Path in HA UI | Value | Why |
|---|---|---|---|
| Static IP | Settings → System → Network | `192.168.1.234/24`, gateway `192.168.1.1`, DNS `192.168.1.1` then `1.1.1.1` | Match the LAN table; eliminate DHCP drift |
| Trusted proxies | `configuration.yaml` `http:` block | `use_x_forwarded_for: true`, `trusted_proxies: [10.244.0.0/16, 192.168.1.230]` | Real client IPs in logs and rate limits; Traefik termination |
| HACS PAT | HACS settings panel | GitHub PAT from OpenBao | Avoid GitHub anonymous rate limits |
| Z-Wave JS UI controller | Z-Wave JS UI → Settings → Z-Wave → Restore NVM | NVM backup from old HA | Carry the Z-Wave network over |
| 2FA | Profile → 2FA setup | TOTP enabled (recommended) | Decision 7 — built-in auth with TOTP |
| Backup schedule | Settings → System → Backups → Automation | Nightly, keep last 14, encrypted with passphrase from OpenBao | Decision 11 — local snapshots only |

## Cutover runbook (executed once after PR merges)

The PR merge creates the **empty** HAOS VM and stands up the IngressRoute. Cutover is a separate manual operation. Pre-condition: the old HA is still running and reachable from your workstation.

**A header on the runbook in the repo will say explicitly: "Have you completed cutover already? If yes, STOP — re-running these steps overwrites work done after."**

1. **Pre-merge prep** (do before merging the PR):
   1. SSH to `pve1`, run `qm list | grep -E '^(\s+)?250\s'`. Confirm VMID 250 is free.
   2. In Proxmox UI: `Datacenter → Resource Mappings → USB Devices`. Add a new mapping named `aeotec-zstick-10`, targeting the Aeotec on `pve1` (vendor:product is either `0658:0200` or `10c4:ea60` depending on firmware variant — pick whichever is the Aeotec).
   3. Verify the `haos_version` pinned in `group_vars/all.yml` exists at `https://github.com/home-assistant/operating-system/releases/tag/<ver>`. Capture the sha256 from the release page into `haos_qcow2_checksum`.
2. **Merge the PR.** CI applies Ansible (downloads + decompresses qcow2) then Pulumi (creates VM, attaches dongle). VM auto-boots into HAOS welcome.
3. **First-boot onboarding** (browse to `http://192.168.1.234:8123` over LAN since HAOS comes up on DHCP first):
   1. Complete the onboarding wizard. Create a throwaway admin user — restored auth from backup will overwrite this in step 6.
   2. Settings → System → Network → set static IP `192.168.1.234`, gateway `192.168.1.1`, DNS `192.168.1.1`. Restart HAOS.
   3. Confirm `https://homeassistant.frame.chalupatech.com` loads on LAN (Traefik route + ExternalName + ingress all working).
4. **Add-on install pass** (do NOT start Z-Wave JS UI yet — old HA still owns the dongle):
   1. Settings → Add-ons → Add-on Store → install **Z-Wave JS UI**. Leave stopped.
   2. Install **HACS** by installing the **Studio Code Server** (or SSH & Web Terminal) add-on first, opening a terminal inside HAOS, then running the official download script: `wget -O - https://get.hacs.xyz | bash -`. This drops `hacs/` into `/config/custom_components/`. Restart HA core, then add the HACS integration via Settings → Devices & Services → Add Integration → HACS. Enter the GitHub PAT from OpenBao at `secret/homeassistant/github-pat`. (HACS is not a HA Supervisor add-on — it's a custom integration installed into `custom_components/`.)
   3. Install **Samba** add-on (for `/config` file transfer in step 6) or use the SSH / Studio Code Server add-on.
5. **Quiesce old HA** (one-way; old setup goes offline):
   1. In old HA's Z-Wave JS UI: export the NVM backup (`Settings → Z-Wave → Backup NVM`). Save the `.bin` to your workstation.
   2. Optional but recommended: export Z-Wave JS UI settings/store separately if the UI offers it (device friendly-names sometimes live here in addition to the NVM).
   3. Stop the Z-Wave JS instance on the old HA.
   4. Stop the old HA Core / Container entirely. Confirm the old HA's web UI is unreachable. From this point until step 7c, **the dongle is unowned**.
6. **Restore `/config`**:
   1. From workstation, mount the new HAOS Samba share or open the SSH add-on.
   2. Copy old HA's `/config/` contents into new HAOS's `/config/`, overwriting everything *except* `home-assistant.log` (let HA start fresh).
   3. From the new HAOS UI: Settings → System → Restart (full restart, not just core).
   4. After restart, log in with **old credentials**. The throwaway admin from step 3.1 is overwritten.
   5. Reinstall HACS if its add-on flag got reset by the `/config` overwrite; HACS detects existing `custom_components/` and resumes without re-downloading.
7. **Attach Z-Wave + import NVM**:
   1. Start the **Z-Wave JS UI** add-on. It claims the dongle.
   2. Z-Wave JS UI → Settings → Z-Wave → Restore from NVM Backup. Upload the `.bin` from step 5.1. Confirm node count matches old HA's.
   3. Trigger one device (toggle a switch / read a sensor) from the HA UI. Confirm round-trip < 2 s.
8. **Integration audit pass** (Settings → Devices & Services):
   1. Walk each restored integration.
   2. For any that show "auth expired" or "cannot connect": re-enter credentials. Since old HA was on the same LAN, IPs and hostnames should still resolve.
   3. Delete any integration pointing at a service that no longer exists.
   4. Record the final integration list in cutover notes (PR review comment or separate doc, your call).
9. **Smoke test**:
   1. Trigger one known automation. Confirm expected action fires.
   2. Verify Lovelace dashboards render without missing entities.
   3. Check Settings → System → Logs for persistent red banners; document or fix any.
10. **Cutover complete.** Old HA host can be archived / repurposed. The dongle is now bonded to the new HAOS exclusively.

## Failure modes

| Failure | Detection | Recovery |
|---|---|---|
| HAOS image URL 404 (pinned version doesn't exist) | Ansible `get_url` fails in CI | Pre-merge step #1.3 catches this. If missed: bump `haos_version`, re-run. |
| USB mapping `aeotec-zstick-10` not present | `pulumi up` errors at VM creation: "mapping not found" | Runbook step #1.2; if missed, create mapping, re-run CI. No state damage. |
| VMID 250 collision | `pulumi up` errors: "VM 250 already exists" | Runbook step #1.1; if missed, pick alternate VMID, update spec + Pulumi. |
| qcow2 path mismatch between Ansible and Pulumi | Pulumi VM creation fails: "disk image not found" | Both files reference the same `haos_version` constant. Implementer must verify path consistency before merge. |
| VM boots but HAOS doesn't reach DHCP | `WaitForIp` times out at 10 m | Inspect via Proxmox console. Common cause: OVMF + scsi0-only boot order; HAOS official is dual BIOS/UEFI bootable. If hung: switch `Bios: seabios`, `pulumi up`. |
| USB dongle present in Proxmox but `/dev/serial/by-id/` empty inside HAOS | HAOS Hardware view shows USB device but no serial node | Mapping is targeting wrong host USB device (Aeotec presents under multiple vendor IDs depending on firmware). Fix mapping in Proxmox UI; restart VM. |
| Traefik returns 404 for `Host(\`homeassistant.frame.chalupatech.com\`)` | `curl -k -H 'Host: homeassistant.frame.chalupatech.com' https://192.168.1.230` returns 404 | Check ArgoCD: `infra-tools/homeassistant` Application Synced/Healthy; check IngressRoute landed in the right namespace; check Host() rule. |
| Traefik proxies but HA returns "400: invalid host header" | HA logs show rejection from Traefik pod IP | Add `10.244.0.0/16` and `192.168.1.230` to `http.trusted_proxies` (runbook step 3.2 reminder). |
| External-DNS silently skips the IngressRoute | Cloudflare doesn't get an A record (LAN still works via Unifi override) | Confirm `external-dns.alpha.kubernetes.io/target: "192.168.1.230"` annotation per the relevant memory. External resolution is moot anyway given Cloudflare's RFC 1918 filter (LAN-only is the intended posture). |
| HACS install fails (GitHub rate limit or PAT unauthorized) | HACS UI shows "rate limit exceeded" or auth error | Regenerate PAT with `read:packages, read:org` scopes; re-paste. No restart needed. |
| Z-Wave network ends up empty after NVM restore | Z-Wave JS UI shows 0 nodes | NVM file from a different controller, or restore step missed. Re-export from old HA; verify file integrity; retry import. If old controller was different hardware family entirely (it isn't here — Aeotec→Aeotec), NVM portability is not guaranteed. |
| Both HAs accidentally talk to the dongle simultaneously | Z-Wave JS UI on either side shows "serial port busy" or intermittent communication failures | Strictly serialize via runbook steps 5–7 (quiesce old before starting new). If it happens: stop *both* HAs, restart only the new one. The dongle NVM is unaffected; the brief contention does not corrupt network state. |

### Idempotency posture

- **Code PR (Pulumi + Ansible + Traefik manifests):** fully idempotent. Re-running CI is safe — no state damage.
- **Runbook:** explicitly **one-shot**. Re-running step 6 (`/config` restore) after the new HA has accumulated post-cutover state would overwrite that state. The runbook header calls this out. If a true rollback is needed, see below.

### Rollback

Until step 5 of cutover ("Quiesce old HA"), the old HA is still authoritative and a rollback is "do nothing on the new HAOS, keep using old HA." After step 5, rollback requires:

1. Stop the new HAOS VM.
2. Move the dongle back to the old host (physical).
3. Start the old HA. Z-Wave network resumes — NVM lives in the dongle.

The new HAOS VM remains on `pve1` as a non-functional shell until you decide to destroy or retry. Because of `Protect(true)`, destroying requires `pulumi.Protect(false)` first, an explicit guardrail against accidental teardown.

## Verification gates

Pulled from the testing section of the brainstorm. The PR is **not** considered complete until Phases 1 and 2 are demonstrated in the PR description with command output.

### Phase 1 — Pre-merge (CI on the PR)

| Check | Command | Pass = |
|---|---|---|
| Go compiles | `cd pulumi && go build ./...` | exit 0 |
| Pulumi lint | `cd pulumi && golangci-lint run` | exit 0 |
| Ansible lint | `cd ansible && ansible-lint` | exit 0 |
| Pulumi preview | `pulumi preview` (runs in `.github/workflows/pulumi.yml`) | plan shows: 1 new VM, 0 destroy, 0 protect-changes |
| Ansible dry-run | `ansible-playbook -i inventory.yml site.yml --check --diff` (runs in `.github/workflows/ansible.yml`) | idempotent — only change is the new HAOS download task on a fresh host |
| HAOS image URL probe | `curl -fsSI https://github.com/home-assistant/operating-system/releases/download/<ver>/haos_ova-<ver>.qcow2.xz` | HTTP 200 |

### Phase 2 — Post-merge data-plane

Executed by CI's existing `Verify GitOps reconciliation` step (from sub-project #1 PR #86) plus manual checks. The implementer must include output in the PR description.

| Check | How | Pass = |
|---|---|---|
| HAOS qcow2 on host | `ssh pve1 ls -la /var/lib/vz/template/iso/haos_ova-*.qcow2` | file exists, size > 0 |
| VM 250 running | `ssh pve1 qm status 250` | `status: running` |
| Dongle visible to VM | Proxmox UI → VM 250 → Hardware → USB list includes `aeotec-zstick-10` | entry present |
| HAOS HTTP reachable | `curl -k -o /dev/null -w '%{http_code}\n' http://192.168.1.234:8123` | 200 |
| Synced in ArgoCD | `kubectl get application -n argocd homeassistant -o jsonpath='{.status.sync.status} {.status.health.status}'` | `Synced Healthy` |
| Traefik route resolves | `curl -k -o /dev/null -w '%{http_code}\n' https://homeassistant.frame.chalupatech.com` | 200 |
| TLS cert valid | `curl -v https://homeassistant.frame.chalupatech.com 2>&1 \| grep 'subject:'` | wildcard `*.frame.chalupatech.com` |

### Phase 3 — Cutover verification (manual, after runbook)

Not PR-gating; executed after the runbook completes.

| Check | Pass = |
|---|---|
| HA UI loads with restored auth | login screen accepts old credentials |
| Restored automations visible | expected automation count in Settings → Automations |
| Z-Wave JS UI populated | expected node count, names intact |
| Round-trip Z-Wave control | a device responds within 1–2 s |
| One automation fires correctly | known trigger → expected action |
| No persistent red banners | Settings → System → Logs is clean or documented exceptions |

## Open questions / assumptions

These are not blockers, but flag them at implementation time:

- **Aeotec USB vendor:product ID.** Spec lists two possibilities (`0658:0200` Sigma Designs, `10c4:ea60` Silicon Labs CP2102) based on common Aeotec firmware variants. Runbook step 1.2 has the implementer identify the actual ID via `lsusb` on the Proxmox host before creating the mapping.
- **HAOS image filename convention.** The HAOS GitHub releases use `haos_ova-X.Y.qcow2.xz` (note the dash before the version). Confirm by visiting the releases page during implementation; if the filename uses an underscore in current releases, fix the Ansible task and the Pulumi `ImportFrom` path together.
- **HACS GitHub PAT scopes.** Spec says `read:packages, read:org`. Latest HACS may require additional scopes; confirm against current HACS docs during runbook step 4.2.
- **Old HA Z-Wave controller hardware family.** Spec assumes the old HA used the same Aeotec Z-Stick 10 Pro (since user stated the dongle is migrating). If the old HA used a different Z-Wave controller and only the dongle is migrating, the NVM is not portable and the runbook collapses to "re-pair each device." Cross-check at runbook step 5.1.
- **`gitops/apps/infra-tools/` ApplicationSet shape.** Spec assumes the `infra-tools` ApplicationSet globs `gitops/apps/infra-tools/*`. Implementer should read `gitops/bootstrap/applicationsets/` and confirm before placing the wrapper there; if the structure differs, adjust placement to match.
- **Pulumi qcow2 disk-import API surface.** Spec writes `Disks[0].ImportFrom: "/var/lib/vz/template/iso/haos_ova-<ver>.qcow2"`. The pulumi-proxmoxve v7.13.0 SDK's actual field may be `Disks[0].FileId` referencing `<datastore>:import/<filename>`, a separate `proxmoxve.download.File` resource, or `ImportFrom` as written. Implementer confirms against the SDK before writing the Go file; the conceptual operation (use the qcow2 Ansible staged on the host as the VM's scsi0 disk on first apply, then `IgnoreChanges` thereafter) is unchanged.

## Memory updates after spec lands

The relevant memory file `project_homelab_roadmap.md` currently says:

> 6. **Home automation** — Home Assistant + Z-Wave in a NEW privileged LXC (not K8s). Pattern mirrors the Plex LXC: privileged container, USB device passthrough for Z-Wave dongle. Bypasses Talos's no-USB constraint.

After this spec is approved, that line is updated to reflect the actual hosting shape:

> 6. **Home automation** — Home Assistant OS in a Proxmox VM (VMID 250, 4 vCPU, 8 GB RAM, 60 GB disk, IP 192.168.1.234). Pulumi-managed in the `chalupa-infra` stack, USB passthrough for the Aeotec Z-Stick 10 Pro (Z-Wave 800; Zigbee dormant), Traefik ingress at `homeassistant.frame.chalupatech.com`. Backup-restore from existing HA (HA Container flavor, same LAN, same dongle) via one-shot manual runbook after the code PR lands.

The roadmap memory update happens when the spec PR lands, not during this brainstorm.
