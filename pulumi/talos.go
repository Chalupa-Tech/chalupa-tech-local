package main

import (
	"fmt"

	"github.com/muhlba91/pulumi-proxmoxve/sdk/v6/go/proxmoxve"
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v6/go/proxmoxve/storage"
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v6/go/proxmoxve/vm"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/client"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

func setupTalosCluster(ctx *pulumi.Context, pveProvider *proxmoxve.Provider) error {
	clusterName := "proxmox-cluster"
	controlPlaneIP := "192.168.1.41"
	worker1IP := "192.168.1.42"
	worker2IP := "192.168.1.43"

	// 1. Generate Talos Secrets
	secrets, err := machine.NewSecrets(ctx, "talos-secrets", nil)
	if err != nil {
		return err
	}

	// 2. Generate Machine Configurations
	cpConfig := machine.GetConfigurationOutput(ctx, machine.GetConfigurationOutputArgs{
		ClusterName:     pulumi.String(clusterName),
		MachineType:     pulumi.String("controlplane"),
		ClusterEndpoint: pulumi.String(fmt.Sprintf("https://%s:6443", controlPlaneIP)),
		MachineSecrets:  secrets.MachineSecrets,
	})

	workerConfig := machine.GetConfigurationOutput(ctx, machine.GetConfigurationOutputArgs{
		ClusterName:     pulumi.String(clusterName),
		MachineType:     pulumi.String("worker"),
		ClusterEndpoint: pulumi.String(fmt.Sprintf("https://%s:6443", controlPlaneIP)),
		MachineSecrets:  secrets.MachineSecrets,
	})

	// 3. Upload Talos configs as snippets
	cpSnippet, err := storage.NewFile(ctx, "talos-cp-config", &storage.FileArgs{
		NodeName:    pulumi.String("proxmox"),
		DatastoreId: pulumi.String("local"),
		ContentType: pulumi.String("snippets"),
		SourceRaw: &storage.FileSourceRawArgs{
			Data:     cpConfig.MachineConfiguration(),
			FileName: pulumi.String("talos-cp-config.yaml"),
		},
	}, pulumi.Provider(pveProvider))
	if err != nil {
		return err
	}

	workerSnippet, err := storage.NewFile(ctx, "talos-worker-config", &storage.FileArgs{
		NodeName:    pulumi.String("proxmox"),
		DatastoreId: pulumi.String("local"),
		ContentType: pulumi.String("snippets"),
		SourceRaw: &storage.FileSourceRawArgs{
			Data:     workerConfig.MachineConfiguration(),
			FileName: pulumi.String("talos-worker-config.yaml"),
		},
	}, pulumi.Provider(pveProvider))
	if err != nil {
		return err
	}

	// 4. Provision Control Plane VM
	cpVM, err := vm.NewVirtualMachine(ctx, "talos-cp", &vm.VirtualMachineArgs{
		NodeName:    pulumi.String("proxmox"),
		Name:        pulumi.String("talos-cp-01"),
		Description: pulumi.String("Talos Control Plane"),
		Bios:        pulumi.String("ovmf"),
		Machine:     pulumi.String("q35"),
		Cpu: &vm.VirtualMachineCpuArgs{
			Cores: pulumi.Int(2),
			Type:  pulumi.String("host"),
		},
		Memory: &vm.VirtualMachineMemoryArgs{
			Dedicated: pulumi.Int(4096),
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
				Size:        pulumi.Int(40),
				FileFormat:  pulumi.String("raw"),
			},
		},
		Cdrom: &vm.VirtualMachineCdromArgs{
			Enabled: pulumi.Bool(true),
			FileId:  pulumi.String("local:iso/talos-metal-amd64.iso"),
		},
		Initialization: &vm.VirtualMachineInitializationArgs{
			DatastoreId:    pulumi.String("local-lvm"),
			UserDataFileId: cpSnippet.ID(),
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

	// 5. Provision Worker VMs
	workerIPs := []string{worker1IP, worker2IP}
	for i := range workerIPs {
		_, err := vm.NewVirtualMachine(ctx, fmt.Sprintf("talos-worker-%d", i+1), &vm.VirtualMachineArgs{
			NodeName:    pulumi.String("proxmox"),
			Name:        pulumi.String(fmt.Sprintf("talos-worker-%02d", i+1)),
			Description: pulumi.String(fmt.Sprintf("Talos Worker %d", i+1)),
			Bios:        pulumi.String("ovmf"),
			Machine:     pulumi.String("q35"),
			Cpu: &vm.VirtualMachineCpuArgs{
				Cores: pulumi.Int(2),
				Type:  pulumi.String("host"),
			},
			Memory: &vm.VirtualMachineMemoryArgs{
				Dedicated: pulumi.Int(4096),
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
					Size:        pulumi.Int(40),
					FileFormat:  pulumi.String("raw"),
				},
			},
			Cdrom: &vm.VirtualMachineCdromArgs{
				Enabled: pulumi.Bool(true),
				FileId:  pulumi.String("local:iso/talos-metal-amd64.iso"),
			},
			Initialization: &vm.VirtualMachineInitializationArgs{
				DatastoreId:    pulumi.String("local-lvm"),
				UserDataFileId: workerSnippet.ID(),
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
	}

	// 6. Bootstrap the Cluster
	_, err = machine.NewBootstrap(ctx, "talos-bootstrap", &machine.BootstrapArgs{
		Node:                pulumi.String(controlPlaneIP),
		Endpoint:            pulumi.String(controlPlaneIP),
		ClientConfiguration: secrets.ClientConfiguration,
	}, pulumi.DependsOn([]pulumi.Resource{cpVM}))
	if err != nil {
		return err
	}

	// 7. Generate talosconfig client configuration
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

	return nil
}
