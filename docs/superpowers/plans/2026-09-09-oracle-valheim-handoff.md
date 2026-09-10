# Handoff: Execute the Oracle Cloud Valheim Server Plan

**For a fresh Claude session.** Brainstorming, spec, and planning are done and
approved by the user. Your job is execution only.

## First actions (in order)

1. Switch into the existing worktree — do NOT create a new one and do NOT work
   on any other checkout:
   `EnterWorktree` with path
   `/Users/tbigelow/Documents/code/chalupa-tech-local/.claude/worktrees/oracle-valheim`
   (branch `worktree-oracle-valheim`, already 2 commits ahead of `origin/main`).
2. Invoke the **superpowers:subagent-driven-development** skill and follow it
   exactly: fresh subagent per task, two-stage review between tasks.
3. Execute `docs/superpowers/plans/2026-09-09-oracle-valheim.md` task by task
   (Tasks 1–8). Each task carries complete file contents, test commands with
   expected output, and a commit step. Read the plan's **Global Constraints**
   before dispatching Task 1 — every subagent prompt must include the
   constraints relevant to its task.

## Documents

- Plan (execute this): `docs/superpowers/plans/2026-09-09-oracle-valheim.md`
- Spec (context/arbiter): `docs/superpowers/specs/2026-09-09-oracle-valheim-design.md`

## State at handoff

- Worktree branch `worktree-oracle-valheim` has two commits (spec `29017534`,
  plan + spec amendment `e91802dd`). No implementation files exist yet —
  `oracle-cloud-server/` has not been created. Task 1 is the starting point.
- Baseline verified clean at worktree creation (`go build ./...` passes in
  `pulumi/` and `pulumi-talos/` — don't touch those dirs; that was just the
  repo's health check).

## Decisions already made — do not relitigate

- Terraform (OCI provider `~> 9.0`, S3-compat state backend) → cloud-init joins
  Tailscale → Ansible configures. GitHub Actions applies on merge; PR runs
  plan + lint only.
- DepotDownloader 3.4.0 (ARM-native) downloads the game — **not steamcmd**
  (32-bit x86; Box64 can't run it; this was corrected in the spec deliberately).
- Only the Valheim server binary runs emulated (Box64 via binfmt). No Docker.
- Mod/tool pins were verified against live registries on 2026-09-09 and are
  copied into the plan's Global Constraints. Do not "refresh" or upgrade them.
- Crossplay off (Steam only). UDP 2456–2457 is the only public ingress; SSH is
  Tailscale-only (custom OCI security list deliberately omits port 22).

## Hard rules (from CLAUDE.md + user)

- All changes via PR — **never push to `main`**; the branch is pushed and a PR
  opened only in Task 8.
- **No local `terraform apply` or `ansible-playbook`** (syntax-check/lint
  only). CI is the source of truth; the first real deploy also needs the
  user's one-time manual bootstrap (README checklist, Task 7) — creating OCI
  API keys, the state bucket, Tailscale keys, and 13 GitHub secrets is the
  **user's** job, not yours.
- Don't touch `pulumi/`, `pulumi-talos/`, root `ansible/`, or anything
  TrueNAS-related.

## Known environment notes

- Local tools the test steps need (install only if missing): `terraform`
  (`brew install hashicorp/tap/terraform`), `ansible-lint` (`pipx install
  ansible-lint` + `ansible-galaxy collection install ansible.posix
  community.general`), `actionlint` (`brew install actionlint`).
- `terraform validate` runs with `terraform init -backend=false` — no OCI
  credentials exist locally and none are needed pre-merge.
- When the PR is eventually created (Task 8): verify it's still open with
  `gh pr view` before pushing any follow-up commits.

## Definition of done

Tasks 1–8 complete, every task's lint/validate steps green, work committed
per task, PR open against `main` with the plan's Task 8 body. Post-merge
runtime verification (Task 8 Step 4) is a checklist for the user — hand it to
them and stop; do not attempt to deploy or verify against live infrastructure
yourself.
