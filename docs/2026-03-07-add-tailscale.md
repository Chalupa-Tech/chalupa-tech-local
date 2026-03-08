# Change Log: Add Tailscale to CI/CD

## Summary
Integrated Tailscale into GitHub Actions workflows to allow secure access to the local Proxmox environment without exposing it to the public internet.

## Changes
- **Ansible Workflow (`ansible.yml`)**: Added the `tailscale/github-action` step using OAuth credentials and the `tag:github-runner` tag to the `check-and-diff` and `deploy` jobs. This enables the GitHub runner to connect to the homelab network before executing the Ansible playbooks via SSH.
- **Pulumi Workflow (`pulumi.yml`)**: Added the `tailscale/github-action` step using OAuth credentials and the `tag:github-runner` tag to the `preview` and `up` jobs. This provides network connectivity for the runner to communicate with the Proxmox VE API.

## Rationale
- **Security First**: Proxmox must NEVER be exposed to the public internet. To allow GitHub Actions to provision and configure the infrastructure, a secure tunnel to the internal network is required.
- **Tailscale**: Using Tailscale provides an easy-to-use and highly secure VPN for runners. The use of OAuth credentials and tags conforms to better security practices for ephemeral CI runners than using static auth keys.
