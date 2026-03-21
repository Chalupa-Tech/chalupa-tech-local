package main

import (
	"fmt"
	"strings"

	"github.com/muhlba91/pulumi-proxmoxve/sdk/v6/go/proxmoxve"
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v6/go/proxmoxve/vm"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

func createTalosCluster(ctx *pulumi.Context, pveProvider *proxmoxve.Provider) error {
	// 1. Generate Talos Secrets
	secrets, err := machine.NewSecrets(ctx, "talos-secrets", nil)
	if err != nil {
		return err
	}

	nodes := []struct {
		name        string
		ip          string
		machineType string
	}{
		{"talos-cp", "192.168.1.42", "controlplane"},
		{"talos-worker-1", "192.168.1.43", "worker"},
		{"talos-worker-2", "192.168.1.44", "worker"},
	}

	for _, node := range nodes {
		// 2. Generate configuration with patches for static IP
		// Note from plan: The patch updates the network interface to use the desired static IP.
		patch := fmt.Sprintf(`[
			{"op": "add", "path": "/machine/network", "value": {"interfaces": [{"interface": "eth0", "dhcp": false, "addresses": ["%s/24"], "routes": [{"network": "0.0.0.0/0", "gateway": "192.168.1.1"}]}]}}
		]`, node.ip)

		configArgs := machine.GetConfigurationOutputArgs{
			ClusterName:     pulumi.String("talos-cluster"),
			MachineType:     pulumi.String(node.machineType),
			ClusterEndpoint: pulumi.String("https://192.168.1.42:6443"),
			MachineSecrets:  secrets.MachineSecrets,
			ConfigPatches:   pulumi.StringArray{pulumi.String(patch)},
		}

		config := machine.GetConfigurationOutput(ctx, configArgs, nil)

		// 3. Define Proxmox VM without CloudInit network configurations
		talosVM, err := vm.NewVirtualMachine(ctx, node.name, &vm.VirtualMachineArgs{
			NodeName:    pulumi.String("proxmox"),
			Name:        pulumi.String(node.name),
			Description: pulumi.String(fmt.Sprintf("Talos Linux Node - %s (Managed by Pulumi)", node.name)),
			Bios:        pulumi.String("ovmf"),
			Machine:     pulumi.String("q35"),
			Cpu: &vm.VirtualMachineCpuArgs{
				Cores: pulumi.Int(4),
				Type:  pulumi.String("host"),
			},
			Memory: &vm.VirtualMachineMemoryArgs{
				Dedicated: pulumi.Int(16384),
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
					Size:        pulumi.Int(32),
					FileFormat:  pulumi.String("raw"),
				},
			},
			Cdrom: &vm.VirtualMachineCdromArgs{
				FileId: pulumi.String("local:iso/nocloud-amd64.iso"),
			},
			OperatingSystem: &vm.VirtualMachineOperatingSystemArgs{
				Type: pulumi.String("l26"),
			},
			Agent: &vm.VirtualMachineAgentArgs{
				Enabled: pulumi.Bool(true),
			},
			Vga: &vm.VirtualMachineVgaArgs{
				Type: pulumi.String("vmware"),
			},
			Started: pulumi.Bool(true),
			OnBoot:  pulumi.Bool(true),
		}, pulumi.Provider(pveProvider), pulumi.IgnoreChanges([]string{"started"}))
		if err != nil {
			return err
		}

		// 4. Extract Dynamic IP from QEMU guest agent
		dhcpIp := talosVM.Ipv4Addresses.ApplyT(func(ips [][]string) (string, error) {
			for _, ifaceIps := range ips {
				for _, ip := range ifaceIps {
					// Exclude localhost/loopback addresses
					if ip != "127.0.0.1" && ip != "" && ip != "::1" && !strings.HasPrefix(ip, "169.254.") {
						return ip, nil
					}
				}
			}
			return "", nil // Important: return empty so preview doesn't fail when IPs aren't ready yet
		}).(pulumi.StringOutput)

		// 5. Apply the static node configuration to the dynamic DHCP IP endpoint
		_, err = machine.NewConfigurationApply(ctx, fmt.Sprintf("%s-config-apply", node.name), &machine.ConfigurationApplyArgs{
			Endpoint:                  dhcpIp,
			Node:                      dhcpIp,
			ClientConfiguration:       secrets.ClientConfiguration,
			MachineConfigurationInput: config.MachineConfiguration(),
			ApplyMode:                 pulumi.String("reboot"), // Nodes will reboot to apply network configuration
		}, pulumi.DependsOn([]pulumi.Resource{talosVM}))
		if err != nil {
			return err
		}
	}

	return nil
}
