package main

import (
	"os"

	"github.com/muhlba91/pulumi-proxmoxve/sdk/v6/go/proxmoxve"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		// Use "root" as default SSH username if not provided, matching ansible inventory
		sshUsername := os.Getenv("PROXMOX_VE_SSH_USERNAME")
		if sshUsername == "" {
			sshUsername = "root"
		}

		// Create a Proxmox provider with SSH agent support
		// This matches the SSH method used by Ansible
		pveProvider, err := proxmoxve.NewProvider(ctx, "proxmox-provider", &proxmoxve.ProviderArgs{
			Endpoint: pulumi.String(os.Getenv("PROXMOX_VE_ENDPOINT")),
			ApiToken: pulumi.String(os.Getenv("PROXMOX_VE_API_TOKEN")),
			Insecure: pulumi.Bool(true),
			Ssh: &proxmoxve.ProviderSshArgs{
				Agent:    pulumi.Bool(true),
				Username: pulumi.String(sshUsername),
			},
		})
		if err != nil {
			return err
		}

		ctx.Export("message", pulumi.String("Pulumi setup initialized with Go."))

		// Create TrueNAS VM
		if err := createTrueNASVM(ctx, pveProvider); err != nil {
			return err
		}

		// Create Talos Kubernetes Cluster
		if err := createTalosCluster(ctx, pveProvider); err != nil {
			return err
		}

		return nil
	})
}
