package main

import (
	"fmt"
	"os"

	"github.com/muhlba91/pulumi-proxmoxve/sdk/v7/go/proxmoxve"
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v7/go/proxmoxve/vm"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/client"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/cluster"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

const (
	talosClusterName = "chalupa-cluster"
	talosVersion     = "v1.12.6"
	controlPlaneIP   = "192.168.1.225"
	controlPlaneVIP  = "192.168.1.231"
	gateway          = "192.168.1.1"
)

type talosNode struct {
	name        string
	vmid        int
	ip          string
	machineType string // "controlplane" or "worker"
	bootOrder   int
	cores       int
	memoryMB    int
}

func buildMachineConfigPatch(node talosNode) string {
	vipBlock := ""
	if node.machineType == "controlplane" {
		vipBlock = fmt.Sprintf("        vip:\n          ip: %s\n", controlPlaneVIP)
	}

	return fmt.Sprintf(`machine:
  network:
    interfaces:
      - deviceSelector:
          busPath: "0*"
        dhcp: false
        addresses:
          - %s/24
        routes:
          - network: 0.0.0.0/0
            gateway: %s
%s    nameservers:
      - 1.1.1.1
      - 8.8.8.8
  install:
    disk: /dev/sda
---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: %s
auto: off
`, node.ip, gateway, vipBlock, node.name)
}

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		sshUsername := os.Getenv("PROXMOX_VE_SSH_USERNAME")
		if sshUsername == "" {
			sshUsername = "root"
		}

		// Create a Proxmox provider with SSH agent support.
		// pulumi.Version is REQUIRED — see pulumi/main.go for explanation.
		pveProvider, err := proxmoxve.NewProvider(ctx, "proxmox-provider", &proxmoxve.ProviderArgs{
			Endpoint: pulumi.String(os.Getenv("PROXMOX_VE_ENDPOINT")),
			ApiToken: pulumi.String(os.Getenv("PROXMOX_VE_API_TOKEN")),
			Insecure: pulumi.Bool(true),
			Ssh: &proxmoxve.ProviderSshArgs{
				Agent:    pulumi.Bool(true),
				Username: pulumi.String(sshUsername),
			},
		}, pulumi.Version("7.13.0"))
		if err != nil {
			return err
		}

		if err := createTalosCluster(ctx, pveProvider); err != nil {
			return err
		}

		return nil
	})
}

func createTalosCluster(ctx *pulumi.Context, pveProvider *proxmoxve.Provider) error {
	nodes := []talosNode{
		{"talos-cp", 300, controlPlaneIP, "controlplane", 4, 2, 6144},
		{"talos-cp-2", 304, "192.168.1.228", "controlplane", 4, 2, 6144},
		{"talos-cp-3", 305, "192.168.1.229", "controlplane", 4, 2, 6144},
		{"talos-worker-1", 301, "192.168.1.226", "worker", 5, 4, 20480},
		{"talos-worker-2", 302, "192.168.1.227", "worker", 5, 4, 20480},
		{"talos-worker-3", 303, "192.168.1.232", "worker", 5, 4, 20480},
	}

	// Step 1: Generate cluster secrets (stored in Pulumi state for reproducibility)
	secrets, err := machine.NewSecrets(ctx, "talos-secrets", &machine.SecretsArgs{
		TalosVersion: pulumi.String(talosVersion),
	})
	if err != nil {
		return err
	}

	// Step 2: Create VMs, generate configs, and apply them
	var configApplyResources []pulumi.Resource

	for _, node := range nodes {
		// Create Proxmox VM
		talosVM, err := vm.NewVirtualMachine(ctx, node.name, &vm.VirtualMachineArgs{
			VmId:        pulumi.Int(node.vmid),
			NodeName:    pulumi.String("proxmox"),
			Name:        pulumi.String(node.name),
			Description: pulumi.String(fmt.Sprintf("Talos Linux %s (Managed by Pulumi)", node.machineType)),
			Bios:        pulumi.String("ovmf"),
			Machine:     pulumi.String("q35"),

			Cpu: &vm.VirtualMachineCpuArgs{
				Cores: pulumi.Int(node.cores),
				Type:  pulumi.String("host"),
			},
			Memory: &vm.VirtualMachineMemoryArgs{
				Dedicated: pulumi.Int(node.memoryMB),
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
					Size:        pulumi.Int(50),
					FileFormat:  pulumi.String("raw"),
				},
			},
			Cdrom: &vm.VirtualMachineCdromArgs{
				FileId: pulumi.String("local:iso/talos-nocloud-amd64.iso"),
			},
			Agent: &vm.VirtualMachineAgentArgs{
				Enabled: pulumi.Bool(true),
				Timeout: pulumi.String("10m"),
				WaitForIp: &vm.VirtualMachineAgentWaitForIpArgs{
					Ipv4: pulumi.Bool(true),
				},
			},
			Started: pulumi.Bool(true),
			OnBoot:  pulumi.Bool(true),
			OperatingSystem: &vm.VirtualMachineOperatingSystemArgs{
				Type: pulumi.String("l26"),
			},
			Startup: &vm.VirtualMachineStartupArgs{
				Order: pulumi.Int(node.bootOrder),
			},
			Vga: &vm.VirtualMachineVgaArgs{
				Type: pulumi.String("vmware"),
			},
		}, pulumi.Provider(pveProvider), pulumi.IgnoreChanges([]string{"started", "cdrom", "disks"}))
		if err != nil {
			return err
		}

		// Generate Talos machine configuration with static IP patch.
		// Talos v1.12+ auto-generates a HostnameConfig document with auto: stable.
		// Setting machine.network.hostname in the v1alpha1 doc conflicts with it,
		// so we override the HostnameConfig document directly (auto: off).
		patch := buildMachineConfigPatch(node)

		machineConfig := machine.GetConfigurationOutput(ctx, machine.GetConfigurationOutputArgs{
			ClusterEndpoint: pulumi.String(fmt.Sprintf("https://%s:6443", controlPlaneVIP)),
			ClusterName:     pulumi.String(talosClusterName),
			MachineType:     pulumi.String(node.machineType),
			MachineSecrets:  secrets.MachineSecrets,
			TalosVersion:    pulumi.String(talosVersion),
			ConfigPatches:   pulumi.StringArray{pulumi.String(patch)},
		}, nil)

		// Apply Talos configuration to the node, targeting the node's static IP.
		// Once a node is configured, it lives at node.ip — that's the only IP that's
		// reliably reachable. Earlier code targeted a DHCP IP captured from
		// qemu-guest-agent at create time, but that IP was a maintenance-mode lease
		// that goes stale the moment Talos applies the static-IP config and reboots.
		// Adding a brand-new node requires a manual `talosctl --insecure apply-config`
		// against its DHCP IP first, so it lands at node.ip before pulumi up runs.
		configApply, err := machine.NewConfigurationApply(ctx, fmt.Sprintf("%s-config-apply", node.name), &machine.ConfigurationApplyArgs{
			ClientConfiguration: machine.ClientConfigurationArgs{
				CaCertificate:     secrets.ClientConfiguration.CaCertificate(),
				ClientCertificate: secrets.ClientConfiguration.ClientCertificate(),
				ClientKey:         secrets.ClientConfiguration.ClientKey(),
			},
			MachineConfigurationInput: machineConfig.MachineConfiguration(),
			Node:                      pulumi.String(node.ip),
			Endpoint:                  pulumi.String(node.ip),
			ApplyMode:                 pulumi.String("reboot"),
		}, pulumi.DependsOn([]pulumi.Resource{talosVM}))
		if err != nil {
			return err
		}

		configApplyResources = append(configApplyResources, configApply)
	}

	// Step 3: Bootstrap the cluster (once, on the control plane node, using static IP post-reboot)
	// Bootstrap targets controlPlaneIP directly, NOT the VIP, even though the rest of the
	// stack speaks to the cluster via the VIP. This is a one-shot operation already recorded
	// in Pulumi state — changing Node/Endpoint here would attempt a re-bootstrap on a
	// running cluster (undefined behavior). Leave as controlPlaneIP.
	bootstrap, err := machine.NewBootstrap(ctx, "talos-bootstrap", &machine.BootstrapArgs{
		ClientConfiguration: machine.ClientConfigurationArgs{
			CaCertificate:     secrets.ClientConfiguration.CaCertificate(),
			ClientCertificate: secrets.ClientConfiguration.ClientCertificate(),
			ClientKey:         secrets.ClientConfiguration.ClientKey(),
		},
		Node:     pulumi.String(controlPlaneIP),
		Endpoint: pulumi.String(controlPlaneIP),
	}, pulumi.DependsOn(configApplyResources))
	if err != nil {
		return err
	}

	// Step 4: Retrieve kubeconfig
	kubeconfig, err := cluster.NewKubeconfig(ctx, "talos-kubeconfig", &cluster.KubeconfigArgs{
		ClientConfiguration: cluster.KubeconfigClientConfigurationArgs{
			CaCertificate:     secrets.ClientConfiguration.CaCertificate(),
			ClientCertificate: secrets.ClientConfiguration.ClientCertificate(),
			ClientKey:         secrets.ClientConfiguration.ClientKey(),
		},
		Node:     pulumi.String(controlPlaneVIP),
		Endpoint: pulumi.String(controlPlaneVIP),
	}, pulumi.DependsOn([]pulumi.Resource{bootstrap}))
	if err != nil {
		return err
	}

	ctx.Export("kubeconfig", kubeconfig.KubeconfigRaw)

	// Step 5: Generate talosconfig for talosctl access
	talosClientConfig := client.GetConfigurationOutput(ctx, client.GetConfigurationOutputArgs{
		ClientConfiguration: client.GetConfigurationClientConfigurationArgs{
			CaCertificate:     secrets.ClientConfiguration.CaCertificate(),
			ClientCertificate: secrets.ClientConfiguration.ClientCertificate(),
			ClientKey:         secrets.ClientConfiguration.ClientKey(),
		},
		ClusterName: pulumi.String(talosClusterName),
		Endpoints: pulumi.StringArray{
			pulumi.String(controlPlaneVIP),
		},
		Nodes: pulumi.StringArray{
			pulumi.String(controlPlaneIP),
			pulumi.String("192.168.1.228"),
			pulumi.String("192.168.1.229"),
			pulumi.String("192.168.1.226"),
			pulumi.String("192.168.1.227"),
			pulumi.String("192.168.1.232"),
		},
	}, nil)

	ctx.Export("talosconfig", talosClientConfig.TalosConfig())

	return nil
}
