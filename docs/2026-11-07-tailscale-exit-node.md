# Tailscale LXC 100 as an exit node

## Why

The Tailscale container on pve1 (`lxcprxtailscale`, LXC 100) is a subnet
router for 192.168.1.0/24. That is enough for the GitHub runners, but not
for a laptop on a remote network that *also* uses 192.168.1.0/24 (the most
common default on home and guest networks): macOS prefers the local
interface for that range and Tailscale steps aside, so pve1, the Talos VIP
(192.168.1.231) and TrueNAS are unreachable while the container itself still
answers on its tailnet address (seen 2026-11-07).

An exit node fixes this without renumbering anything: with the exit node
selected and LAN access left off, the client sends **all** traffic,
including the clashing 192.168.1.x range, through home.

## Change

- `lxc_baseline` gains `lxc_baseline_tailscale_exit_node` (default `false`).
  When true it verifies `net.ipv4.ip_forward=1` (already required for the
  subnet route) and runs `tailscale set --advertise-exit-node=true`
  (`false` withdraws it). `playbooks/vm-configure.yml` sets it for the
  Tailscale LXC only; the Plex LXC is untouched.
- `deploy.yml` Stage 0 now also triggers Stage 3 on changes under
  `ansible/roles/lxc_baseline/**` and `ansible/roles/unattended_upgrades/**`
  (previously only the playbook and the Plex roles were watched).

## One-time approval and client use

1. After Stage 3 runs, approve the exit node once in the admin console:
   https://login.tailscale.com/admin/machines → `lxcprxtailscale` → Edit
   route settings → "Use as exit node". Alternatively add an
   `autoApprovers.exitNode` entry for the owner in the tailnet policy.
2. On the Mac (CLI or menu bar → Exit node):
   `tailscale set --exit-node=lxcprxtailscale` (keep LAN access **off** so
   192.168.1.x goes to home); `tailscale set --exit-node=` to stop.

While an exit node is selected all internet traffic of the laptop goes via
the home connection. Disable it when not needed.
