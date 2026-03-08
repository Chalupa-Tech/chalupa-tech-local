# Fix Pulumi TLS Error

## Overview
The `pulumi up` command failed because it was unable to verify the TLS certificate of the Proxmox VE server. This is expected when using self-signed certificates.

## Changes
- Updated `pulumi/Pulumi.proxmox.yaml` to include `proxmoxve:insecure: true`. This configures the `muhlba91/pulumi-proxmoxve` provider to skip TLS certificate verification.

## Rationale
The Proxmox host in the local lab environment uses a self-signed certificate. By setting `insecure: true`, Pulumi can connect to the API without failing on certificate validation.

## PR Link
[Will be updated after PR creation]
