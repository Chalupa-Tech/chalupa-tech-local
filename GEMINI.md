# Gemini Agent Instructions

This repository is managed with the help of the Gemini CLI agent. Gemini should strictly follow these rules when interacting with this repository:

1. **Pull Requests Only**: All changes to infrastructure or configuration MUST be proposed via Pull Requests. Do not merge directly to `main`.
2. **Use GitHub CLI (gh)**: For all GitHub-related operations (creating PRs, checking status, adding comments), strictly use the `gh` command-line tool. DO NOT use the GitHub MCP server tools.
3. **Review CI Outputs**: Rely on GitHub Actions CI outputs for validation. Read and review the results of Pulumi previews and Ansible check/diff runs in PR comments.
3. **No Local Execution**:
   - NEVER run `pulumi up`, `pulumi destroy`, or any mutating Pulumi command locally against the live environment.
   - NEVER run `ansible-playbook` against the live Proxmox host locally.
   - You may run `pulumi preview` locally *if* properly configured, but CI is the source of truth.
4. **Local Linting First**: Always run linters (e.g., `ansible-lint`, `npm run lint` for Pulumi if configured) locally before creating a PR to ensure clean code.
5. **Safety First (No Destructive Ops)**: Base all change processes on being as safe as possible. NEVER attempt to delete data or perform actions that could result in data loss on the TrueNAS VM or other critical systems.
