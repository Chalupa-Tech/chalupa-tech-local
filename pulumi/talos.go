package main

import (
	"fmt"

	"github.com/muhlba91/pulumi-proxmoxve/sdk/v6/go/proxmoxve"
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v6/go/proxmoxve/vm"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/client"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

// extractVMIP extracts the first non-loopback IPv4 address from a Proxmox VM's
// QEMU guest agent output. The Ipv4Addresses output is a [][]string where each
// outer element is a network interface and each inner element is an IP on that
// interface. We skip 127.0.0.1 (loopback) and return the first real IP found.
func extractVMIP(vmResource *vm.VirtualMachine) pulumi.StringOutput {
	return vmResource.Ipv4Addresses.ApplyT(func(addrs [][]string) string {
		for _, iface := range addrs {
			for _, ip := range iface {
				if ip != "127.0.0.1" && ip != "" {
					return ip
				}
			}
		}
		return ""
	}).(pulumi.StringOutput)
}

func setupTalosCluster(ctx *pulumi.Context, pveProvider *proxmoxve.Provider) error {
	clusterName := "proxmox-cluster"
	controlPlaneIP := "192.168.1.41"
	worker1IP := "192.168.1.42"
	worker2IP := "192.168.1.43"
	gateway := "192.168.1.1"

	// 1. Generate Talos Secrets
	secrets, err := machine.NewSecrets(ctx, "talos-secrets", nil)
	if err != nil {
		return err
	}

	// 2. Generate Control Plane Machine Configuration
	cpConfig := machine.GetConfigurationOutput(ctx, machine.GetConfigurationOutputArgs{
		ClusterName:     pulumi.String(clusterName),
		MachineType:     pulumi.String("controlplane"),
		ClusterEndpoint: pulumi.String(fmt.Sprintf("https://%s:6443", controlPlaneIP)),
		MachineSecrets:  secrets.MachineSecrets,
		ConfigPatches: pulumi.StringArray{
			pulumi.String(fmt.Sprintf(`
machine:
  network:
    interfaces:
      - interface: enp0s18
        addresses:
          - %s/24
        routes:
          - network: 0.0.0.0/0
            gateway: %s
    nameservers:
      - 1.1.1.1
      - 8.8.8.8
`, controlPlaneIP, gateway)),
		},
	})

	// 3. Export the control plane machine configuration for use with talosctl
	ctx.Export("talos-cp-config", cpConfig.MachineConfiguration())

	// 4. Provision Control Plane VM
	cpVM, err := vm.NewVirtualMachine(ctx, "talos-cp", &vm.VirtualMachineArgs{
		NodeName:    pulumi.String("proxmox"),
		Name:        pulumi.String("talos-cp-01"),
		Description: pulumi.String("Talos Control Plane"),
		Bios:        pulumi.String("ovmf"),
		Machine:     pulumi.String("q35"),
		Cpu: &vm.VirtualMachineCpuArgs{
			Cores: pulumi.Int(6),
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
				Size:        pulumi.Int(120),
				FileFormat:  pulumi.String("raw"),
			},
		},
		Cdrom: &vm.VirtualMachineCdromArgs{
			FileId: pulumi.String("local:iso/nocloud-amd64.iso"),
		},
		Agent: &vm.VirtualMachineAgentArgs{
			Enabled: pulumi.Bool(true),
		},

		Started: pulumi.Bool(true),
		OnBoot:  pulumi.Bool(true),
		OperatingSystem: &vm.VirtualMachineOperatingSystemArgs{
			Type: pulumi.String("l26"),
		},
	}, pulumi.Provider(pveProvider), pulumi.IgnoreChanges([]string{"started", "cdrom"}))
	if err != nil {
		return err
	}

	// 5. Apply the Talos machine config to the Control Plane VM.
	//    The VM boots from the nocloud ISO into maintenance mode with a DHCP IP.
	//    We extract the DHCP IP from the QEMU guest agent output, then apply
	//    the machine config (which includes the static IP) to initiate setup.
	cpDHCPIP := extractVMIP(cpVM)

	cpApply, err := machine.NewConfigurationApply(ctx, "talos-cp-apply", &machine.ConfigurationApplyArgs{
		ClientConfiguration:       secrets.ClientConfiguration,
		MachineConfigurationInput: cpConfig.MachineConfiguration(),
		Node:                      cpDHCPIP,
		Endpoint:                  cpDHCPIP,
		ApplyMode:                 pulumi.String("reboot"),
		Timeouts: &machine.TimeoutArgs{
			Create: pulumi.String("15m"),
		},
	}, pulumi.DependsOn([]pulumi.Resource{cpVM}))
	if err != nil {
		return err
	}

	// 6. Provision Worker VMs and apply their configs
	workerIPs := []string{worker1IP, worker2IP}
	var workerApplies []*machine.ConfigurationApply
	for i, ip := range workerIPs {
		nodeIdx := i + 1

		// Generate Worker Machine Configuration with Static IP
		workerConfig := machine.GetConfigurationOutput(ctx, machine.GetConfigurationOutputArgs{
			ClusterName:     pulumi.String(clusterName),
			MachineType:     pulumi.String("worker"),
			ClusterEndpoint: pulumi.String(fmt.Sprintf("https://%s:6443", controlPlaneIP)),
			MachineSecrets:  secrets.MachineSecrets,
			ConfigPatches: pulumi.StringArray{
				pulumi.String(fmt.Sprintf(`
machine:
  network:
    interfaces:
      - interface: enp0s18
        addresses:
          - %s/24
        routes:
          - network: 0.0.0.0/0
            gateway: %s
    nameservers:
      - 1.1.1.1
      - 8.8.8.8
`, ip, gateway)),
			},
		})

		// Export the worker machine configuration for use with talosctl
		ctx.Export(fmt.Sprintf("talos-worker-config-%d", nodeIdx), workerConfig.MachineConfiguration())

		workerVM, err := vm.NewVirtualMachine(ctx, fmt.Sprintf("talos-worker-%d", nodeIdx), &vm.VirtualMachineArgs{
			NodeName:    pulumi.String("proxmox"),
			Name:        pulumi.String(fmt.Sprintf("talos-worker-%02d", nodeIdx)),
			Description: pulumi.String(fmt.Sprintf("Talos Worker %d", nodeIdx)),
			Bios:        pulumi.String("ovmf"),
			Machine:     pulumi.String("q35"),
			Cpu: &vm.VirtualMachineCpuArgs{
				Cores: pulumi.Int(6),
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
					Size:        pulumi.Int(120),
					FileFormat:  pulumi.String("raw"),
				},
			},
			Cdrom: &vm.VirtualMachineCdromArgs{
				FileId: pulumi.String("local:iso/nocloud-amd64.iso"),
			},
			Agent: &vm.VirtualMachineAgentArgs{
				Enabled: pulumi.Bool(true),
			},
			Started: pulumi.Bool(true),
			OnBoot:  pulumi.Bool(true),
			OperatingSystem: &vm.VirtualMachineOperatingSystemArgs{
				Type: pulumi.String("l26"),
			},
		}, pulumi.Provider(pveProvider), pulumi.IgnoreChanges([]string{"started", "cdrom"}))
		if err != nil {
			return err
		}

		// Apply the Talos machine config to the worker VM via its DHCP IP
		workerDHCPIP := extractVMIP(workerVM)

		workerApply, err := machine.NewConfigurationApply(ctx, fmt.Sprintf("talos-worker-%d-apply", nodeIdx), &machine.ConfigurationApplyArgs{
			ClientConfiguration:       secrets.ClientConfiguration,
			MachineConfigurationInput: workerConfig.MachineConfiguration(),
			Node:                      workerDHCPIP,
			Endpoint:                  workerDHCPIP,
			ApplyMode:                 pulumi.String("reboot"),
			Timeouts: &machine.TimeoutArgs{
				Create: pulumi.String("15m"),
			},
		}, pulumi.DependsOn([]pulumi.Resource{workerVM}))
		if err != nil {
			return err
		}
		workerApplies = append(workerApplies, workerApply)
	}

	// 7. Bootstrap the Cluster — depends on CP config being applied
	//    After ConfigurationApply, the CP VM reboots with its static IP,
	//    so we target the static IP for bootstrap.
	_, err = machine.NewBootstrap(ctx, "talos-bootstrap", &machine.BootstrapArgs{
		Node:                pulumi.String(controlPlaneIP),
		Endpoint:            pulumi.String(controlPlaneIP),
		ClientConfiguration: secrets.ClientConfiguration,
		Timeouts: &machine.BootstrapTimeoutsArgs{
			Create: pulumi.String("10m"),
		},
	}, pulumi.DependsOn([]pulumi.Resource{cpApply}))
	if err != nil {
		return err
	}

	// 8. Generate talosconfig client configuration
	talosConfig := client.GetConfigurationOutput(ctx, client.GetConfigurationOutputArgs{
		ClusterName: pulumi.String(clusterName),
		ClientConfiguration: secrets.ClientConfiguration.ApplyT(func(conf machine.ClientConfiguration) client.GetConfigurationClientConfiguration {
			return client.GetConfigurationClientConfiguration{
				CaCertificate:     conf.CaCertificate,
				ClientCertificate: conf.ClientCertificate,
				ClientKey:         conf.ClientKey,
			}
		}).(client.GetConfigurationClientConfigurationOutput),
		Endpoints: pulumi.StringArray{pulumi.String(controlPlaneIP)},
		Nodes:     pulumi.StringArray{pulumi.String(controlPlaneIP)},
	})

	ctx.Export("talosconfig", talosConfig.TalosConfig())

	// Suppress unused variable warnings for workerApplies
	_ = workerApplies

	return nil
}
