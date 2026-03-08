package main

import (
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v6/go/proxmoxve/vm"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func createTrueNASVM(ctx *pulumi.Context) error {
	_, err := vm.NewVirtualMachine(ctx, "truenas-scale", &vm.VirtualMachineArgs{
		NodeName:    pulumi.String("proxmox"),
		Name:        pulumi.String("truenas-scale"),
		Description: pulumi.String("TrueNAS SCALE VM (Managed by Pulumi)"),
		Bios:        pulumi.String("ovmf"),
		Machine:     pulumi.String("q35"),

		Cpu: &vm.VirtualMachineCpuArgs{
			Cores: pulumi.Int(4),
			Type:  pulumi.String("host"),
		},
		Memory: &vm.VirtualMachineMemoryArgs{
			Dedicated: pulumi.Int(16000),
		},
		NetworkDevices: vm.VirtualMachineNetworkDeviceArray{
			&vm.VirtualMachineNetworkDeviceArgs{
				Bridge: pulumi.String("vmbr0"),
			},
		},
		Hostpcis: vm.VirtualMachineHostpciArray{
			&vm.VirtualMachineHostpciArgs{
				Device:  pulumi.String("hostpci0"),
				Mapping: pulumi.String("hba_part_1"),
				Pcie:    pulumi.Bool(true),
				Rombar:  pulumi.Bool(true),
			},
			&vm.VirtualMachineHostpciArgs{
				Device:  pulumi.String("hostpci1"),
				Mapping: pulumi.String("hba_part_2"),
				Pcie:    pulumi.Bool(true),
				Rombar:  pulumi.Bool(true),
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
			Enabled: pulumi.Bool(true),
			FileId:  pulumi.String("local:iso/TrueNAS-SCALE-25.10-RC.1.iso"),
		},
		OperatingSystem: &vm.VirtualMachineOperatingSystemArgs{
			Type: pulumi.String("l26"),
		},
	})
	return err
}
