package main

import (
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v7/go/proxmoxve"
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v7/go/proxmoxve/ct"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func createPlexLXC(ctx *pulumi.Context, pveProvider *proxmoxve.Provider) error {
	_, err := ct.NewContainer(ctx, "plex-lxc", &ct.ContainerArgs{
		NodeName:    pulumi.String("proxmox"),
		VmId:        pulumi.Int(200),
		Description: pulumi.String("Plex Media Server LXC (Managed by Pulumi)"),

		// Ubuntu 24.04 LTS container template (downloaded by Ansible in Stage 1)
		OperatingSystem: &ct.ContainerOperatingSystemArgs{
			TemplateFileId: pulumi.String("local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"),
			Type:           pulumi.String("ubuntu"),
		},

		Cpu: &ct.ContainerCpuArgs{
			Cores: pulumi.Int(8),
		},
		Memory: &ct.ContainerMemoryArgs{
			Dedicated: pulumi.Int(8192), // 8 GB — LXC is lighter than a full VM
		},

		// Root filesystem
		Disk: &ct.ContainerDiskArgs{
			DatastoreId: pulumi.String("local-lvm"),
			Size:        pulumi.Int(16), // 16 GB — Plex metadata ~5 GB + headroom
		},

		NetworkInterfaces: ct.ContainerNetworkInterfaceArray{
			&ct.ContainerNetworkInterfaceArgs{
				Name:   pulumi.String("eth0"),
				Bridge: pulumi.String("vmbr0"),
			},
		},

		// Static IP — same as the old Plex VM for seamless client migration
		Initialization: &ct.ContainerInitializationArgs{
			Hostname: pulumi.String("plex"),
			IpConfigs: ct.ContainerInitializationIpConfigArray{
				&ct.ContainerInitializationIpConfigArgs{
					Ipv4: &ct.ContainerInitializationIpConfigIpv4Args{
						Address: pulumi.String("192.168.1.224/24"),
						Gateway: pulumi.String("192.168.1.1"),
					},
				},
			},
			Dns: &ct.ContainerInitializationDnsArgs{
				Servers: pulumi.StringArray{
					pulumi.String("192.168.1.1"),
					pulumi.String("1.1.1.1"),
				},
			},
			UserAccount: &ct.ContainerInitializationUserAccountArgs{
				Keys: pulumi.StringArray{
					// Personal key (tbigelow@Mac) — for manual SSH access
					pulumi.String("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINvR9jYqq/EEuoMyJEloxILC6XfNAGHwoaMP4fMNk7ca"),
					// CI runner key (pulumi_proxmox_runner) — for Stage 3 Ansible
					pulumi.String("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII8mSi1hjt/MpS6JtS06rwI1pWHMF9hBet6rKHADCiUp"),
				},
			},
		},

		// GPU render device (/dev/dri/renderD128) is passed through post-creation
		// via `pct set` in the deploy workflow (Stage 3). Proxmox restricts
		// device passthrough configuration to root@pam, which API tokens
		// cannot provide — so it's done via SSH as root on the host instead.
		//
		// Nesting for systemd inside the container
		Features: &ct.ContainerFeaturesArgs{
			Nesting: pulumi.Bool(true),
		},

		Unprivileged: pulumi.Bool(false),
		Started:      pulumi.Bool(true),
		StartOnBoot:  pulumi.Bool(true),
		Startup: &ct.ContainerStartupArgs{
			Order: pulumi.Int(3), // After TrueNAS (order 1) — NFS dependency
		},
	}, pulumi.Provider(pveProvider), pulumi.IgnoreChanges([]string{"started"}))
	if err != nil {
		return err
	}

	ctx.Export("plex-ip", pulumi.String("192.168.1.224"))

	return nil
}
