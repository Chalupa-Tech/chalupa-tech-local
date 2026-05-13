package main

import (
	"os"

	"github.com/muhlba91/pulumi-proxmoxve/sdk/v7/go/proxmoxve"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		// Use "root" as default SSH username if not provided, matching ansible inventory
		sshUsername := os.Getenv("PROXMOX_VE_SSH_USERNAME")
		if sshUsername == "" {
			sshUsername = "root"
		}

		// Create a Proxmox provider with SSH agent support.
		// This matches the SSH method used by Ansible.
		//
		// pulumi.Version is REQUIRED: muhlba91/pulumi-proxmoxve/sdk/v7
		// ships with internal.SdkVersion as the zero value, so the
		// SDK's PkgResourceDefaultOpts never appends a version to
		// resource options. Without an explicit pin, Pulumi resolves
		// the latest plugin in the registry (currently v8.x), which
		// has different resource type tokens than v7 and breaks every
		// existing resource in state ("Resource type ... not found").
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

		ctx.Export("message", pulumi.String("Pulumi setup initialized with Go."))

		// Create TrueNAS VM
		if err := createTrueNASVM(ctx, pveProvider); err != nil {
			return err
		}

		// Create Home Assistant OS VM (sub-project #6)
		if err := createHomeAssistantVM(ctx, pveProvider); err != nil {
			return err
		}

		// Plex LXC container (VMID 200) is managed by Ansible, not Pulumi.
		// Proxmox restricts LXC device passthrough and feature flags to
		// root@pam, which API tokens cannot provide. Ansible runs as root
		// on the host via SSH, so it has no such restrictions.
		ctx.Export("plex-ip", pulumi.String("192.168.1.224"))

		return nil
	})
}
