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
	// storageIP is the static address on the vmbr1 storage subnet
	// (10.10.10.0/24, jumbo, no gateway). Empty for control-plane
	// nodes — they don't mount NFS. Workers get one and a second NIC
	// is added to the VM so NFS traffic to TrueNAS bypasses vmbr0.
	storageIP string
}

func buildMachineConfigPatch(node talosNode) string {
	vipBlock := ""
	if node.machineType == "controlplane" {
		vipBlock = fmt.Sprintf("        vip:\n          ip: %s\n", controlPlaneVIP)
	}

	// Talos on QEMU/KVM uses systemd predictable interface naming —
	// the first virtio NIC is `ens18`, the second is `ens19`, not
	// eth0/eth1. Using `interface: eth1` matches nothing and silently
	// fails. Worse, `deviceSelector: busPath: "0*"` is a glob that
	// matches every NIC on PCI bus 0 (both ens18 and ens19 in a
	// 2-NIC VM), so a glob in the primary stanza applies the primary
	// IP to BOTH interfaces — duplicate IP, broken storage subnet.
	// The PR #201 storage-net work shipped exactly that bug; this
	// patch pins explicit interface names to fix it.

	// Second interface on the storage subnet (ens19). Only emitted for
	// nodes with a storageIP — i.e. workers. Static config, jumbo MTU,
	// no routes (storage subnet is link-local) and no gateway (ens18
	// still owns the default route).
	storageIfaceBlock := ""
	if node.storageIP != "" {
		storageIfaceBlock = fmt.Sprintf(`      - interface: ens19
        dhcp: false
        mtu: 9000
        addresses:
          - %s/24
`, node.storageIP)
	}

	return fmt.Sprintf(`machine:
  kubelet:
    # Pin kubelet's registered Node InternalIP to the management subnet.
    # Without this, on multi-NIC workers Talos's default heuristic can
    # pick ens19's storage IP (10.10.10.x) as the InternalIP — that
    # subnet exists only on vmbr1, which CPs don't sit on, so the API
    # server can no longer reach the kubelet for exec/logs/port-forward/
    # proxy. Observed live 2026-05-18 right after PR #202 fixed the
    # storage-net duplicate-IP bug: workers came up with
    # InternalIP=10.10.10.226 and every exec attempt failed
    # "dial tcp 10.10.10.226:10250" from the API server.
    nodeIP:
      validSubnets:
        - 192.168.1.0/24
  network:
    interfaces:
      - interface: ens18
        dhcp: false
        addresses:
          - %s/24
        routes:
          - network: 0.0.0.0/0
            gateway: %s
%s%s    nameservers:
      - 1.1.1.1
      - 8.8.8.8
  install:
    disk: /dev/sda
---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: %s
auto: off
`, node.ip, gateway, vipBlock, storageIfaceBlock, node.name)
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
		// Last field (storageIP) is empty for CPs — they don't mount NFS.
		// Workers get a 10.10.10.x address on vmbr1 matching the last
		// octet of their primary IP for sanity.
		{"talos-cp", 300, controlPlaneIP, "controlplane", 4, 2, 4096, 50, ""},
		{"talos-cp-2", 304, "192.168.1.228", "controlplane", 4, 2, 4096, 50, ""},
		{"talos-cp-3", 305, "192.168.1.229", "controlplane", 4, 2, 4096, 50, ""},
		{"talos-worker-1", 301, "192.168.1.226", "worker", 5, 4, 20480, 100, "10.10.10.226"},
		{"talos-worker-2", 302, "192.168.1.227", "worker", 5, 4, 20480, 100, "10.10.10.227"},
		{"talos-worker-3", 303, "192.168.1.232", "worker", 5, 4, 20480, 100, "10.10.10.232"},
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

	// Serialize VM updates within each pool: chain each CP to depend on the
	// previous CP, and each worker to depend on the previous worker. Without
	// this, Pulumi parallelizes sibling-resource updates and a single apply
	// that triggers reboots (e.g. CPU/memory resize, machine-config change)
	// cold-restarts every member of the pool concurrently. For CPs that
	// breaks etcd quorum; for workers it drops the entire scheduling
	// capacity at once (verified live during PR #201 — all three workers
	// went NotReady simultaneously for ~60s while applying a new machine
	// config). The two pools chain independently so worker reboots don't
	// wait on CPs (or vice versa) — they just stagger within their own pool.
	var prevCPVM *vm.VirtualMachine
	var prevWorkerVM *vm.VirtualMachine

	for _, node := range nodes {
		vmOpts := []pulumi.ResourceOption{
			pulumi.Provider(pveProvider),
			pulumi.IgnoreChanges([]string{"started", "cdrom"}),
		}
		if node.machineType == "controlplane" && prevCPVM != nil {
			vmOpts = append(vmOpts, pulumi.DependsOn([]pulumi.Resource{prevCPVM}))
		}
		if node.machineType == "worker" && prevWorkerVM != nil {
			vmOpts = append(vmOpts, pulumi.DependsOn([]pulumi.Resource{prevWorkerVM}))
		}

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
			NetworkDevices: func() vm.VirtualMachineNetworkDeviceArray {
				devs := vm.VirtualMachineNetworkDeviceArray{
					// net0: management + WAN egress, default MTU 1500.
					&vm.VirtualMachineNetworkDeviceArgs{
						Bridge: pulumi.String("vmbr0"),
					},
				}
				// net1: storage subnet on vmbr1 (jumbo, internal-only).
				// Only added for nodes with a storageIP — i.e. workers,
				// since CPs don't mount NFS. The matching machine-config
				// patch configures eth1 with the static IP and MTU 9000.
				if node.storageIP != "" {
					devs = append(devs, &vm.VirtualMachineNetworkDeviceArgs{
						Bridge: pulumi.String("vmbr1"),
						Mtu:    pulumi.Int(9000),
					})
				}
				return devs
			}(),
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
		}, vmOpts...)
		if err != nil {
			return err
		}
		if node.machineType == "controlplane" {
			prevCPVM = talosVM
		}
		if node.machineType == "worker" {
			prevWorkerVM = talosVM
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
