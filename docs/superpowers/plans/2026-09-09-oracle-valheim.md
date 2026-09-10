# Oracle Cloud Valheim Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision an always-free OCI Ampere A1 instance with Terraform and configure a modded (BepInEx) Valheim dedicated server on it with Ansible, deployed by GitHub Actions over Tailscale.

**Architecture:** Terraform creates the OCI network + instance; cloud-init installs Tailscale and joins the tailnet; Ansible (over Tailscale SSH) installs Box64, downloads the x86_64 Valheim server with ARM-native DepotDownloader, layers BepInEx + three pinned mods on top, and runs it as a systemd unit. Two new GitHub workflows mirror the repo's existing PR-check/deploy split.

**Tech Stack:** Terraform >= 1.9 with `oracle/oci` provider `~> 9.0` (S3-compatible state backend on OCI Object Storage), Ansible, Box64 (binfmt), DepotDownloader 3.4.0, BepInExPack_Valheim 5.4.2350.

**Spec:** `docs/superpowers/specs/2026-09-09-oracle-valheim-design.md`

## Global Constraints

- All work in this worktree on branch `worktree-oracle-valheim`; merged via PR only — never push to `main`.
- Never run `terraform apply` or `ansible-playbook` (without `--check`) locally — CI applies on merge.
- Do not touch `pulumi/`, `pulumi-talos/`, `ansible/` (root), or anything TrueNAS-related.
- OCI shape: `VM.Standard.A1.Flex`, 4 OCPUs / 24 GB RAM / 150 GB boot volume (always-free ceiling).
- Only UDP 2456–2457 is exposed to the internet. Port 22 is never opened publicly; SSH is Tailscale-only.
- Crossplay stays **off** (Steam-only): the server args must NOT include `-crossplay`.
- Pinned versions (verified against their registries on 2026-09-09 — do not "upgrade" while implementing):
  - DepotDownloader `3.4.0` (linux-arm64 build)
  - `denikson-BepInExPack_Valheim` `5.4.2350`
  - `Azumatt-AzuCraftyBoxes` `1.8.15`, `Azumatt-AAA_Crafting` `2.1.6`, `Azumatt-AzuAutoStore` `3.0.14` (no dependencies beyond BepInEx)
  - Terraform provider `oracle/oci` `~> 9.0`
- Thunderstore download URL pattern: `https://thunderstore.io/package/download/<team>/<name>/<version>/` (returns a zip).
- Tailscale hostname of the instance is exactly `oracle-server` — cloud-init sets it; the deploy workflow and inventory resolve it by that name.
- Secrets are referenced by these exact GitHub secret names (created during manual bootstrap, documented in Task 7): `OCI_TENANCY_OCID`, `OCI_USER_OCID`, `OCI_KEY_FINGERPRINT`, `OCI_PRIVATE_KEY`, `OCI_REGION`, `OCI_NAMESPACE`, `OCI_COMPARTMENT_OCID`, `OCI_S3_ACCESS_KEY`, `OCI_S3_SECRET_KEY`, `ORACLE_SSH_PUBLIC_KEY`, `ORACLE_SSH_PRIVATE_KEY`, `ORACLE_TAILSCALE_AUTH_KEY`, `VALHEIM_PASSWORD`. Existing secrets `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` are reused for the runner.

**Tool availability (first task that needs each):** `terraform version || brew install hashicorp/tap/terraform`; `ansible-lint --version || pipx install ansible-lint` (then `ansible-galaxy collection install ansible.posix community.general`); `actionlint -version || brew install actionlint`.

---

### Task 1: Terraform stack

**Files:**
- Create: `oracle-cloud-server/terraform/versions.tf`
- Create: `oracle-cloud-server/terraform/provider.tf`
- Create: `oracle-cloud-server/terraform/variables.tf`
- Create: `oracle-cloud-server/terraform/network.tf`
- Create: `oracle-cloud-server/terraform/compute.tf`
- Create: `oracle-cloud-server/terraform/cloud-init.yaml.tftpl`
- Create: `oracle-cloud-server/terraform/outputs.tf`
- Modify: `.gitignore` (append terraform ignores)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: Terraform output `public_ip`; an instance whose Tailscale hostname is `oracle-server` with login user `ubuntu` (OCI Ubuntu default); backend expects a `backend.hcl` written at init time (Task 6 writes it in CI) and AWS-style env credentials for state.

- [ ] **Step 1: Write the Terraform configuration**

`versions.tf`:

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.0"
    }
  }

  # OCI Object Storage via its S3-compatible API. Region + endpoint differ
  # per tenancy, so they arrive via -backend-config=backend.hcl (CI writes
  # it from secrets); credentials arrive via AWS_ACCESS_KEY_ID /
  # AWS_SECRET_ACCESS_KEY (OCI "customer secret keys").
  backend "s3" {
    bucket                      = "terraform-state"
    key                         = "oracle-cloud-server/terraform.tfstate"
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
```

`provider.tf`:

```hcl
provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  user_ocid    = var.user_ocid
  fingerprint  = var.api_key_fingerprint
  private_key  = var.api_private_key
  region       = var.region
}
```

`variables.tf`:

```hcl
variable "tenancy_ocid" {
  type = string
}

variable "user_ocid" {
  type = string
}

variable "api_key_fingerprint" {
  type = string
}

variable "api_private_key" {
  type      = string
  sensitive = true
}

variable "region" {
  type = string
}

variable "compartment_ocid" {
  description = "Compartment for all resources; the tenancy root OCID is fine"
  type        = string
}

variable "ssh_public_key" {
  description = "Authorized key for the ubuntu user (CI's ORACLE_SSH keypair)"
  type        = string
}

variable "tailscale_auth_key" {
  description = "Pre-authorized, tagged (tag:oracle-server) Tailscale auth key"
  type      = string
  sensitive = true
}

variable "instance_shape" {
  type    = string
  default = "VM.Standard.A1.Flex"
}

variable "instance_ocpus" {
  type    = number
  default = 4
}

variable "instance_memory_gb" {
  type    = number
  default = 24
}

variable "boot_volume_gb" {
  type    = number
  default = 150
}
```

`network.tf` — note the subnet gets a *custom* security list (egress + path-MTU ICMP only) instead of OCI's default one, which would open port 22 to the internet:

```hcl
resource "oci_core_vcn" "oracle_server" {
  compartment_id = var.compartment_ocid
  display_name   = "oracle-server-vcn"
  cidr_blocks    = ["10.30.0.0/16"]
  dns_label      = "oracleserver"
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oracle_server.id
  display_name   = "oracle-server-igw"
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oracle_server.id
  display_name   = "oracle-server-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

# Deliberately NOT the default security list: no SSH ingress. Game traffic
# is admitted by the NSG below; Tailscale rides outbound UDP (egress only).
resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oracle_server.id
  display_name   = "oracle-server-public-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # Path MTU discovery (fragmentation needed)
  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.oracle_server.id
  cidr_block        = "10.30.1.0/24"
  display_name      = "oracle-server-public"
  dns_label         = "public"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.public.id]
}

resource "oci_core_network_security_group" "valheim" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oracle_server.id
  display_name   = "valheim-nsg"
}

resource "oci_core_network_security_group_security_rule" "valheim_udp" {
  network_security_group_id = oci_core_network_security_group.valheim.id
  direction                 = "INGRESS"
  protocol                  = "17" # UDP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  udp_options {
    destination_port_range {
      min = 2456
      max = 2457
    }
  }
}
```

`compute.tf`:

```hcl
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "ubuntu_arm" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "oracle_server" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_ocid
  display_name        = "oracle-server"
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_arm.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
    hostname_label   = "oracleserver"
    nsg_ids          = [oci_core_network_security_group.valheim.id]
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
      tailscale_auth_key = var.tailscale_auth_key
    }))
  }

  lifecycle {
    # A newer Ubuntu image publishing must not replace the instance,
    # and cloud-init edits only apply at first boot anyway.
    ignore_changes = [
      source_details[0].source_id,
      metadata,
    ]
  }
}
```

`cloud-init.yaml.tftpl`:

```yaml
#cloud-config
package_update: true
runcmd:
  - ['sh', '-c', 'curl -fsSL https://tailscale.com/install.sh | sh']
  - ['tailscale', 'up', '--authkey=${tailscale_auth_key}', '--hostname=oracle-server']
```

`outputs.tf`:

```hcl
output "public_ip" {
  description = "Public IP players connect to (port 2456/UDP)"
  value       = oci_core_instance.oracle_server.public_ip
}
```

- [ ] **Step 2: Append terraform ignores to `.gitignore`**

Append these lines (keep whatever is already there):

```gitignore
# Terraform (oracle-cloud-server)
**/.terraform/
oracle-cloud-server/terraform/backend.hcl
*.tfstate
*.tfstate.backup
crash.log
```

- [ ] **Step 3: Validate**

Run (install terraform first if missing — see tool availability in Global Constraints):

```bash
cd oracle-cloud-server/terraform
terraform fmt -check -recursive   # expect: no output, exit 0
terraform init -backend=false     # expect: "Terraform has been successfully initialized!"
terraform validate                # expect: "Success! The configuration is valid."
```

If `fmt` rewrites files, run `terraform fmt -recursive` and re-check.

- [ ] **Step 4: Commit**

```bash
git add oracle-cloud-server/terraform .gitignore
git commit -m "feat(oracle): terraform stack for always-free A1 instance"
```

Include `oracle-cloud-server/terraform/.terraform.lock.hcl` (created by init) in the commit.

---

### Task 2: Ansible skeleton + base role

**Files:**
- Create: `oracle-cloud-server/ansible/ansible.cfg`
- Create: `oracle-cloud-server/ansible/inventory.yml`
- Create: `oracle-cloud-server/ansible/site.yml`
- Create: `oracle-cloud-server/ansible/group_vars/all.yml`
- Create: `oracle-cloud-server/ansible/roles/base/tasks/main.yml`

**Interfaces:**
- Consumes: instance reachable as Tailscale host `oracle-server`, user `ubuntu` (Task 1).
- Produces: inventory group `oracle` with host `oracle-server`; `ansible_host` resolves from env var `ORACLE_SERVER_IP` (Task 6 sets it), falling back to the MagicDNS name `oracle-server` for local runs; play `site.yml` applying roles `base` then `valheim`; group var `valheim_password` from env `VALHEIM_PASSWORD`. Packages `unzip`, `jq`, `iptables-persistent` guaranteed present for later roles.

- [ ] **Step 1: Write the skeleton**

`ansible.cfg`:

```ini
[defaults]
roles_path = ./roles
inventory = inventory.yml
```

`inventory.yml`:

```yaml
all:
  children:
    oracle:
      hosts:
        oracle-server:
          # CI injects ORACLE_SERVER_IP (resolved from `tailscale status`).
          # Locally, the MagicDNS name works if this machine is on the tailnet.
          ansible_host: "{{ lookup('env', 'ORACLE_SERVER_IP') | default('oracle-server', true) }}"
          ansible_user: ubuntu
```

`site.yml`:

```yaml
---
- name: Configure oracle-cloud-server
  hosts: oracle
  become: true
  roles:
    - base
    - valheim
```

(Referencing `valheim` before Task 3 exists would fail a playbook run, but only lint runs pre-merge; Tasks 2–5 merge together. Keep it.)

`group_vars/all.yml`:

```yaml
---
valheim_server_name: "Chalupa Valheim"
valheim_world_name: "chalupa"
# Never committed: provided by CI env (GitHub secret VALHEIM_PASSWORD).
valheim_password: "{{ lookup('env', 'VALHEIM_PASSWORD') }}"
```

`roles/base/tasks/main.yml`:

```yaml
---
- name: Upgrade packages
  ansible.builtin.apt:
    update_cache: true
    cache_valid_time: 3600
    upgrade: safe

- name: Install base packages
  ansible.builtin.apt:
    name:
      - unattended-upgrades
      - iptables-persistent
      - unzip
      - jq
    state: present

- name: Enable unattended security upgrades
  ansible.builtin.copy:
    dest: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
    owner: root
    group: root
    mode: "0644"
```

- [ ] **Step 2: Lint**

```bash
cd oracle-cloud-server/ansible
ansible-lint            # expect: exit 0 (site.yml's valheim role missing is a
                        # *playbook* concern, not lint; if ansible-lint errors on
                        # the unresolvable role, create an empty
                        # roles/valheim/tasks/main.yml ("---\n[]") now — Task 3
                        # overwrites it)
```

- [ ] **Step 3: Commit**

```bash
git add oracle-cloud-server/ansible
git commit -m "feat(oracle): ansible skeleton + base role"
```

---

### Task 3: valheim role — Box64, game install, host firewall

**Files:**
- Create: `oracle-cloud-server/ansible/roles/valheim/defaults/main.yml`
- Create: `oracle-cloud-server/ansible/roles/valheim/tasks/main.yml`
- Create: `oracle-cloud-server/ansible/roles/valheim/tasks/box64.yml`
- Create: `oracle-cloud-server/ansible/roles/valheim/tasks/install.yml`
- Create: `oracle-cloud-server/ansible/roles/valheim/tasks/firewall.yml`
- Create: `oracle-cloud-server/ansible/roles/valheim/handlers/main.yml`

**Interfaces:**
- Consumes: `unzip`, `iptables-persistent` from base role; group vars from Task 2.
- Produces: vars `valheim_user` (`valheim`), `valheim_home` (`/opt/valheim`), `valheim_server_dir` (`/opt/valheim/server`), `valheim_data_dir` (`/opt/valheim/data`), `valheim_dist_dir` (`/opt/valheim/dist`), `valheim_port` (`2456`), `valheim_mods` (list of `{name, team, version}`); handlers `Persist iptables` and `Restart valheim` (Task 4's unit; handler defined here, unit arrives in Task 4). Task 4 appends includes to `tasks/main.yml`.

- [ ] **Step 1: Write defaults**

`defaults/main.yml`:

```yaml
---
valheim_user: valheim
valheim_home: /opt/valheim
valheim_server_dir: /opt/valheim/server
valheim_data_dir: /opt/valheim/data
valheim_dist_dir: /opt/valheim/dist
valheim_port: 2456
valheim_steam_app_id: "896660"

depotdownloader_version: "3.4.0"
depotdownloader_url: "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_{{ depotdownloader_version }}/DepotDownloader-linux-arm64.zip"

box64_list_url: "https://ryanfortner.github.io/box64-debs/box64.list"
box64_key_url: "https://ryanfortner.github.io/box64-debs/KEY.gpg"

bepinex_version: "5.4.2350"
bepinex_url: "https://thunderstore.io/package/download/denikson/BepInExPack_Valheim/{{ bepinex_version }}/"

valheim_mods:
  - name: AzuCraftyBoxes
    team: Azumatt
    version: "1.8.15"
  - name: AAA_Crafting
    team: Azumatt
    version: "2.1.6"
  - name: AzuAutoStore
    team: Azumatt
    version: "3.0.14"
```

- [ ] **Step 2: Write task files**

`tasks/main.yml` (Task 4 and 5 append to this list):

```yaml
---
- name: Install Box64
  ansible.builtin.import_tasks: box64.yml

- name: Install Valheim dedicated server
  ansible.builtin.import_tasks: install.yml

- name: Open host firewall for Valheim
  ansible.builtin.import_tasks: firewall.yml
```

`tasks/box64.yml`:

```yaml
---
- name: Add box64 apt source list
  ansible.builtin.get_url:
    url: "{{ box64_list_url }}"
    dest: /etc/apt/sources.list.d/box64.list
    owner: root
    group: root
    mode: "0644"

- name: Add box64 apt signing key
  ansible.builtin.shell:
    cmd: >
      set -o pipefail &&
      curl -fsSL {{ box64_key_url }}
      | gpg --dearmor -o /etc/apt/trusted.gpg.d/box64-debs-archive-keyring.gpg
    creates: /etc/apt/trusted.gpg.d/box64-debs-archive-keyring.gpg
    executable: /bin/bash

- name: Install box64
  ansible.builtin.apt:
    name: box64
    state: present
    update_cache: true

- name: Verify box64 executes x86_64 binaries via binfmt
  ansible.builtin.command: box64 --version
  changed_when: false
```

`tasks/install.yml`:

```yaml
---
- name: Create valheim system user
  ansible.builtin.user:
    name: "{{ valheim_user }}"
    system: true
    home: "{{ valheim_home }}"
    create_home: true
    shell: /usr/sbin/nologin

- name: Create valheim directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: "{{ valheim_user }}"
    group: "{{ valheim_user }}"
    mode: "0755"
  loop:
    - "{{ valheim_server_dir }}"
    - "{{ valheim_data_dir }}"
    - "{{ valheim_dist_dir }}"

- name: Download DepotDownloader {{ depotdownloader_version }}
  ansible.builtin.get_url:
    url: "{{ depotdownloader_url }}"
    dest: "{{ valheim_dist_dir }}/DepotDownloader-{{ depotdownloader_version }}.zip"
    owner: "{{ valheim_user }}"
    mode: "0644"

- name: Extract DepotDownloader
  ansible.builtin.unarchive:
    src: "{{ valheim_dist_dir }}/DepotDownloader-{{ depotdownloader_version }}.zip"
    dest: "{{ valheim_home }}"
    remote_src: true
    owner: "{{ valheim_user }}"
    group: "{{ valheim_user }}"
    creates: "{{ valheim_home }}/DepotDownloader"

- name: Stat server binary before update
  ansible.builtin.stat:
    path: "{{ valheim_server_dir }}/valheim_server.x86_64"
    checksum_algorithm: sha256
  register: valheim_bin_before

- name: Download / update Valheim dedicated server (app {{ valheim_steam_app_id }})
  ansible.builtin.command:
    cmd: >
      {{ valheim_home }}/DepotDownloader
      -app {{ valheim_steam_app_id }}
      -dir {{ valheim_server_dir }}
  become: true
  become_user: "{{ valheim_user }}"
  changed_when: false
  # Change is detected by comparing the binary checksum below, because
  # DepotDownloader always revalidates and its exit output isn't a
  # reliable changed signal.

- name: Stat server binary after update
  ansible.builtin.stat:
    path: "{{ valheim_server_dir }}/valheim_server.x86_64"
    checksum_algorithm: sha256
  register: valheim_bin_after

- name: Detect server update
  ansible.builtin.command: /bin/true
  changed_when: >-
    (valheim_bin_before.stat.checksum | default(''))
    != (valheim_bin_after.stat.checksum | default(''))
  notify: Restart valheim

- name: Ensure server binary is executable
  ansible.builtin.file:
    path: "{{ valheim_server_dir }}/valheim_server.x86_64"
    mode: "0755"
```

`tasks/firewall.yml` — OCI Ubuntu images bake default-REJECT iptables rules; the NSG alone is not enough:

```yaml
---
- name: Allow Valheim UDP {{ valheim_port }}-{{ valheim_port + 1 }} on host firewall
  ansible.builtin.iptables:
    chain: INPUT
    action: insert
    rule_num: "1"
    protocol: udp
    destination_ports:
      - "{{ valheim_port }}:{{ valheim_port + 1 }}"
    jump: ACCEPT
    comment: valheim
  notify: Persist iptables
```

`handlers/main.yml`:

```yaml
---
- name: Persist iptables
  ansible.builtin.command: netfilter-persistent save
  changed_when: true

- name: Restart valheim
  ansible.builtin.systemd_service:
    name: valheim
    state: restarted
    daemon_reload: true
```

- [ ] **Step 3: Lint**

```bash
cd oracle-cloud-server/ansible
ansible-lint                          # expect: exit 0
ansible-playbook site.yml --syntax-check   # expect: "playbook: site.yml"
```

- [ ] **Step 4: Commit**

```bash
git add oracle-cloud-server/ansible/roles/valheim
git commit -m "feat(oracle): valheim role — box64, DepotDownloader install, host firewall"
```

---

### Task 4: valheim role — BepInEx, mods, systemd service

**Files:**
- Create: `oracle-cloud-server/ansible/roles/valheim/tasks/bepinex.yml`
- Create: `oracle-cloud-server/ansible/roles/valheim/tasks/service.yml`
- Create: `oracle-cloud-server/ansible/roles/valheim/templates/valheim.service.j2`
- Modify: `oracle-cloud-server/ansible/roles/valheim/tasks/main.yml` (append two imports)

**Interfaces:**
- Consumes: vars and handlers from Task 3 (`valheim_server_dir`, `valheim_dist_dir`, `valheim_mods`, `bepinex_version`, `bepinex_url`, handler `Restart valheim`); group vars `valheim_server_name`, `valheim_world_name`, `valheim_password` from Task 2.
- Produces: systemd unit `valheim.service` (enabled + started); mods installed under `BepInEx/plugins/<Name>-<version>/`. Task 5's backup reads worlds from `{{ valheim_data_dir }}/worlds_local`.

- [ ] **Step 1: Write bepinex tasks**

`tasks/bepinex.yml`:

```yaml
---
- name: Download BepInExPack_Valheim {{ bepinex_version }}
  ansible.builtin.get_url:
    url: "{{ bepinex_url }}"
    dest: "{{ valheim_dist_dir }}/BepInExPack_Valheim-{{ bepinex_version }}.zip"
    owner: "{{ valheim_user }}"
    mode: "0644"

- name: Unpack BepInExPack to staging
  ansible.builtin.unarchive:
    src: "{{ valheim_dist_dir }}/BepInExPack_Valheim-{{ bepinex_version }}.zip"
    dest: "{{ valheim_dist_dir }}"
    remote_src: true
    owner: "{{ valheim_user }}"
    group: "{{ valheim_user }}"
    creates: "{{ valheim_dist_dir }}/BepInExPack_Valheim"

- name: Install BepInExPack into server dir
  ansible.builtin.copy:
    src: "{{ valheim_dist_dir }}/BepInExPack_Valheim/"
    dest: "{{ valheim_server_dir }}/"
    remote_src: true
    owner: "{{ valheim_user }}"
    group: "{{ valheim_user }}"
    mode: preserve
  notify: Restart valheim

- name: Download mods
  ansible.builtin.get_url:
    url: "https://thunderstore.io/package/download/{{ item.team }}/{{ item.name }}/{{ item.version }}/"
    dest: "{{ valheim_dist_dir }}/{{ item.name }}-{{ item.version }}.zip"
    owner: "{{ valheim_user }}"
    mode: "0644"
  loop: "{{ valheim_mods }}"

- name: Create versioned mod directories
  ansible.builtin.file:
    path: "{{ valheim_server_dir }}/BepInEx/plugins/{{ item.name }}-{{ item.version }}"
    state: directory
    owner: "{{ valheim_user }}"
    group: "{{ valheim_user }}"
    mode: "0755"
  loop: "{{ valheim_mods }}"

- name: Install mods into BepInEx plugins dir
  ansible.builtin.unarchive:
    src: "{{ valheim_dist_dir }}/{{ item.name }}-{{ item.version }}.zip"
    dest: "{{ valheim_server_dir }}/BepInEx/plugins/{{ item.name }}-{{ item.version }}"
    remote_src: true
    owner: "{{ valheim_user }}"
    group: "{{ valheim_user }}"
    creates: "{{ valheim_server_dir }}/BepInEx/plugins/{{ item.name }}-{{ item.version }}/manifest.json"
  loop: "{{ valheim_mods }}"
  notify: Restart valheim
```

(Thunderstore zips extract their files at the archive root, so each mod gets its own versioned directory; every Thunderstore zip contains `manifest.json` at its root, which makes `creates` a true idempotence marker.)

Then remove stale versions after a pin bump:

```yaml
- name: Find outdated managed-mod directories
  ansible.builtin.find:
    paths: "{{ valheim_server_dir }}/BepInEx/plugins"
    file_type: directory
    patterns: "{{ item.name }}-*"
    excludes: "{{ item.name }}-{{ item.version }}"
  loop: "{{ valheim_mods }}"
  register: valheim_stale_mods

- name: Remove outdated managed-mod directories
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: absent
  loop: "{{ valheim_stale_mods.results | map(attribute='files') | flatten }}"
  loop_control:
    label: "{{ item.path }}"
  notify: Restart valheim
```

- [ ] **Step 2: Write the systemd unit and service tasks**

`templates/valheim.service.j2` — Box64's binfmt handler executes the x86_64 binary transparently; the Doorstop env vars are the ones BepInExPack's own `start_server_bepinex.sh` sets, with absolute paths:

```ini
[Unit]
Description=Valheim Dedicated Server (BepInEx via Box64)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User={{ valheim_user }}
WorkingDirectory={{ valheim_server_dir }}
Environment=SteamAppId=892970
Environment=DOORSTOP_ENABLE=TRUE
Environment=DOORSTOP_INVOKE_DLL_PATH={{ valheim_server_dir }}/BepInEx/core/BepInEx.Preloader.dll
Environment=DOORSTOP_CORLIB_OVERRIDE_PATH={{ valheim_server_dir }}/unstripped_corlib
Environment=LD_LIBRARY_PATH={{ valheim_server_dir }}/doorstop_libs:{{ valheim_server_dir }}/linux64
Environment=LD_PRELOAD=libdoorstop_x64.so
ExecStart={{ valheim_server_dir }}/valheim_server.x86_64 -nographics -batchmode -name "{{ valheim_server_name }}" -port {{ valheim_port }} -world "{{ valheim_world_name }}" -password "{{ valheim_password }}" -public 1 -savedir {{ valheim_data_dir }}
Restart=on-failure
RestartSec=10
StartLimitBurst=5
StartLimitIntervalSec=300
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
```

`tasks/service.yml`:

```yaml
---
- name: Assert server password is usable
  ansible.builtin.assert:
    that:
      - valheim_password | length >= 5
      - valheim_password not in valheim_server_name
    fail_msg: >-
      VALHEIM_PASSWORD must be at least 5 characters and must not be
      contained in the server name (Valheim refuses to start otherwise).
    quiet: true

- name: Install valheim systemd unit
  ansible.builtin.template:
    src: valheim.service.j2
    dest: /etc/systemd/system/valheim.service
    owner: root
    group: root
    mode: "0600"
  notify: Restart valheim

- name: Enable and start valheim
  ansible.builtin.systemd_service:
    name: valheim
    enabled: true
    state: started
    daemon_reload: true
```

(Unit mode is 0600 because the world password is embedded in ExecStart.)

Append to `tasks/main.yml`:

```yaml
- name: Install BepInEx and mods
  ansible.builtin.import_tasks: bepinex.yml

- name: Configure and start valheim service
  ansible.builtin.import_tasks: service.yml
```

- [ ] **Step 3: Lint**

```bash
cd oracle-cloud-server/ansible
ansible-lint                          # expect: exit 0
ansible-playbook site.yml --syntax-check   # expect: "playbook: site.yml"
```

- [ ] **Step 4: Commit**

```bash
git add oracle-cloud-server/ansible/roles/valheim
git commit -m "feat(oracle): valheim role — BepInEx + pinned mods + systemd unit"
```

---

### Task 5: valheim role — world backups

**Files:**
- Create: `oracle-cloud-server/ansible/roles/valheim/tasks/backup.yml`
- Create: `oracle-cloud-server/ansible/roles/valheim/templates/valheim-backup.sh.j2`
- Create: `oracle-cloud-server/ansible/roles/valheim/templates/valheim-backup.service.j2`
- Create: `oracle-cloud-server/ansible/roles/valheim/templates/valheim-backup.timer.j2`
- Modify: `oracle-cloud-server/ansible/roles/valheim/tasks/main.yml` (append one import)

**Interfaces:**
- Consumes: `valheim_user`, `valheim_home`, `valheim_data_dir` from Task 3. Worlds live at `{{ valheim_data_dir }}/worlds_local` (created by the server on first world save).
- Produces: `valheim-backup.timer` (daily), archives in `{{ valheim_home }}/backups`, retention 14.

- [ ] **Step 1: Write templates**

`templates/valheim-backup.sh.j2`:

```bash
#!/usr/bin/env bash
set -euo pipefail

backup_dir="{{ valheim_home }}/backups"
worlds_dir="{{ valheim_data_dir }}/worlds_local"

if [ ! -d "$worlds_dir" ]; then
  echo "No worlds directory yet ($worlds_dir); nothing to back up."
  exit 0
fi

mkdir -p "$backup_dir"
tar -czf "$backup_dir/worlds-$(date +%F-%H%M).tar.gz" -C "{{ valheim_data_dir }}" worlds_local

# Keep the newest 14 archives
ls -1t "$backup_dir"/worlds-*.tar.gz | tail -n +15 | xargs -r rm --
```

`templates/valheim-backup.service.j2`:

```ini
[Unit]
Description=Back up Valheim worlds

[Service]
Type=oneshot
User={{ valheim_user }}
ExecStart={{ valheim_home }}/valheim-backup.sh
```

`templates/valheim-backup.timer.j2`:

```ini
[Unit]
Description=Daily Valheim world backup

[Timer]
OnCalendar=*-*-* 09:30:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
```

(09:30 UTC ≈ 03:30 America/Denver — low-traffic.)

`tasks/backup.yml`:

```yaml
---
- name: Install backup script
  ansible.builtin.template:
    src: valheim-backup.sh.j2
    dest: "{{ valheim_home }}/valheim-backup.sh"
    owner: "{{ valheim_user }}"
    group: "{{ valheim_user }}"
    mode: "0755"

- name: Install backup service and timer
  ansible.builtin.template:
    src: "{{ item.src }}"
    dest: "/etc/systemd/system/{{ item.dest }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - { src: valheim-backup.service.j2, dest: valheim-backup.service }
    - { src: valheim-backup.timer.j2, dest: valheim-backup.timer }

- name: Enable backup timer
  ansible.builtin.systemd_service:
    name: valheim-backup.timer
    enabled: true
    state: started
    daemon_reload: true
```

Append to `tasks/main.yml`:

```yaml
- name: Configure world backups
  ansible.builtin.import_tasks: backup.yml
```

- [ ] **Step 2: Lint**

```bash
cd oracle-cloud-server/ansible
ansible-lint                          # expect: exit 0
ansible-playbook site.yml --syntax-check   # expect: "playbook: site.yml"
```

- [ ] **Step 3: Commit**

```bash
git add oracle-cloud-server/ansible/roles/valheim
git commit -m "feat(oracle): nightly valheim world backups (14-day retention)"
```

---

### Task 6: CI workflows

**Files:**
- Create: `.github/workflows/oracle.yml` (PR checks)
- Create: `.github/workflows/oracle-deploy.yml` (apply on merge)

**Interfaces:**
- Consumes: Terraform stack (Task 1) expecting `backend.hcl` + `TF_VAR_*` env; Ansible tree (Tasks 2–5) expecting `ORACLE_SERVER_IP` and `VALHEIM_PASSWORD` env; Tailscale hostname `oracle-server`; secret names from Global Constraints.
- Produces: PR plan comments (same `github-script` pattern as `ansible.yml`); deploy pipeline `terraform apply` → resolve Tailscale IP → `ansible-playbook`.

- [ ] **Step 1: Write the PR workflow**

`.github/workflows/oracle.yml`:

```yaml
name: Oracle Cloud Server

on:
  pull_request:
    branches:
      - main

jobs:
  detect-changes:
    name: Detect changed paths
    runs-on: ubuntu-latest
    outputs:
      terraform: ${{ steps.filter.outputs.terraform }}
      ansible: ${{ steps.filter.outputs.ansible }}
    steps:
      - uses: actions/checkout@v7
      - uses: dorny/paths-filter@v4
        id: filter
        with:
          filters: |
            terraform:
              - 'oracle-cloud-server/terraform/**'
              - '.github/workflows/oracle.yml'
            ansible:
              - 'oracle-cloud-server/ansible/**'
              - '.github/workflows/oracle.yml'

  terraform-plan:
    name: Terraform Plan
    runs-on: ubuntu-latest
    needs: detect-changes
    if: needs.detect-changes.outputs.terraform == 'true'
    permissions:
      pull-requests: write
    defaults:
      run:
        working-directory: oracle-cloud-server/terraform
    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.OCI_S3_ACCESS_KEY }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.OCI_S3_SECRET_KEY }}
      TF_VAR_tenancy_ocid: ${{ secrets.OCI_TENANCY_OCID }}
      TF_VAR_user_ocid: ${{ secrets.OCI_USER_OCID }}
      TF_VAR_api_key_fingerprint: ${{ secrets.OCI_KEY_FINGERPRINT }}
      TF_VAR_api_private_key: ${{ secrets.OCI_PRIVATE_KEY }}
      TF_VAR_region: ${{ secrets.OCI_REGION }}
      TF_VAR_compartment_ocid: ${{ secrets.OCI_COMPARTMENT_OCID }}
      TF_VAR_ssh_public_key: ${{ secrets.ORACLE_SSH_PUBLIC_KEY }}
      TF_VAR_tailscale_auth_key: ${{ secrets.ORACLE_TAILSCALE_AUTH_KEY }}
    steps:
      - uses: actions/checkout@v7

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_wrapper: false

      - name: Terraform fmt
        run: terraform fmt -check -recursive

      - name: Write backend config
        run: |
          cat > backend.hcl <<EOF
          region    = "${{ secrets.OCI_REGION }}"
          endpoints = { s3 = "https://${{ secrets.OCI_NAMESPACE }}.compat.objectstorage.${{ secrets.OCI_REGION }}.oraclecloud.com" }
          EOF

      - name: Terraform init
        run: terraform init -backend-config=backend.hcl

      - name: Terraform validate
        run: terraform validate

      - name: Terraform plan
        id: plan
        run: |
          output=$(terraform plan -no-color -input=false 2>&1)
          status=$?
          echo "output<<EOF" >> $GITHUB_OUTPUT
          echo "$output" >> $GITHUB_OUTPUT
          echo "EOF" >> $GITHUB_OUTPUT
          exit $status
        continue-on-error: true

      - name: Comment PR with plan
        uses: actions/github-script@v9
        env:
          PLAN_OUTPUT: ${{ steps.plan.outputs.output }}
        with:
          script: |
            const output = `### Oracle Terraform Plan
            <details><summary>Show Output</summary>

            \`\`\`
            ${process.env.PLAN_OUTPUT}
            \`\`\`

            </details>`;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            })

      - name: Fail if plan failed
        if: steps.plan.outcome == 'failure'
        run: exit 1

  ansible-lint:
    name: Lint Ansible
    runs-on: ubuntu-latest
    needs: detect-changes
    if: needs.detect-changes.outputs.ansible == 'true'
    steps:
      - uses: actions/checkout@v7

      - name: Set up Python
        uses: actions/setup-python@v7
        with:
          python-version: '3.14'

      - name: Install ansible-lint
        run: |
          pip install ansible-lint
          ansible-galaxy collection install ansible.posix community.general

      - name: Run ansible-lint
        run: ansible-lint
        working-directory: oracle-cloud-server/ansible/
```

- [ ] **Step 2: Write the deploy workflow**

`.github/workflows/oracle-deploy.yml`:

```yaml
name: Oracle Deploy

on:
  push:
    branches:
      - main
  workflow_dispatch:

jobs:
  detect-changes:
    name: Detect changed paths
    runs-on: ubuntu-latest
    if: github.event_name != 'workflow_dispatch'
    outputs:
      terraform: ${{ steps.filter.outputs.terraform }}
      ansible: ${{ steps.filter.outputs.ansible }}
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - uses: dorny/paths-filter@v4
        id: filter
        with:
          filters: |
            terraform:
              - 'oracle-cloud-server/terraform/**'
              - '.github/workflows/oracle-deploy.yml'
            ansible:
              - 'oracle-cloud-server/ansible/**'
              - '.github/workflows/oracle-deploy.yml'

  terraform-apply:
    name: Terraform Apply
    runs-on: ubuntu-latest
    needs: detect-changes
    if: |
      always() &&
      needs.detect-changes.result != 'failure' &&
      needs.detect-changes.result != 'cancelled' &&
      (github.event_name == 'workflow_dispatch' || needs.detect-changes.outputs.terraform == 'true')
    defaults:
      run:
        working-directory: oracle-cloud-server/terraform
    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.OCI_S3_ACCESS_KEY }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.OCI_S3_SECRET_KEY }}
      TF_VAR_tenancy_ocid: ${{ secrets.OCI_TENANCY_OCID }}
      TF_VAR_user_ocid: ${{ secrets.OCI_USER_OCID }}
      TF_VAR_api_key_fingerprint: ${{ secrets.OCI_KEY_FINGERPRINT }}
      TF_VAR_api_private_key: ${{ secrets.OCI_PRIVATE_KEY }}
      TF_VAR_region: ${{ secrets.OCI_REGION }}
      TF_VAR_compartment_ocid: ${{ secrets.OCI_COMPARTMENT_OCID }}
      TF_VAR_ssh_public_key: ${{ secrets.ORACLE_SSH_PUBLIC_KEY }}
      TF_VAR_tailscale_auth_key: ${{ secrets.ORACLE_TAILSCALE_AUTH_KEY }}
    steps:
      - uses: actions/checkout@v7

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_wrapper: false

      - name: Write backend config
        run: |
          cat > backend.hcl <<EOF
          region    = "${{ secrets.OCI_REGION }}"
          endpoints = { s3 = "https://${{ secrets.OCI_NAMESPACE }}.compat.objectstorage.${{ secrets.OCI_REGION }}.oraclecloud.com" }
          EOF

      - name: Terraform init
        run: terraform init -backend-config=backend.hcl

      - name: Terraform apply
        run: terraform apply -auto-approve -input=false

  ansible-configure:
    name: Ansible Configure
    runs-on: ubuntu-latest
    needs: [detect-changes, terraform-apply]
    if: |
      always() &&
      needs.terraform-apply.result != 'failure' &&
      needs.terraform-apply.result != 'cancelled' &&
      (
        github.event_name == 'workflow_dispatch' ||
        needs.detect-changes.outputs.ansible == 'true' ||
        needs.detect-changes.outputs.terraform == 'true'
      )
    steps:
      - uses: actions/checkout@v7

      - name: Set up Python
        uses: actions/setup-python@v7
        with:
          python-version: '3.14'

      - name: Install Ansible + collections
        run: |
          pip install ansible
          ansible-galaxy collection install ansible.posix community.general

      - name: Connect to Tailscale
        uses: tailscale/github-action@v4
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:github-runner

      - name: Setup SSH
        uses: webfactory/ssh-agent@v0.10.0
        with:
          ssh-private-key: ${{ secrets.ORACLE_SSH_PRIVATE_KEY }}

      - name: Resolve oracle-server Tailscale IP
        run: |
          for attempt in $(seq 1 18); do
            ORACLE_IP=$(tailscale status --json \
              | jq -r '.Peer[] | select(.HostName == "oracle-server") | .TailscaleIPs[0]')
            if [ -n "$ORACLE_IP" ] && [ "$ORACLE_IP" != "null" ]; then
              echo "ORACLE_SERVER_IP=$ORACLE_IP" >> "$GITHUB_ENV"
              mkdir -p ~/.ssh
              for scan in 1 2 3; do
                if ssh-keyscan -H "$ORACLE_IP" >> ~/.ssh/known_hosts; then
                  exit 0
                fi
                echo "ssh-keyscan attempt $scan failed, retrying in 10s..." >&2
                sleep 10
              done
              echo "ERROR: ssh-keyscan failed" >&2
              exit 1
            fi
            echo "oracle-server not on tailnet yet (attempt $attempt/18), retrying in 10s..."
            sleep 10
          done
          echo "ERROR: oracle-server never appeared on the tailnet" >&2
          exit 1

      - name: Run Ansible Playbook
        run: ansible-playbook -i inventory.yml site.yml
        working-directory: oracle-cloud-server/ansible/
        env:
          VALHEIM_PASSWORD: ${{ secrets.VALHEIM_PASSWORD }}
```

- [ ] **Step 3: Lint the workflows**

```bash
actionlint .github/workflows/oracle.yml .github/workflows/oracle-deploy.yml
# expect: no output, exit 0 (install with `brew install actionlint` if missing)
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/oracle.yml .github/workflows/oracle-deploy.yml
git commit -m "ci(oracle): PR plan/lint + deploy workflows for oracle-cloud-server"
```

---

### Task 7: README + CLAUDE.md

**Files:**
- Create: `oracle-cloud-server/README.md`
- Modify: `CLAUDE.md` (add an Oracle Cloud Server section)

**Interfaces:**
- Consumes: everything above — the README documents the exact secret names, hostnames, ports, paths, and versions defined in Tasks 1–6. Do not invent new names.
- Produces: the operator-facing bootstrap checklist and player instructions.

- [ ] **Step 1: Write `oracle-cloud-server/README.md`** with these sections (prose is the implementer's, facts must match earlier tasks exactly):

1. **What this is** — always-free OCI A1 instance (4 OCPU / 24 GB / 150 GB, Ubuntu 24.04 ARM) running a modded Valheim dedicated server (x86_64 under Box64), first workload of several. Link the spec.
2. **One-time bootstrap checklist** (numbered, in order):
   1. OCI console → Identity → your user → API keys → generate key pair; record tenancy OCID, user OCID, fingerprint, region.
   2. OCI console → Object Storage → create bucket `terraform-state` (Standard tier); Identity → your user → Customer secret keys → create one (this yields the S3 access/secret pair). Record the Object Storage **namespace** (shown on the bucket page).
   3. If `terraform apply` later fails with "Out of host capacity": upgrade the account to Pay-As-You-Go (Billing → Upgrade). Always-free A1 usage remains $0.
   4. Tailscale admin console → add ACL tag `tag:oracle-server` (owner `autogroup:admin`), ACL rule allowing `tag:github-runner` → `tag:oracle-server:22`, then Keys → generate an auth key: reusable, pre-approved, tagged `tag:oracle-server`. (Note key expiry — max 90 days; regenerating and updating the secret is only needed if the instance is recreated.)
   5. Generate a dedicated SSH keypair: `ssh-keygen -t ed25519 -f oracle_server_key -C oracle-cloud-server -N ""`.
   6. Add the GitHub secrets (table with all 13 names from the plan's Global Constraints and what goes in each).
3. **How deploys work** — PR = plan + lint with a plan comment; merge = apply + ansible over Tailscale. No local applies.
4. **Players: how to join** — server appears in the Steam/Valheim community list as `Chalupa Valheim`; direct-connect `<public_ip>:2456` (IP from the Terraform output `public_ip`, shown in the apply logs, or `terraform output` locally with creds); password shared out-of-band. **Required client mods (must match server pins):** `denikson-BepInExPack_Valheim@5.4.2350`, `Azumatt-AzuCraftyBoxes@1.8.15`, `Azumatt-AAA_Crafting@2.1.6`, `Azumatt-AzuAutoStore@3.0.14` — easiest via an r2modman profile; crossplay is off, Steam only.
5. **Operations** — SSH: `ssh ubuntu@oracle-server` (tailnet); logs: `journalctl -u valheim -f`; BepInEx load check: `journalctl -u valheim | grep -i 'Loading \['`; restart: `sudo systemctl restart valheim`; backups in `/opt/valheim/backups` (daily timer `valheim-backup.timer`, 14 kept); mod upgrades = bump version in `roles/valheim/defaults/main.yml` via PR.
6. **Troubleshooting** — Out of capacity (see bootstrap step 3); "nobody can connect" → check host iptables (`sudo iptables -L INPUT -n | head`) AND the NSG, in that order; instance unreachable → check Tailscale admin console for `oracle-server`, auth key validity; Box64 sanity: `box64 --version` and `update-binfmts --display | grep box64`.
7. **Future workloads** — add a new role beside `valheim/` and list it in `site.yml`; open its ports in both the NSG (Terraform) and host iptables (its role).

- [ ] **Step 2: Add to `CLAUDE.md`** — after the Talos cluster paragraph in Project Overview/Architecture, add a short section:

```markdown
**Oracle Cloud Server** (`oracle-cloud-server/`): Always-free OCI Ampere A1
instance (4 OCPU / 24 GB, Ubuntu 24.04 ARM) running a modded Valheim dedicated
server (x86_64 via Box64, BepInEx, DepotDownloader) — Terraform provisions
(state in OCI Object Storage via S3-compat backend), Ansible configures over
Tailscale (host `oracle-server`, SSH never exposed publicly; only UDP
2456-2457 open). CI: `.github/workflows/oracle.yml` (PR plan/lint) and
`oracle-deploy.yml` (apply on merge). See `oracle-cloud-server/README.md`
for bootstrap + operations.
```

And in the Commands section:

```markdown
### Oracle Cloud Server (from `oracle-cloud-server/`)
```bash
cd terraform && terraform fmt -check -recursive && terraform validate  # after init -backend=false
cd ansible && ansible-lint            # Lint
ssh ubuntu@oracle-server              # Over Tailscale
```
```

- [ ] **Step 3: Verify**

```bash
grep -c 'OCI_' oracle-cloud-server/README.md   # expect >= 8 (secrets table present)
```

Proofread the README secret names against Global Constraints — all 13 present, spelled exactly.

- [ ] **Step 4: Commit**

```bash
git add oracle-cloud-server/README.md CLAUDE.md
git commit -m "docs(oracle): README bootstrap/ops guide + CLAUDE.md section"
```

---

### Task 8: Final verification + PR

**Files:**
- Modify: `docs/superpowers/specs/2026-09-09-oracle-valheim-design.md` (only if drift found)

- [ ] **Step 1: Full lint sweep**

```bash
cd oracle-cloud-server/terraform && terraform fmt -check -recursive && terraform validate
cd ../ansible && ansible-lint && ansible-playbook site.yml --syntax-check
cd ../.. && actionlint .github/workflows/oracle.yml .github/workflows/oracle-deploy.yml
```

Expected: all exit 0.

- [ ] **Step 2: Spec drift check** — reread the spec; if implementation deviated anywhere (names, versions, structure), update the spec to match reality and commit `docs: sync spec with implementation`.

- [ ] **Step 3: Create the PR** (never push to main):

```bash
git push -u origin worktree-oracle-valheim
gh pr create --title "feat: Oracle Cloud always-free Valheim server (Terraform + Tailscale + Ansible)" \
  --body "$(cat <<'EOF'
## Summary
- New `oracle-cloud-server/` top-level dir: Terraform (OCI A1 4c/24GB, UDP 2456-2457 only, Tailscale-only SSH) + Ansible (Box64, DepotDownloader, Valheim + BepInEx + 3 pinned QoL mods, systemd, nightly backups)
- New CI: `oracle.yml` (PR plan/lint) + `oracle-deploy.yml` (apply on merge over Tailscale)
- Spec: docs/superpowers/specs/2026-09-09-oracle-valheim-design.md

## Notes
- First deploy requires the one-time bootstrap checklist in oracle-cloud-server/README.md (OCI API key, state bucket, Tailscale tag/ACL/auth key, 13 GitHub secrets)
- CI-applied only; no local terraform apply

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Post-merge verification checklist** (after the user completes bootstrap and merges — record results in the PR or a follow-up):

1. `oracle-deploy.yml` run green (apply + ansible).
2. `oracle-server` visible in Tailscale admin console.
3. `ssh ubuntu@oracle-server 'systemctl is-active valheim'` → `active`.
4. `journalctl -u valheim | grep -i 'Loading \['` shows AzuCraftyBoxes, AAA_Crafting, AzuAutoStore.
5. A client with matching mods joins `<public_ip>:2456`; world persists across `sudo systemctl restart valheim`.
6. Next morning: one archive in `/opt/valheim/backups`.
