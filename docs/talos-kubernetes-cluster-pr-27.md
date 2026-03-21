# Talos Kubernetes Cluster

## Changes Made
- Created a new Pulumi module `pulumi/talos.go` containing the infrastructure deployment logic for a 3-node Talos Kubernetes cluster on Proxmox.
- The definition uses 3 `vm.VirtualMachine` resources (for nodes: `talos-cp`, `talos-worker-1`, `talos-worker-2`) and connects to `vmbr0`.
- Integrated `talos.machine.NewSecrets` to generate machine secrets independently for the new cluster.
- Implemented a dynamic DHCP IP retrieval mechanism for the Talos nodes by extracting the `Ipv4Addresses` reported by the QEMU guest agent once they boot into maintenance mode.
- Used `talos.machine.GetConfigurationOutput` coupled with YAML strategic merge `ConfigPatches` to inject static network settings (`192.168.1.42`, `192.168.1.43`, `192.168.1.44` with a gateway of `192.168.1.1`) into the machine configuration.
- Configured `talos.machine.ConfigurationApply` with an `ApplyMode` set to `"reboot"`. This pushes the `MachineConfiguration` containing the static IP setup via the temporary DHCP address and subsequently forces the node to reboot to reflect the networking changes natively.

## Rationale
- The user requested to deploy a greenfield 3-node Talos Kubernetes Cluster via Pulumi while strictly bypassing previous implementations.
- Proxmox's native Cloud-Init network logic is bypassed in favor of Talos's internal configurations using `ConfigPatches`, per the requirement to allow nodes to natively manage their own static settings while circumventing potential IP overlap/state issues during initialization. By depending on `ConfigurationApply` with `ApplyMode` as `reboot`, we ensure the static IP network state is actively enforced by Talos Linux itself.

## Associated PR
- Pull Request #27 (Resolves Feature Request)
