package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/muhlba91/pulumi-proxmoxve/sdk/v7/go/proxmoxve"
	"github.com/muhlba91/pulumi-proxmoxve/sdk/v7/go/proxmoxve/vm"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/client"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/cluster"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

const (
	talosClusterName = "chalupa-cluster"
	talosVersion     = "v1.12.7"
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
	diskGB      int
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
		{"talos-cp", 300, controlPlaneIP, "controlplane", 4, 2, 6144, 50},
		{"talos-cp-2", 304, "192.168.1.228", "controlplane", 4, 2, 6144, 50},
		{"talos-cp-3", 305, "192.168.1.229", "controlplane", 4, 2, 6144, 50},
		{"talos-worker-1", 301, "192.168.1.226", "worker", 5, 4, 20480, 100},
		{"talos-worker-2", 302, "192.168.1.227", "worker", 5, 4, 20480, 100},
		{"talos-worker-3", 303, "192.168.1.232", "worker", 5, 4, 20480, 100},
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

			// Disk first, then CD-ROM, then network. Without this, Proxmox defaults
			// to ide3 (CD) before scsi0 (disk). On a fresh VM that's correct — the
			// installer ISO boots, Talos installs to disk, then kexec's into the
			// installed kernel without re-reading BIOS. But the next time the VM
			// is stopped and started cold (e.g. a Pulumi resize that changes
			// CPU/memory), BIOS re-reads the boot order, hits ide3 first, loads
			// the ISO, and Talos's `halt_if_installed` kernel param halts the boot
			// — wedging the node at the installer prompt. With scsi0 first, the
			// installed Talos boots; the ISO stays attached for fresh-install
			// fallback (UEFI tries the next entry if scsi0 has no bootloader).
			BootOrders: pulumi.StringArray{
				pulumi.String("scsi0"),
				pulumi.String("ide3"),
				pulumi.String("net0"),
			},

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
					Size:        pulumi.Int(node.diskGB),
					FileFormat:  pulumi.String("raw"),
				},
			},
			Cdrom: &vm.VirtualMachineCdromArgs{
				FileId: pulumi.String(fmt.Sprintf("local:iso/talos-nocloud-amd64-%s.iso", talosVersion)),
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
		}, pulumi.Provider(pveProvider), pulumi.IgnoreChanges([]string{"started", "cdrom"}))
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

	// pulumi-talos's NewKubeconfig pulls the kubeconfig from the cluster, which still
	// has the original bootstrap server URL (https://controlPlaneIP:6443) baked in —
	// changing cluster.controlPlaneEndpoint in the machine config doesn't regenerate
	// the cluster-stored kubeconfig. Rewrite the server URL to point at the VIP so
	// `kubectl cluster-info` and any tooling consuming this output stay correct.
	kubeconfigVIP := kubeconfig.KubeconfigRaw.ApplyT(func(raw string) string {
		return strings.ReplaceAll(
			raw,
			fmt.Sprintf("https://%s:6443", controlPlaneIP),
			fmt.Sprintf("https://%s:6443", controlPlaneVIP),
		)
	}).(pulumi.StringOutput)

	ctx.Export("kubeconfig", kubeconfigVIP)

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
