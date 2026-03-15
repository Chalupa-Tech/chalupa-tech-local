# 2026-03-14: Setup Talos Kubernetes Cluster

## Overview
Added a new Talos Kubernetes cluster to the infrastructure. The setup includes one control plane node and two worker nodes, managed by Pulumi and provisioned on Proxmox.

## Rationale
To provide a container orchestration layer for internal services and applications. Talos was chosen for its immutable, minimalist, and secure nature.

## Changes
- Updated `pulumi/go.mod` to include the `pulumiverse/pulumi-talos` provider.
- Created `pulumi/talos.go` to define:
    - Talos secrets and machine configurations.
    - Proxmox VMs for the control plane (`192.168.1.41`) and two workers (`192.168.1.42`, `192.168.1.43`).
    - Automated configuration delivery via Proxmox snippets.
    - Automated cluster bootstrapping.
- Integrated `setupTalosCluster` in `pulumi/main.go`.

## Verification Results
- `go build` confirms that the code compiles correctly against the latest Pulumi and provider SDKs.
- Pulumi stack exports `talosconfig` for easy access.

## Pull Request
[PR #11](https://github.com/Chalupa-Tech/chalupa-tech-local/pull/11)
