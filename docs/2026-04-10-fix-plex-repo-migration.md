# 2026-04-10: Migrate Plex Repo to `repo.plex.tv/rpm/`

## Overview
After [PR #39](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/39) unblocked Ansible mount/firewalld tasks, Stage 3 of [run 24223547732](https://github.com/Chalupa-Tech/chalupa-tech-local/actions/runs/24223547732) progressed all the way to `Install plexmediaserver` and failed with:

```
Failed to validate GPG signatures: OpenPGP check for package
"plexmediaserver-1.42.2.10156-f737b826c.x86_64" ... from repo "plex"
has failed: Import of the key didn't help, wrong key?
```

## Rationale

### What the old config was
`ansible/roles/plex_server/defaults/main.yml` had:

```yaml
plex_server_repo_url: "https://downloads.plex.tv/repo/rpm/x86_64/"
plex_server_repo_gpgkey: "https://downloads.plex.tv/plex-keys/PlexSign.v2.key"
```

### What's actually on the VM
SSH'd into the Plex VM and inspected the cached RPM that dnf was rejecting:

```
$ rpm -qi --qf "%{SIGPGP:pgpsig}\n" -p .../plexmediaserver-1.42.2.10156-f737b826c.x86_64.rpm
RSA/SHA512, Thu 18 Sep 2025 03:16:02 PM UTC, Key ID 97203c7b3adca79d
```

And the two keys Plex publishes:

```
$ curl -s https://downloads.plex.tv/plex-keys/PlexSign.v2.key | gpg --show-keys
pub   ed25519 2024-02-20 [C]
      6EFF EB47 8A65 59D7 5C7C  4FE7 06C5 2179 0B9C FFDE

$ curl -s https://downloads.plex.tv/plex-keys/PlexSign.key    | gpg --show-keys
pub   rsa4096 2015-03-22 [SC]
      CD66 5CBA 0E2F 88B7 373F  7CB9 9720 3C7B 3ADC A79D
```

Packages at the *old* URL (`downloads.plex.tv/repo/rpm/x86_64/`) are still signed with the legacy 2015 RSA key (`97203C7B 3ADCA79D`). Our config was importing the new ed25519 v2 key and then trying to use it to verify RPMs signed by the RSA key — "wrong key". That's why package verification failed.

### The migration Plex actually wants
The support article points at `https://repo.plex.tv/scripts/setupRepo.sh`. Reading the script's RPM branch, the currently-endorsed repo configuration is:

```
[PlexTv]
name=Plex.tv
baseurl=https://repo.plex.tv/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://downloads.plex.tv/plex-keys/PlexSign.v2.key
```

Plex has migrated from `downloads.plex.tv/repo/rpm/x86_64/` to `repo.plex.tv/rpm/`. The *new* URL serves packages signed with the v2 key — the old URL still serves old packages signed with the legacy key. Verified directly on the Plex VM with a one-shot repo file + `dnf install -y plexmediaserver`, which fetched `plexmediaserver-1.43.1.10576` and validated cleanly against the v2 key.

### Why we can't run `setupRepo.sh` directly
The script uses `read -rp "$prompt [y/n]: " answer < /dev/tty` for every decision. It cannot be piped non-interactively — even `yes | setupRepo.sh` fails because the `read` is hard-bound to `/dev/tty`, not stdin. So we replicate what it does declaratively in Ansible.

### Two dnf-specific gotchas
Running the equivalent config through dnf revealed two subtle CI-relevant details:

1. **Pre-import the GPG key.** dnf's package `gpgcheck` uses the RPM keyring. On a fresh VM that keyring is empty, so the first `dnf install` would prompt "Is this ok [y/N]:" to import the key — and Ansible's `dnf` module has no way to answer that prompt, so it hangs or fails. Solved with an `ansible.builtin.rpm_key` task that imports `PlexSign.v2.key` into the keyring *before* `yum_repository` is configured, so the key is already trusted when dnf runs.

2. **Do NOT set `repo_gpgcheck: true`.** The setup script enables it, but only gets away with it because every dnf invocation in the script uses `-y`, which auto-confirms *both* key-import prompts — the package-signing key import (which rpm_key already handles for us) *and* a separate prompt for the repomd.xml metadata key import. Ansible's dnf module does not pass through a non-interactive confirmation for the metadata key import. I verified this directly:

    - `repo_gpgcheck=1` + `dnf --assumeno ...` → hangs on `Is this ok [y/N]:` and fails with `repomd.xml GPG signature verification error: Signing key not found`.
    - Same config + `dnf -y ...` → works, auto-confirms, installs cleanly.
    - `repo_gpgcheck` *removed* + `dnf --disablerepo=\"*\" --enablerepo=plex makecache` → works non-interactively.

    Package `gpgcheck` is still on, so every RPM payload is still verified against the pre-imported key — the thing that actually matters for supply chain integrity. `repo_gpgcheck` adds a metadata-level check on top of that; it's a nice-to-have we can revisit if dnf5 gets a non-interactive auto-accept option.

## Changes
- **Ansible defaults** `ansible/roles/plex_server/defaults/main.yml`:
  - `plex_server_repo_url` → `https://repo.plex.tv/rpm/` (the current endorsed URL).
  - Reverted `plex_server_repo_gpgkey` to a single string (`PlexSign.v2.key`) after briefly trying a two-key list in a previous revision of this branch — the new URL is single-key-signed and the list was unnecessary.
- **Ansible role** `ansible/roles/plex_server/tasks/main.yml`:
  - Added a new `Import Plex repository GPG key` task using `ansible.builtin.rpm_key` before the repo is configured.
  - Left `yum_repository` otherwise untouched: `gpgcheck: true`, no `repo_gpgcheck`, with a detailed comment explaining why.

## Manual state notes
While verifying the fix on the live VM I deliberately ran `dnf install -y plexmediaserver` to confirm that the new URL + v2 key combination installs cleanly. That left `plexmediaserver-1.43.1.10576` installed on the Plex VM. The Ansible `dnf: state=present` task is idempotent — the next deploy will see the package is already present and make no further changes.

## Pull Request
[PR #40](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/40)
