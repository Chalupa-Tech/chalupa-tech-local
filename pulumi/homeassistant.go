package main

import (
	"fmt"

	"github.com/muhlba91/pulumi-proxmoxve/sdk/v7/go/proxmoxve"
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v7/go/proxmoxve/vm"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

func createHomeAssistantVM(ctx *pulumi.Context, pveProvider *proxmoxve.Provider) error {
	cfg := config.New(ctx, "chalupa-infra")
	haosVersion := cfg.Require("haosVersion")

	// ImportFrom references the decompressed HAOS qcow2 staged by
	// Ansible's proxmox_prep role at /var/lib/vz/import/. The
	// pulumi-proxmoxve provider requires the 'import' content type
	// for VM disk imports — PR #191's initial FileId+iso form failed
	// at apply time with "unable to parse directory volume name"
	// (iso content type is for CDROM media, not VM disks; the SDK
	// docstring is misleading on this point).
	//
	// download.File would be the GitOps-friendly alternative, but its
	// decompressionAlgorithm only supports gz/lzo/zst/bz2 — not xz,
	// which is the only format HAOS publishes. Ansible owns the xz step.
	haosImportRef := fmt.Sprintf("local:import/haos_ova-%s.qcow2", haosVersion)

	_, err := vm.NewVirtualMachine(ctx, "homeassistant", &vm.VirtualMachineArgs{
		VmId:        pulumi.Int(250),
		NodeName:    pulumi.String("proxmox"),
		Name:        pulumi.String("homeassistant"),
		Description: pulumi.String("Home Assistant OS (Managed by Pulumi)"),
		Bios:        pulumi.String("ovmf"),
		Machine:     pulumi.String("q35"),

		Cpu: &vm.VirtualMachineCpuArgs{
			Cores: pulumi.Int(4),
			Type:  pulumi.String("host"),
		},
		Memory: &vm.VirtualMachineMemoryArgs{
			Dedicated: pulumi.Int(8192),
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
				Size:        pulumi.Int(60),
				FileFormat:  pulumi.String("raw"),
				ImportFrom:  pulumi.String(haosImportRef),
			},
		},
		Usbs: vm.VirtualMachineUsbArray{
			&vm.VirtualMachineUsbArgs{
				// Named Proxmox Resource Mapping. Created out-of-band in the
				// Proxmox UI (Datacenter -> Resource Mappings -> USB Devices)
				// because the dongle vendor:product is captured at the time of
				// the physical install — see the PR description for the
				// pre-merge runbook covering this step.
				Mapping: pulumi.String("aeotec-zstick-10"),
				Usb3:    pulumi.Bool(true),
			},
		},
		BootOrders: pulumi.StringArray{
			pulumi.String("scsi0"),
		},
		Agent: &vm.VirtualMachineAgentArgs{
			// HAOS doesn't ship qemu-guest-agent by default; we set the static
			// IP via the HAOS UI on first boot rather than waiting for an
			// agent-reported lease. Skipping WaitForIp keeps `pulumi up` fast.
			Enabled: pulumi.Bool(false),
		},
		Started: pulumi.Bool(true),
		OnBoot:  pulumi.Bool(true),
		OperatingSystem: &vm.VirtualMachineOperatingSystemArgs{
			Type: pulumi.String("l26"),
		},
		Startup: &vm.VirtualMachineStartupArgs{
			Order: pulumi.Int(6),
		},
		Vga: &vm.VirtualMachineVgaArgs{
			Type: pulumi.String("vmware"),
		},
	},
		pulumi.Provider(pveProvider),
		// IgnoreChanges["disks"] prevents a routine HAOS version bump
		// (which changes ImportFrom) from triggering a destroy/recreate
		// of the boot disk. First-apply imports from ImportFrom;
		// thereafter Pulumi leaves the disk alone.
		// IgnoreChanges["started"] matches the TrueNAS/Talos pattern.
		pulumi.IgnoreChanges([]string{"started", "disks"}),
		// Protect(true) matches TrueNAS posture — accidental teardown loses
		// accumulating HA configuration + history (Z-Wave network state lives
		// in the dongle NVM and would survive, but everything else wouldn't).
		pulumi.Protect(true),
	)
	return err
}
