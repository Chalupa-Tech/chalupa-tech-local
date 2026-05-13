# Home Automation (#6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a Home Assistant OS VM on `pve1` with Aeotec Z-Stick 10 Pro USB passthrough and Traefik HTTPS ingress at `homeassistant.frame.chalupatech.com`, in one PR. Cutover from the existing HA instance (HA Container, same LAN, same dongle) is a separate manual runbook executed by the human after merge — *not in scope of this plan*.

**Architecture:** Pulumi declares a new VM in the `chalupa-infra` stack (`pulumi/homeassistant.go`, 4 vCPU / 8 GB / 60 GB / VMID 250 / IP 192.168.1.234), referencing a named Proxmox Resource Mapping for the dongle. An Ansible task in `proxmox_prep` pre-stages the HAOS qcow2 image on the host so Pulumi can use it as the VM's boot disk. A small wrapper chart in `gitops/apps/infra-tools/homeassistant/` adds an ExternalName Service + Middleware + IngressRoute that routes Traefik to the off-cluster VM.

**Tech Stack:** Pulumi Go (`muhlba91/pulumi-proxmoxve` v7.13.0), Ansible (`get_url` + `command`), Helm wrapper chart with Traefik CRDs (`IngressRoute`, `Middleware`), ArgoCD ApplicationSet auto-discovery.

**Spec reference:** `docs/superpowers/specs/2026-05-12-home-automation-design.md`

---

## Prerequisites (must be true before Task 1)

- Worktree created for this work via `superpowers:using-git-worktrees` (subagent-driven-development handles this if you're using that mode).
- SSH access to `pve1` at 192.168.1.223 with `~/.ssh/pulumi_proxmox_runner` (per CLAUDE.md).
- Tailscale connection to the local network (per CLAUDE.md — Pulumi preview needs Proxmox API reachability).
- Pulumi CLI logged into the project's state backend.

---

## Task 1: Reconnaissance — verify external facts the spec deferred

**Why this is a task and not just notes:** the spec's "Open questions" section explicitly flags four items needing implementation-time verification. They all need to be answered before any code is written — wrong answers here cascade into broken Pulumi state, failed CI, or a wedged VM. None of these involve writing code; the output of this task is a set of confirmed values used by later tasks.

**Files:** none in this task — output is captured in PR description / commit-message context.

- [ ] **Step 1: Pin HAOS version and capture checksum**

Visit `https://github.com/home-assistant/operating-system/releases` in a browser. Find the latest stable release (current as of plan: HAOS 13.x line). Click into the release to find the qcow2 asset, typically named `haos_ova-<ver>.qcow2.xz`.

Verify the file exists with HTTP HEAD:

```bash
HAOS_VER=13.2   # replace with the actual latest stable
curl -fsSI "https://github.com/home-assistant/operating-system/releases/download/${HAOS_VER}/haos_ova-${HAOS_VER}.qcow2.xz" | head -1
```

Expected: `HTTP/2 200` (or 302→200 after redirect).

If the filename uses an underscore (`haos_ova_13.2.qcow2.xz`) instead of a dash, use that — capture the exact filename and pass it to later tasks. Do NOT proceed if any redirect lands on a 404.

Now capture the sha256 checksum. The release page has a checksums file. Easiest:

```bash
curl -fsSL "https://github.com/home-assistant/operating-system/releases/download/${HAOS_VER}/haos_ova-${HAOS_VER}.qcow2.xz.sha256" 2>/dev/null \
  | awk '{print $1}'
```

If that returns the sha256, record it. If the release uses a different checksum filename (e.g., `SHA256SUMS`), find the right URL on the release page. **Record:** `HAOS_VER`, exact filename (dash vs underscore), sha256.

- [ ] **Step 2: Confirm pulumi-proxmoxve disk-import API surface**

The spec's `Disks[0].ImportFrom: "/path/to/file.qcow2"` is a guess. Verify against the actual SDK before writing the Go file.

```bash
cd /path/to/worktree/pulumi
grep -rn "ImportFrom\|FileId" $(go env GOMODCACHE)/github.com/muhlba91/pulumi-proxmoxve/sdk/v7@*/go/proxmoxve/vm/pulumiTypes.go 2>/dev/null | head -20
```

Look for `VirtualMachineDiskArgs` struct fields. The field is one of:

- **`ImportFrom`** — accepts a path string. Use as-written in spec.
- **`FileId`** — accepts a Proxmox storage volume identifier like `local:import/haos_ova-13.2.qcow2`. You'd need to upload the qcow2 to Proxmox storage's `import` content type first (the Ansible task may need to use `pveam` or `qm importdisk` instead of just placing a file).
- A separate resource (e.g., `proxmoxve.download.File`) that returns a volume reference.

Pick the one that exists in v7.13.0. Document the choice. If `ImportFrom` exists but is documented as accepting a `<datastore>:import/<filename>` form (not a host path), use that form and have Ansible place the file under `/var/lib/vz/import/` (the directory backing the `local:import` content) instead of `/var/lib/vz/template/iso/`.

**Record:** which field, what value form it expects, and what host path the qcow2 needs to land at.

- [ ] **Step 3: Identify the Aeotec dongle USB vendor:product ID**

```bash
ssh -i ~/.ssh/pulumi_proxmox_runner root@192.168.1.223 'lsusb'
```

Look for a line mentioning "Aeotec", "Sigma Designs", or "Silicon Labs CP210x". Common Aeotec IDs: `0658:0200` (Sigma Designs) or `10c4:ea60` (Silicon Labs UART bridge). Record the vendor:product ID and the device's bus/port. If multiple Aeotec-related entries appear (e.g., one for the Zigbee chip and one for the Z-Wave chip on the combo dongle), record all.

**Record:** vendor:product ID(s), bus/port.

- [ ] **Step 4: Confirm VMID 250 is free**

```bash
ssh -i ~/.ssh/pulumi_proxmox_runner root@192.168.1.223 'qm list && pct list'
```

Expected: no entry for VMID 250 in `qm list` (VMs) and no CT 250 in `pct list` (LXCs). If 250 is taken, pick the next free number ≥ 250 and update Task 6's VMID reference accordingly.

- [ ] **Step 5: Confirm `infra-tools` ApplicationSet shape**

Already known from spec recon, but confirm in-worktree:

```bash
cat /path/to/worktree/gitops/bootstrap/applicationsets/infra-tools.yaml
```

Expected:
- `generators.git.directories.path: gitops/apps/infra-tools/*`
- `template.spec.destination.namespace: '{{.path.basename}}'`
- `syncOptions: [CreateNamespace=true, ServerSideApply=true, SkipDryRunOnMissingResource=true]`

If the shape is different, adjust the wrapper chart location in Tasks 7–9 to match. If it matches: proceed.

- [ ] **Step 6: Manual one-time Proxmox UI prep** *(must happen before merge, can happen any time during planning)*

In Proxmox UI:

1. `Datacenter → Resource Mappings → USB Devices → Add`
2. Name: `aeotec-zstick-10`
3. Node: `proxmox` (the only node)
4. Select the Aeotec device from the dropdown (use the vendor:product from Step 3 to disambiguate if multiple USB devices appear)
5. Save

This mapping is referenced by name from Pulumi in Task 6. If you skip it, `pulumi up` will fail with `usb mapping not found`.

- [ ] **Step 7: Record reconnaissance results**

Write the captured values somewhere accessible for later tasks. Easiest: a scratch note in the worktree (don't commit it):

```bash
cat > /tmp/ha-recon.txt <<EOF
HAOS_VER=13.2
HAOS_FILENAME=haos_ova-13.2.qcow2.xz
HAOS_SHA256=<paste>
PULUMI_DISK_FIELD=<ImportFrom|FileId|other>
PULUMI_DISK_VALUE_FORM=<path|datastore:import/file>
HOST_QCOW2_PATH=<chosen path>
AEOTEC_USB_VENDOR_PRODUCT=<e.g., 0658:0200>
VMID=250
USB_MAPPING_NAME=aeotec-zstick-10
USB_MAPPING_CREATED=<yes|no>
EOF
```

These values feed Tasks 3, 4, and 6. **No commit for this task** — it's pure information gathering.

---

## Task 2: Add HAOS image variables to Ansible group_vars

**Files:**
- Modify: `ansible/group_vars/all.yml`

- [ ] **Step 1: Read current state**

```bash
cat ansible/group_vars/all.yml
```

Expected current content:
```yaml
---
truenas_vm_ip: "192.168.1.40"
```

- [ ] **Step 2: Add HAOS variables**

Edit `ansible/group_vars/all.yml` to add the three HAOS values from Task 1 Step 1, with a comment cross-referencing the Pulumi config. Replace the file's content with:

```yaml
---
truenas_vm_ip: "192.168.1.40"

# Home Assistant OS image pinned for proxmox_prep download.
# Keep in sync with pulumi/Pulumi.proxmox.yaml -> chalupa-infra:haosVersion.
haos_version: "13.2"
haos_image_filename: "haos_ova-13.2.qcow2.xz"
haos_image_sha256: "sha256:<paste actual sha256 from recon>"
```

Use the actual `HAOS_VER`, filename, and sha256 from `/tmp/ha-recon.txt`. The `sha256:` prefix on `haos_image_sha256` is required by `get_url`'s checksum format.

- [ ] **Step 3: Lint**

```bash
cd ansible && ansible-lint group_vars/all.yml
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add ansible/group_vars/all.yml
git commit -m "feat(ansible): pin HAOS version for proxmox_prep download

Adds haos_version, haos_image_filename, and haos_image_sha256 to
group_vars so the upcoming HAOS qcow2 download task can reference
them. Kept in sync with pulumi/Pulumi.proxmox.yaml's haosVersion key.

Spec: docs/superpowers/specs/2026-05-12-home-automation-design.md"
```

---

## Task 3: Add HAOS qcow2 download task to `proxmox_prep` role

**Files:**
- Modify: `ansible/roles/proxmox_prep/tasks/main.yml`

- [ ] **Step 1: Read the existing role for pattern reference**

The role already has a similar pattern for the Talos ISO (`Download Talos ISO with qemu-guest-agent`, line ~108) — follow that style. Note: the Talos task uses `stat` + `get_url with when:` for idempotency; we'll use `get_url`'s built-in `checksum:` for the same effect more cleanly.

- [ ] **Step 2: Add the two HAOS tasks at the bottom of `tasks/main.yml`**

Append the following block at the bottom of `ansible/roles/proxmox_prep/tasks/main.yml`, after the Talos ISO download:

```yaml

# --- Home Assistant OS qcow2 (for the HAOS VM created by Pulumi) ---
- name: Ensure HAOS qcow2 image (compressed) is present on host
  ansible.builtin.get_url:
    url: "https://github.com/home-assistant/operating-system/releases/download/{{ haos_version }}/{{ haos_image_filename }}"
    dest: "/var/lib/vz/template/iso/{{ haos_image_filename }}"
    checksum: "{{ haos_image_sha256 }}"
    mode: "0644"

- name: Decompress HAOS qcow2
  ansible.builtin.command:
    cmd: "xz --decompress --keep --force /var/lib/vz/template/iso/{{ haos_image_filename }}"
    creates: "/var/lib/vz/template/iso/{{ haos_image_filename | regex_replace('\\.xz$', '') }}"
```

> **If Task 1 Step 2 chose a `<datastore>:import/<filename>` path instead of a direct file path:** change the two `dest:`/`creates:` paths from `/var/lib/vz/template/iso/` to `/var/lib/vz/import/` and ensure the `local` storage in Proxmox has `import` listed in its content types. The decompression line is unchanged.

- [ ] **Step 3: Lint**

```bash
cd ansible && ansible-lint
```

Expected: no errors. Common pitfalls: `command:` tasks need either `changed_when:` or `creates:` to satisfy lint — `creates:` is provided.

- [ ] **Step 4: Dry-run against pve1**

```bash
cd ansible && ansible-playbook -i inventory.yml site.yml --check --diff
```

Expected:
- All existing tasks report `ok` (no drift on already-prepped host).
- The new `Ensure HAOS qcow2 image (compressed) is present on host` reports `changed` (will download) or `ok` (already present).
- The new `Decompress HAOS qcow2` reports `skipped` in `--check` mode because the `command` module can't dry-run a state change. This is expected; CI's full apply will run it for real.

If `--check` fails with a connection error, verify Tailscale is up and `~/.ssh/pulumi_proxmox_runner` is configured.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/proxmox_prep/tasks/main.yml
git commit -m "feat(ansible): download and decompress HAOS qcow2 in proxmox_prep

Adds two tasks to the proxmox_prep role that stage the Home Assistant
OS qcow2 image at /var/lib/vz/template/iso/. The pinned version,
filename, and sha256 live in group_vars/all.yml. The image is used
by the Pulumi HAOS VM definition that lands in this same PR.

Spec: docs/superpowers/specs/2026-05-12-home-automation-design.md"
```

---

## Task 4: Add `haosVersion` to Pulumi config

**Files:**
- Modify: `pulumi/Pulumi.proxmox.yaml`

- [ ] **Step 1: Read current state**

```bash
cat pulumi/Pulumi.proxmox.yaml
```

Expected current content:
```yaml
environment:
  - chalupa-infra/proxmox
config:
  proxmoxve:insecure: true
```

- [ ] **Step 2: Add the HAOS version config key**

Edit `pulumi/Pulumi.proxmox.yaml` to add the version key. Replace the file's content with:

```yaml
environment:
  - chalupa-infra/proxmox
config:
  proxmoxve:insecure: true
  # Home Assistant OS image version. Used by pulumi/homeassistant.go to
  # locate the qcow2 staged on the host by Ansible. Keep in sync with
  # ansible/group_vars/all.yml -> haos_version.
  chalupa-infra:haosVersion: "13.2"
```

Use the same `HAOS_VER` value from Task 2.

- [ ] **Step 3: Verify Pulumi accepts the config**

```bash
cd pulumi && pulumi config -s tayvenb13/chalupa-infra/proxmox
```

Expected: lists `chalupa-infra:haosVersion: 13.2` among the config values. If Pulumi state isn't local, this command may need the `--show-secrets=false` flag — that's fine.

- [ ] **Step 4: Commit**

```bash
git add pulumi/Pulumi.proxmox.yaml
git commit -m "feat(pulumi): add haosVersion config key for HAOS VM

Mirrors ansible/group_vars/all.yml's haos_version. The new
homeassistant.go (added in the next commit) reads this value via
ctx.GetConfig to construct the qcow2 import path.

Spec: docs/superpowers/specs/2026-05-12-home-automation-design.md"
```

---

## Task 5: Create `pulumi/homeassistant.go`

**Files:**
- Create: `pulumi/homeassistant.go`
- Modify: `pulumi/main.go`

- [ ] **Step 1: Read existing patterns for reference**

```bash
cat pulumi/truenas.go     # Same shape as what we'll write (single VM, named hostpci/usb mapping, Protect(true))
cat pulumi/main.go        # We'll add a call to createHomeAssistantVM
```

- [ ] **Step 2: Create `pulumi/homeassistant.go`**

Use the Pulumi disk-import API surface confirmed in Task 1 Step 2. Below is the **`ImportFrom` variant** (most common in v7). If recon told you to use `FileId`-with-`<datastore>:import/<filename>`, swap the `Disks` block accordingly; the rest of the file is identical.

Write the following to `pulumi/homeassistant.go`:

```go
package main

import (
	"fmt"

	"github.com/muhlba91/pulumi-proxmoxve/sdk/v7/go/proxmoxve"
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v7/go/proxmoxve/vm"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

func createHomeAssistantVM(ctx *pulumi.Context, pveProvider *proxmoxve.Provider) error {
	cfg := config.New(ctx, "chalupa-infra")
	haosVersion := cfg.Require("haosVersion")

	// HAOS qcow2 staged by Ansible's proxmox_prep role at
	// /var/lib/vz/template/iso/haos_ova-<ver>.qcow2 (decompressed).
	// Filename pattern must match ansible/group_vars/all.yml's
	// haos_image_filename minus the .xz suffix.
	haosImagePath := fmt.Sprintf("/var/lib/vz/template/iso/haos_ova-%s.qcow2", haosVersion)

	_, err := vm.NewVirtualMachine(ctx, "homeassistant", &vm.VirtualMachineArgs{
		VmId:        pulumi.Int(250),
		NodeName:    pulumi.String("proxmox"),
		Name:        pulumi.String("homeassistant"),
		Description: pulumi.String("Home Assistant OS (Managed by Pulumi)"),
		Bios:        pulumi.String("ovmf"),
		Machine:     pulumi.String("q35"),

		Cpu: &vm.VirtualMachineCpuArgs{
			Cores: pulumi.Int(4),
			Type:  pulumi.String("host"),
		},
		Memory: &vm.VirtualMachineMemoryArgs{
			Dedicated: pulumi.Int(8192),
		},
		NetworkDevices: vm.VirtualMachineNetworkDeviceArray{
			&vm.VirtualMachineNetworkDeviceArgs{
				Bridge: pulumi.String("vmbr0"),
			},
		},
		Disks: vm.VirtualMachineDiskArray{
			&vm.VirtualMachineDiskArgs{
				DatastoreId: pulumi.String("local-lvm"),
				Interface:   pulumi.String("scsi0"),
				Size:        pulumi.Int(60),
				FileFormat:  pulumi.String("raw"),
				ImportFrom:  pulumi.String(haosImagePath),
			},
		},
		Usbs: vm.VirtualMachineUsbArray{
			&vm.VirtualMachineUsbArgs{
				Mapping: pulumi.String("aeotec-zstick-10"),
				Usb3:    pulumi.Bool(true),
			},
		},
		BootOrders: pulumi.StringArray{
			pulumi.String("scsi0"),
		},
		Agent: &vm.VirtualMachineAgentArgs{
			Enabled: pulumi.Bool(false),
		},
		Started: pulumi.Bool(true),
		OnBoot:  pulumi.Bool(true),
		OperatingSystem: &vm.VirtualMachineOperatingSystemArgs{
			Type: pulumi.String("l26"),
		},
		Startup: &vm.VirtualMachineStartupArgs{
			Order: pulumi.Int(6),
		},
		Vga: &vm.VirtualMachineVgaArgs{
			Type: pulumi.String("vmware"),
		},
	},
		pulumi.Provider(pveProvider),
		// IgnoreChanges["disk"] prevents Pulumi from re-importing the qcow2
		// on every apply (ImportFrom is one-shot on creation; later applies
		// would try to recreate the disk and lose state). IgnoreChanges["started"]
		// matches the project pattern from TrueNAS/Talos.
		pulumi.IgnoreChanges([]string{"started", "disks"}),
		// Protect(true) matches TrueNAS posture — HA holds Z-Wave network state
		// (in the dongle NVM, which an accidental VM teardown wouldn't destroy,
		// but accumulating HA config + history would be lost).
		pulumi.Protect(true),
	)
	return err
}
```

**Notes embedded in the code:** `IgnoreChanges` includes `"disks"` (plural — match the SDK field name) so subsequent applies don't try to re-import the qcow2. `Agent.Enabled: false` because HAOS doesn't ship qemu-guest-agent by default and we don't need `WaitForIp` (we set the static IP manually via HAOS UI). The `Vga: vmware` line matches the project pattern from `truenas.go`/`pulumi-talos/main.go`.

- [ ] **Step 3: Wire it into `pulumi/main.go`**

Read the current `pulumi/main.go`:

```bash
cat pulumi/main.go
```

You should see a `Run` function with `createTrueNASVM(ctx, pveProvider)` already called. Add `createHomeAssistantVM` directly after the TrueNAS call.

Edit `pulumi/main.go`: between the existing `createTrueNASVM` line and the `ctx.Export("plex-ip", ...)` line, add:

```go
		// Create Home Assistant OS VM (sub-project #6)
		if err := createHomeAssistantVM(ctx, pveProvider); err != nil {
			return err
		}
```

The resulting block in `Run` should look like (existing code shown for context):

```go
		// Create TrueNAS VM
		if err := createTrueNASVM(ctx, pveProvider); err != nil {
			return err
		}

		// Create Home Assistant OS VM (sub-project #6)
		if err := createHomeAssistantVM(ctx, pveProvider); err != nil {
			return err
		}

		// Plex LXC container (VMID 200) is managed by Ansible, not Pulumi.
		// Proxmox restricts LXC device passthrough and feature flags to
		// root@pam, which API tokens cannot provide. Ansible runs as root
		// on the host via SSH, so it has no such restrictions.
		ctx.Export("plex-ip", pulumi.String("192.168.1.224"))
```

- [ ] **Step 4: Build**

```bash
cd pulumi && go build ./...
```

Expected: no errors. Common failures: missing `config` import (line `"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"`), wrong SDK field name (`ImportFrom` vs `FileId` — if you see a struct-field error, refer back to Task 1 Step 2 reconnaissance).

- [ ] **Step 5: Lint**

```bash
cd pulumi && golangci-lint run
```

Expected: no errors. If `golangci-lint` is not installed locally, this is OK to skip locally — CI will run it on PR.

- [ ] **Step 6: Pulumi preview**

```bash
cd pulumi && pulumi preview -s tayvenb13/chalupa-infra/proxmox
```

Expected output: one create operation for `proxmoxve:VM/virtualMachine:VirtualMachine homeassistant`, zero updates, zero deletes. The TrueNAS VM should show as `unchanged`. If the preview shows the TrueNAS VM as anything other than unchanged, STOP — something is wrong with the diff (likely an `IgnoreChanges` or provider version regression). Investigate before committing.

Capture the preview output for the PR description.

- [ ] **Step 7: Commit**

```bash
git add pulumi/homeassistant.go pulumi/main.go
git commit -m "feat(pulumi): declare HAOS VM (VMID 250) with USB passthrough

Creates a new VM via the muhlba91/pulumi-proxmoxve provider:
- VMID 250, 4 vCPU, 8192 MB, 60 GB scsi0 on local-lvm
- HAOS qcow2 imported from /var/lib/vz/template/iso/ (staged by Ansible)
- Aeotec Z-Stick 10 Pro via named USB Resource Mapping 'aeotec-zstick-10'
- IP 192.168.1.234 set in HAOS UI on first boot (no DHCP wait)
- pulumi.Protect(true) — accidental teardown loses HA config + history
- IgnoreChanges ['started', 'disks'] — ImportFrom is one-shot

Spec: docs/superpowers/specs/2026-05-12-home-automation-design.md"
```

---

## Task 6: Create the wrapper chart skeleton (Chart.yaml + values.yaml + .helmignore)

**Files:**
- Create: `gitops/apps/infra-tools/homeassistant/Chart.yaml`
- Create: `gitops/apps/infra-tools/homeassistant/values.yaml`
- Create: `gitops/apps/infra-tools/homeassistant/.helmignore`

- [ ] **Step 1: Create the directory**

```bash
mkdir -p gitops/apps/infra-tools/homeassistant/templates
```

- [ ] **Step 2: Write `Chart.yaml`**

This is a manifests-only wrapper — no upstream chart dependency. Write to `gitops/apps/infra-tools/homeassistant/Chart.yaml`:

```yaml
apiVersion: v2
name: homeassistant-wrapper
description: |
  Traefik ingress for the off-cluster Home Assistant OS VM at
  192.168.1.234:8123. Renders an ExternalName Service, an HTTP→HTTPS
  redirect Middleware, and IngressRoute entries on the `web` and
  `websecure` entrypoints. The HAOS VM itself is provisioned by
  Pulumi (pulumi/homeassistant.go); this chart only handles K8s-level
  HTTPS routing into it.
type: application
version: 0.1.0
appVersion: "OS"
```

- [ ] **Step 3: Write `values.yaml`**

Write to `gitops/apps/infra-tools/homeassistant/values.yaml`:

```yaml
# Off-cluster HAOS VM coordinates. Used by the ExternalName Service
# and by the IngressRoute services entries.
homeassistant:
  host: "homeassistant.frame.chalupatech.com"
  externalIP: "192.168.1.234"
  port: 8123
```

- [ ] **Step 4: Write `.helmignore`**

> **Lesson from sub-project #3:** the `.helmignore` MUST NOT exclude `charts/` (Helm uses that directory for vendored deps). The repo's media wrappers use a minimal `.helmignore` that excludes only editor/OS metadata.

Write to `gitops/apps/infra-tools/homeassistant/.helmignore`:

```
# Editor and OS metadata
.DS_Store
.idea/
.vscode/
*.swp
*.swo
*~

# Plan or local scratch files
*.bak
*.tmp
```

Do **not** add `charts/`, `Chart.lock`, or `templates/` here — they are required artifacts.

- [ ] **Step 5: Render the (still-empty) chart**

```bash
cd gitops/apps/infra-tools/homeassistant && helm template . --debug 2>&1 | head -20
```

Expected: `helm template` completes with empty output (no templates yet) and no errors. If it errors with "Chart.yaml not found," check the working directory.

- [ ] **Step 6: Commit**

```bash
git add gitops/apps/infra-tools/homeassistant/
git commit -m "feat(gitops): scaffold homeassistant wrapper chart

Empty wrapper chart that will receive Traefik ingress resources for
the off-cluster HAOS VM. Picked up by the existing 'infra-tools-apps'
ApplicationSet which globs gitops/apps/infra-tools/*.

Spec: docs/superpowers/specs/2026-05-12-home-automation-design.md"
```

---

## Task 7: Add the ExternalName Service and Middleware templates

**Files:**
- Create: `gitops/apps/infra-tools/homeassistant/templates/externalname.yaml`
- Create: `gitops/apps/infra-tools/homeassistant/templates/middleware-redirect-https.yaml`

- [ ] **Step 1: Read the nzbget wrapper as the redirect-Middleware reference**

```bash
cat gitops/apps/media/nzbget/templates/redirect-middleware.yaml
```

That's the exact pattern — copy its structure. Same `sync-wave: "-1"` annotation so the Middleware exists before the IngressRoute references it.

- [ ] **Step 2: Write the ExternalName Service template**

Write to `gitops/apps/infra-tools/homeassistant/templates/externalname.yaml`:

```yaml
---
# Routes Traefik (in-cluster) to the off-cluster HAOS VM. ExternalName
# resolves to the LAN IP via cluster DNS, and Traefik treats it like any
# other Service backend.
apiVersion: v1
kind: Service
metadata:
  name: homeassistant
  namespace: homeassistant
spec:
  type: ExternalName
  externalName: {{ .Values.homeassistant.externalIP | quote }}
  ports:
    - name: http
      port: {{ .Values.homeassistant.port }}
      protocol: TCP
```

> **Note on ExternalName + IP:** Kubernetes ExternalName Services historically required a DNS name, but Traefik handles ExternalName-with-IP correctly via its native IngressRoute controller. If `kubectl apply` rejects the manifest (some kubectl versions enforce the DNS-only convention via OpenAPI), the alternative is a headless Service + manually-created Endpoints/EndpointSlice. The IngressRoute pattern in the rest of the repo points at *in-cluster* Services, so this is the one place this plan diverges; report any apply-time rejection back to the reviewer.

- [ ] **Step 3: Write the Middleware template**

Write to `gitops/apps/infra-tools/homeassistant/templates/middleware-redirect-https.yaml`:

```yaml
---
# HTTP -> HTTPS redirect, attached to the `web` entrypoint IngressRoute
# in ingressroute.yaml. sync-wave -1 ensures it exists before the
# IngressRoute that references it (otherwise the IngressRoute would
# error temporarily on first sync).
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-https
  namespace: homeassistant
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  redirectScheme:
    scheme: https
    permanent: true
```

- [ ] **Step 4: Render and verify**

```bash
cd gitops/apps/infra-tools/homeassistant && helm template . --namespace homeassistant
```

Expected output: two resources, one `Service` (type ExternalName, externalName "192.168.1.234", port 8123) and one `Middleware` (redirectScheme https permanent). Confirm the values from `values.yaml` interpolated correctly.

- [ ] **Step 5: Commit**

```bash
git add gitops/apps/infra-tools/homeassistant/templates/externalname.yaml gitops/apps/infra-tools/homeassistant/templates/middleware-redirect-https.yaml
git commit -m "feat(gitops): add ExternalName Service and redirect Middleware for HA

ExternalName Service routes in-cluster traffic to the off-cluster HAOS
VM at 192.168.1.234:8123. Middleware (sync-wave -1) implements the
HTTP→HTTPS redirect that the IngressRoute on the 'web' entrypoint will
reference.

Spec: docs/superpowers/specs/2026-05-12-home-automation-design.md"
```

---

## Task 8: Add the IngressRoute (both entrypoints)

**Files:**
- Create: `gitops/apps/infra-tools/homeassistant/templates/ingressroute.yaml`

- [ ] **Step 1: Read the nzbget ingressroute as the canonical reference**

```bash
cat gitops/apps/media/nzbget/templates/ingressroute.yaml
```

Note the two-IngressRoute shape (one `web` with redirect middleware, one `websecure` with `tls: {}`).

- [ ] **Step 2: Write the IngressRoute template**

Write to `gitops/apps/infra-tools/homeassistant/templates/ingressroute.yaml`:

```yaml
---
# HTTP (port 80) entrypoint — redirected to HTTPS via Middleware.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: homeassistant-http
  namespace: homeassistant
  annotations:
    # Required: external-dns silently skips IngressRoutes lacking this target
    # annotation. See memory: project_external_dns_target_annotation.
    external-dns.alpha.kubernetes.io/target: "192.168.1.230"
spec:
  entryPoints:
    - web
  routes:
    - match: Host({{ .Values.homeassistant.host | quote }})
      kind: Rule
      services:
        - name: homeassistant
          port: {{ .Values.homeassistant.port }}
      middlewares:
        - name: redirect-to-https
          namespace: homeassistant
---
# HTTPS (port 443) entrypoint — Traefik default cert is the wildcard,
# so `tls: {}` is enough (same pattern as the media stack).
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: homeassistant-https
  namespace: homeassistant
  annotations:
    external-dns.alpha.kubernetes.io/target: "192.168.1.230"
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host({{ .Values.homeassistant.host | quote }})
      kind: Rule
      services:
        - name: homeassistant
          port: {{ .Values.homeassistant.port }}
  tls: {}
```

- [ ] **Step 3: Render and verify**

```bash
cd gitops/apps/infra-tools/homeassistant && helm template . --namespace homeassistant
```

Expected: four resources total now (Service, Middleware, two IngressRoutes). Confirm:
- IngressRoute `homeassistant-http` has `entryPoints: [web]` and `middlewares: [redirect-to-https]`
- IngressRoute `homeassistant-https` has `entryPoints: [websecure]` and `tls: {}`
- Both have annotation `external-dns.alpha.kubernetes.io/target: "192.168.1.230"`
- Both `match: Host(\`homeassistant.frame.chalupatech.com\`)`

- [ ] **Step 4: Optional — validate against cluster CRDs (if you have kubectl access)**

```bash
helm template . --namespace homeassistant | kubectl apply --dry-run=server -f - --validate=true
```

Expected: server-side validation passes. If you don't have kubectl access locally, skip — CI doesn't run this either; ArgoCD will be the first thing to apply.

- [ ] **Step 5: Commit**

```bash
git add gitops/apps/infra-tools/homeassistant/templates/ingressroute.yaml
git commit -m "feat(gitops): add IngressRoute for homeassistant.frame.chalupatech.com

Two IngressRoutes — 'web' entrypoint with redirect-to-https middleware,
'websecure' entrypoint with Traefik default wildcard cert. Both
annotated with external-dns target=192.168.1.230 (silent-skip
gotcha from previous sub-projects).

Spec: docs/superpowers/specs/2026-05-12-home-automation-design.md"
```

---

## Task 9: Open the PR and gather Phase 1 verification evidence

**Files:** none (PR metadata + verification commands)

- [ ] **Step 1: Push the branch**

```bash
git push -u origin <branch-name>
```

- [ ] **Step 2: Re-run all Phase 1 verification commands locally and capture output**

```bash
cd pulumi && go build ./... && echo OK
cd pulumi && golangci-lint run && echo OK
cd ansible && ansible-lint && echo OK
cd ansible && ansible-playbook -i inventory.yml site.yml --check --diff 2>&1 | tail -30
cd pulumi && pulumi preview -s tayvenb13/chalupa-infra/proxmox 2>&1 | tail -40
cd gitops/apps/infra-tools/homeassistant && helm template . --namespace homeassistant 2>&1 | tail -60
```

Save each output. The PR description will paste them under a "Phase 1 verification" heading.

- [ ] **Step 3: Probe the HAOS image URL one more time** (per `feedback_verify_image_tag_on_registry.md`)

```bash
HAOS_VER=$(grep haos_version ansible/group_vars/all.yml | awk -F'"' '{print $2}')
HAOS_FILE=$(grep haos_image_filename ansible/group_vars/all.yml | awk -F'"' '{print $2}')
curl -fsSI "https://github.com/home-assistant/operating-system/releases/download/${HAOS_VER}/${HAOS_FILE}" | head -1
```

Expected: `HTTP/2 200`. Failure = revisit Task 1 Step 1 and bump the version pin.

- [ ] **Step 4: Open the PR**

```bash
gh pr create --title "feat(home-automation): HAOS VM + Traefik ingress (sub-project #6)" --body "$(cat <<'EOF'
## Summary

Stand up sub-project #6's home automation foundation: a Home Assistant OS VM on `pve1` (VMID 250, 4 vCPU / 8 GB / 60 GB, IP 192.168.1.234) with USB passthrough of the Aeotec Z-Stick 10 Pro, plus Traefik HTTPS ingress at `homeassistant.frame.chalupatech.com`. Cutover from the existing HA Container instance (same LAN, same dongle) happens as a one-shot manual runbook **after this PR merges** — not in this PR's scope.

## What's in the PR

- **Ansible:** `proxmox_prep` role pre-stages the pinned HAOS qcow2 image on the Proxmox host
- **Pulumi:** new `pulumi/homeassistant.go` adds the VM in the `chalupa-infra` stack; USB device via named Resource Mapping `aeotec-zstick-10`; `pulumi.Protect(true)` matching TrueNAS posture
- **GitOps:** new wrapper chart `gitops/apps/infra-tools/homeassistant/` with an ExternalName Service, HTTP→HTTPS redirect Middleware, and IngressRoute on both `web` and `websecure` entrypoints

## What's NOT in this PR

- Cutover (config restore, Z-Wave NVM import, integration audit) — manual runbook in spec § "Cutover runbook"
- Zigbee radio activation — explicit non-goal (Decision 2b in spec)
- Postgres recorder, OIDC auth, NFS backup destination, new integrations — non-goals
- The one-time **Proxmox UI Resource Mapping** `aeotec-zstick-10` — created manually before merging (gating prerequisite, Task 1 Step 6 of plan)

## Spec & plan

- Design: `docs/superpowers/specs/2026-05-12-home-automation-design.md`
- Plan: `docs/superpowers/plans/2026-05-12-home-automation-plan.md`

## Phase 1 verification (this PR)

<details>
<summary>Local pre-merge gates</summary>

(paste outputs from Step 2 here)

</details>

## Phase 2 verification (after merge — gated by CI's existing `Verify GitOps reconciliation` step)

Will be captured as a follow-up comment on this PR once CI completes:

- [ ] `ssh pve1 ls /var/lib/vz/template/iso/haos_ova-*.qcow2` — file exists
- [ ] `ssh pve1 qm status 250` — `status: running`
- [ ] Proxmox UI → VM 250 → Hardware lists `aeotec-zstick-10`
- [ ] `curl -k -o /dev/null -w '%{http_code}\n' http://192.168.1.234:8123` — `200`
- [ ] `kubectl get application -n argocd homeassistant -o jsonpath='{.status.sync.status} {.status.health.status}'` — `Synced Healthy`
- [ ] `curl -k -o /dev/null -w '%{http_code}\n' https://homeassistant.frame.chalupatech.com` — `200`
- [ ] `curl -v https://homeassistant.frame.chalupatech.com 2>&1 | grep 'subject:'` — wildcard

## Test plan

- [x] Pulumi go build
- [x] golangci-lint
- [x] ansible-lint
- [x] ansible-playbook --check --diff
- [x] pulumi preview shows 1 create / 0 update / 0 delete on `homeassistant`, TrueNAS unchanged
- [x] helm template renders the wrapper chart cleanly
- [x] HAOS image URL HEAD 200
- [ ] CI green on PR
- [ ] Phase 2 data-plane gates after merge

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: After opening, paste the captured outputs into the `<details>` block**

Either edit the PR body via `gh pr edit` or via the GitHub UI. Replace the `(paste outputs from Step 2 here)` placeholder with the real outputs from Step 2.

- [ ] **Step 6: Wait for CI to go green**

```bash
gh pr checks --watch
```

Expected: all jobs green. If `pulumi.yml` or `ansible.yml` fails, read the failure carefully — most likely culprit is the disk-import field name (Task 1 Step 2) or the image checksum (Task 2). Fix in a follow-up commit on the same branch; do NOT amend the existing commits.

---

## Task 10: Merge and run Phase 2 verification

**Files:** none (post-merge ops)

- [ ] **Step 1: Merge the PR**

Per CLAUDE.md: all changes via PR, CI is the source of truth. Use squash or merge — whichever the repo convention prefers (recent commits show standard merges; check `git log --merges main | head -5` for the pattern).

```bash
gh pr merge --squash --delete-branch
# OR
gh pr merge --merge --delete-branch
```

- [ ] **Step 2: Wait for `deploy.yml` to run on `main`**

```bash
gh run watch
```

Expected: deploy workflow green. Specifically:
- Stage 1 (Ansible host prep) reports the HAOS download/decompress tasks ran with `changed=1` on first run and `ok=0 changed=0` on subsequent runs.
- Stage 2a (Pulumi infra) reports `Created proxmoxve:vm:VirtualMachine homeassistant` once. If it reports anything other than that single create, investigate — TrueNAS should be untouched.

- [ ] **Step 3: Run Phase 2 verification commands and capture output**

```bash
# Host
ssh -i ~/.ssh/pulumi_proxmox_runner root@192.168.1.223 'ls -la /var/lib/vz/template/iso/haos_ova-*.qcow2 && qm status 250'

# HAOS reachable on LAN (HAOS welcome page on first boot, before onboarding)
curl -k -o /dev/null -w 'HAOS direct: %{http_code}\n' http://192.168.1.234:8123

# ArgoCD synced
kubectl get application -n argocd homeassistant -o jsonpath='{.metadata.name}: sync={.status.sync.status} health={.status.health.status}{"\n"}'

# Traefik route
curl -k -o /dev/null -w 'Via Traefik: %{http_code}\n' https://homeassistant.frame.chalupatech.com

# TLS subject
curl -v https://homeassistant.frame.chalupatech.com 2>&1 | grep -E 'subject:|issuer:'
```

Expected output (paste into PR comment as Phase 2 evidence):
```
... haos_ova-13.2.qcow2
status: running
HAOS direct: 200
homeassistant: sync=Synced health=Healthy
Via Traefik: 200
*  subject: CN=*.frame.chalupatech.com
*  issuer: ...Let's Encrypt...
```

- [ ] **Step 4: Comment on the PR with Phase 2 evidence**

```bash
gh pr comment <PR_NUMBER> --body "$(cat <<'EOF'
## Phase 2 verification — post-merge data plane

(paste outputs from Step 3 here)

All gates green. Sub-project #6 code shipped. Manual cutover runbook in spec § "Cutover runbook" remains for the human operator.
EOF
)"
```

If any gate fails, file the failure mode against the spec's failure-modes table (§ "Failure modes") and either fix-forward in a follow-up PR or roll back per the rollback section.

---

## Task 11: Update the roadmap memory

**Files:**
- Modify: `~/.claude/projects/-Users-tbigelow-Documents-code-chalupa-tech-local/memory/project_homelab_roadmap.md`

The roadmap memory currently describes sub-project #6 with the wrong hosting framing (privileged LXC). Update it now that the implementation is in.

- [ ] **Step 1: Read the current memory entry for #6**

```bash
sed -n '/^6\. \*\*Home automation\*\*/,/^7\. /p' ~/.claude/projects/-Users-tbigelow-Documents-code-chalupa-tech-local/memory/project_homelab_roadmap.md
```

Expected: a single line describing #6 as "privileged LXC" plus the rationale line about Talos USB constraints.

- [ ] **Step 2: Replace #6 entry**

In `project_homelab_roadmap.md`, replace the #6 line with:

```markdown
6. **Home automation** — Home Assistant OS in a Proxmox VM (VMID 250, 4 vCPU / 8 GB RAM / 60 GB disk, IP 192.168.1.234). Pulumi-managed in the `chalupa-infra` stack (`pulumi/homeassistant.go`), USB passthrough for the Aeotec Z-Stick 10 Pro via named Resource Mapping `aeotec-zstick-10` (Z-Wave 800 LR active; Zigbee radio dormant per Decision 2b). HAOS qcow2 staged by Ansible's `proxmox_prep` role at `/var/lib/vz/template/iso/`. Traefik ingress at `homeassistant.frame.chalupatech.com` via wrapper chart `gitops/apps/infra-tools/homeassistant/` (ExternalName Service → 192.168.1.234:8123). HACS day-1; SQLite recorder; built-in auth (TOTP recommended); local HAOS snapshots only (off-host backup deferred to #7). Cutover from existing HA Container instance (same LAN, same dongle) via one-shot manual runbook in the spec. **DONE \<DATE\>** (PR #\<N\>). Spec: `docs/superpowers/specs/2026-05-12-home-automation-design.md`. Plan: `docs/superpowers/plans/2026-05-12-home-automation-plan.md`.
```

Substitute the actual merge date and PR number.

- [ ] **Step 3: Update the top-line summary**

The frontmatter's `description:` field says "Stages 1, 2, 3, 4 done as of 2026-05-08." Update it to include the new completed stages. After this PR, the state is: 1, 2, 3, 4, 5, 5b, 6 done. Edit the description accordingly.

- [ ] **Step 4: No commit**

Memory updates are local to `~/.claude/projects/.../memory/` — not in the repo. No git operation.

---

## Self-review

After writing the complete plan, checked against the spec with fresh eyes:

**Spec coverage:**
- Architecture (VM, USB mapping, IP, sizing) → Task 5
- Repository layout (Ansible, Pulumi, gitops paths) → Tasks 2-8
- Ansible HAOS image download → Tasks 2, 3
- Pulumi VM with `Protect(true)`, `IgnoreChanges`, USB mapping → Task 5
- Traefik ingress (ExternalName, Middleware, IngressRoute with `external-dns` annotation) → Tasks 6-8
- Verification gates Phase 1 (CI lints, builds, previews) → Task 9
- Verification gates Phase 2 (post-merge data plane) → Task 10
- Verification gates Phase 3 (cutover runbook) → explicitly out of scope (handled by human after merge)
- USB Resource Mapping pre-merge manual creation → Task 1 Step 6
- VMID 250 collision check → Task 1 Step 4
- HAOS version verification → Task 1 Step 1, Task 9 Step 3
- pulumi-proxmoxve SDK API reconnaissance → Task 1 Step 2
- Aeotec USB vendor:product identification → Task 1 Step 3
- ApplicationSet shape confirmation → Task 1 Step 5
- Roadmap memory update → Task 11

**Placeholder scan:** Done. No "TBD", "TODO", or "implement later." The one place the plan defers to recon (Task 1 Step 2 SDK API surface) is appropriate — the spec explicitly flagged this as needing implementation-time SDK verification.

**Type consistency:**
- `haos_version` / `haos_image_filename` / `haos_image_sha256` referenced identically in Tasks 2, 3, 9
- `chalupa-infra:haosVersion` config key referenced identically in Tasks 4, 5
- `aeotec-zstick-10` USB mapping name referenced identically in Tasks 1, 5
- `homeassistant.host` / `homeassistant.externalIP` / `homeassistant.port` referenced identically in Tasks 6, 7, 8
- `homeassistant` namespace and resource names consistent across Tasks 7, 8

**Scope:** One PR, one cohesive deliverable. Cutover runbook out of scope as designed in the spec.

Plan complete.
