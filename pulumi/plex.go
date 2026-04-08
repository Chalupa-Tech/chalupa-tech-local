package main

import (
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v7/go/proxmoxve"
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v7/go/proxmoxve/vm"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func createPlexVM(ctx *pulumi.Context, pveProvider *proxmoxve.Provider) error {
	_, err := vm.NewVirtualMachine(ctx, "plex-server", &vm.VirtualMachineArgs{
		NodeName:    pulumi.String("proxmox"),
		VmId:        pulumi.Int(200),
		Name:        pulumi.String("plex"),
		Description: pulumi.String("Plex Media Server VM (Managed by Pulumi)"),
		Bios:        pulumi.String("ovmf"),
		Machine:     pulumi.String("q35"),

		// Clone from Fedora 43 cloud template (created by Ansible in Stage 1)
		Clone: &vm.VirtualMachineCloneArgs{
			NodeName: pulumi.String("proxmox"),
			VmId:     pulumi.Int(9000),
			Full:     pulumi.Bool(true),
		},

		Cpu: &vm.VirtualMachineCpuArgs{
			Cores: pulumi.Int(8),
			Type:  pulumi.String("host"),
		},
		Memory: &vm.VirtualMachineMemoryArgs{
			Dedicated: pulumi.Int(32768), // 32 GB
		},

		// EFI disk — required for OVMF BIOS; inherited from template but
		// explicitly declared so Pulumi manages it
		EfiDisk: &vm.VirtualMachineEfiDiskArgs{
			DatastoreId:     pulumi.String("local-lvm"),
			FileFormat:      pulumi.String("raw"),
			PreEnrolledKeys: pulumi.Bool(false),
		},

		// Boot disk — resize the cloned 2 GB template disk to 64 GB
		Disks: vm.VirtualMachineDiskArray{
			&vm.VirtualMachineDiskArgs{
				DatastoreId: pulumi.String("local-lvm"),
				Interface:   pulumi.String("scsi0"),
				Size:        pulumi.Int(64),
				FileFormat:  pulumi.String("raw"),
			},
		},

		NetworkDevices: vm.VirtualMachineNetworkDeviceArray{
			&vm.VirtualMachineNetworkDeviceArgs{
				Bridge: pulumi.String("vmbr0"),
			},
		},

		// GPU passthrough via Proxmox Resource Mapping
		Hostpcis: vm.VirtualMachineHostpciArray{
			&vm.VirtualMachineHostpciArgs{
				Device:  pulumi.String("hostpci0"),
				Mapping: pulumi.String("strix_halo_gpu"),
				Pcie:    pulumi.Bool(true),
				Rombar:  pulumi.Bool(true),
			},
		},

		// Cloud-init configuration — applied on first boot
		Initialization: &vm.VirtualMachineInitializationArgs{
			DatastoreId: pulumi.String("local-lvm"),
			UserAccount: &vm.VirtualMachineInitializationUserAccountArgs{
				Username: pulumi.String("fedora"),
				Keys: pulumi.StringArray{
					pulumi.String("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINvR9jYqq/EEuoMyJEloxILC6XfNAGHwoaMP4fMNk7ca"),
				},
			},
			IpConfigs: vm.VirtualMachineInitializationIpConfigArray{
				&vm.VirtualMachineInitializationIpConfigArgs{
					Ipv4: &vm.VirtualMachineInitializationIpConfigIpv4Args{
						Address: pulumi.String("192.168.1.224/24"),
						Gateway: pulumi.String("192.168.1.1"),
					},
				},
			},
			Dns: &vm.VirtualMachineInitializationDnsArgs{
				Servers: pulumi.StringArray{
					pulumi.String("192.168.1.1"),
					pulumi.String("1.1.1.1"),
				},
			},
		},

		// Display: none — required for GPU passthrough, prevents virtual VGA
		// from conflicting with the passed-through GPU
		Vga: &vm.VirtualMachineVgaArgs{
			Type: pulumi.String("none"),
		},

		Agent: &vm.VirtualMachineAgentArgs{
			Enabled: pulumi.Bool(true),
		},

		OperatingSystem: &vm.VirtualMachineOperatingSystemArgs{
			Type: pulumi.String("l26"),
		},

		Started: pulumi.Bool(true),
		OnBoot:  pulumi.Bool(true),
		Startup: &vm.VirtualMachineStartupArgs{
			Order: pulumi.Int(3),
		},

		SerialDevices: vm.VirtualMachineSerialDeviceArray{
			&vm.VirtualMachineSerialDeviceArgs{
				Device: pulumi.String("socket"),
			},
		},
	}, pulumi.Provider(pveProvider), pulumi.IgnoreChanges([]string{"started"}))
	if err != nil {
		return err
	}

	ctx.Export("plex-ip", pulumi.String("192.168.1.224"))

	return nil
}
