package main

import (
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v8/go/proxmoxve"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func createTrueNASVM(ctx *pulumi.Context, pveProvider *proxmoxve.Provider) error {
	_, err := proxmoxve.NewVmLegacy(ctx, "truenas-scale", &proxmoxve.VmLegacyArgs{
		NodeName:    pulumi.String("proxmox"),
		Name:        pulumi.String("truenas-scale"),
		Description: pulumi.String("TrueNAS SCALE VM (Managed by Pulumi)"),
		Bios:        pulumi.String("ovmf"),
		Machine:     pulumi.String("q35"),

		Cpu: &proxmoxve.VmLegacyCpuArgs{
			Cores: pulumi.Int(4),
			Type:  pulumi.String("host"),
		},
		Memory: &proxmoxve.VmLegacyMemoryArgs{
			Dedicated: pulumi.Int(32768),
		},
		NetworkDevices: proxmoxve.VmLegacyNetworkDeviceArray{
			// net0: management + WAN egress (default MTU 1500).
			&proxmoxve.VmLegacyNetworkDeviceArgs{
				Bridge: pulumi.String("vmbr0"),
			},
			// net1: storage-only subnet on vmbr1 (jumbo frames, no
			// physical port). Internal NFS traffic to Talos workers
			// and Plex LXC flows here so the management plane stays
			// at MTU 1500 and the gigabit cap on vmbr0 doesn't pinch
			// NFS throughput. TrueNAS-side IP (10.10.10.40/24) is
			// configured manually in the TrueNAS UI — pulumi only
			// adds the virtual NIC; the OS owns IP assignment.
			&proxmoxve.VmLegacyNetworkDeviceArgs{
				Bridge: pulumi.String("vmbr1"),
				Mtu:    pulumi.Int(9000),
			},
		},
		Hostpcis: proxmoxve.VmLegacyHostpciArray{
			&proxmoxve.VmLegacyHostpciArgs{
				Device:  pulumi.String("hostpci0"),
				Mapping: pulumi.String("hba_part_1"),
				Pcie:    pulumi.Bool(true),
				Rombar:  pulumi.Bool(true),
			},
			&proxmoxve.VmLegacyHostpciArgs{
				Device:  pulumi.String("hostpci1"),
				Mapping: pulumi.String("hba_part_2"),
				Pcie:    pulumi.Bool(true),
				Rombar:  pulumi.Bool(true),
			},
		},
		Disks: proxmoxve.VmLegacyDiskArray{
			&proxmoxve.VmLegacyDiskArgs{
				DatastoreId: pulumi.String("local-lvm"),
				Interface:   pulumi.String("scsi0"),
				Size:        pulumi.Int(32),
				FileFormat:  pulumi.String("raw"),
			},
		},
		Cdrom: &proxmoxve.VmLegacyCdromArgs{
			FileId: pulumi.String("none"),
		},
		Started: pulumi.Bool(true),
		OnBoot:  pulumi.Bool(true),
		OperatingSystem: &proxmoxve.VmLegacyOperatingSystemArgs{
			Type: pulumi.String("l26"),
		},
		Startup: &proxmoxve.VmLegacyStartupArgs{
			Order: pulumi.Int(1),
		},
		Vga: &proxmoxve.VmLegacyVgaArgs{
			Type: pulumi.String("vmware"),
		},
	},
		pulumi.Provider(pveProvider),
		// SDK v8 renamed the resource token (VM/virtualMachine ->
		// index/vmLegacy). Alias the old type so existing state maps
		// in place instead of planning a destroy/recreate.
		pulumi.Aliases([]pulumi.Alias{{Type: pulumi.String("proxmoxve:VM/virtualMachine:VirtualMachine")}}),
		// IgnoreChanges["disks"]: Proxmox sets unmanaged sub-fields
		// (aio, backup, cache, discard, iothread, replicate, ssd) that
		// pulumi-proxmoxve reads back as drift, triggering a no-op
		// "update" on every apply. TrueNAS data lives on the HBA-passed
		// pool, not scsi0 — ignoring scsi0 entirely is acceptable here.
		pulumi.IgnoreChanges([]string{"started", "disks"}),
		pulumi.Protect(true),
	)
	return err
}
