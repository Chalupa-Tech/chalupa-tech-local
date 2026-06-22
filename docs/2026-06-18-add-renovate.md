# Add Renovate (self-hosted on the cluster)

## Summary

Stand up [Renovate](https://docs.renovatebot.com) to automate dependency updates
for `chalupa-tech-local`. It runs **self-hosted as a Kubernetes CronJob on the
Talos cluster**, deployed through ArgoCD like every other app (wrapper chart at
`gitops/apps/infra-tools/renovate/`, wrapping the official `renovate` Helm chart).
Update policy lives in the repo-root `renovate.json`.

Scope is this repo only for now (no org-wide shared preset). Renovate opens PRs;
the existing `gitops.yml` CI (`helm dependency update` + kubeconform) validates
them, and ArgoCD auto-syncs whatever merges.

## Rationale

- ~28 Helm charts, ~12 container image tags, 2 Go modules, ~12 GitHub Actions, and
  the pinned Talos/HAOS/Proxmox-provider versions were all bumped **by hand**. No
  automation existed (the dormant `renovate.json` in `chalupa-infra` never ran).
- Self-hosted on the cluster keeps it fully open-source (no Mend cloud / third-party
  app) and matches the GitOps pattern already in use. Renovate bumps its own chart
  version, so it keeps itself current.
- This repo's dependencies are all public (Helm repos, ghcr.io/lscr.io, Go proxy),
  so Renovate needs only outbound internet + a GitHub token — no Tailscale/cluster
  access required.

## What changed

### `renovate.json` (new, repo root)
Managers: `gomod`, `github-actions`, `helmv3`, and `custom.regex`. Custom regex
managers cover what no standard manager catches:
- bjw-s `app-template` image `repository`/`tag` pairs (tolerating comment lines
  between them, e.g. plex-exporter) and the CNPG single-line `imageName: repo:tag`.
- Cross-file version pins kept in sync: **Talos** (Go const + Ansible var), **HAOS**
  (Pulumi config + Ansible var), **Proxmox provider** (`pulumi.Version(...)` in two
  Go files), and **`go-version`** in the workflows.

Balanced auto-merge policy (auto-merge == auto-deploy, since ArgoCD syncs on merge):
- **Auto-merge** (after CI passes): media/observability leaf images + charts
  (minor/patch/digest), GitHub Actions (minor/patch), Go modules (minor/patch).
- **PR + Dependency Dashboard approval** (manual merge): all majors, platform-critical
  charts (cert-manager, argocd, traefik, metallb, external-secrets, CNPG, openbao,
  external-dns, metrics-server, local-path-provisioner), Pulumi SDKs, and the infra
  versions that drive reprovisioning (Talos, HAOS, Proxmox provider, Go toolchain).

linuxserver.io `…-ls<build>` tags use a custom `regex:` versioning scheme.
`ghcr.io/frebib/nzbget-exporter` only publishes `:latest`, so it is tracked by
digest (`pinDigests`).

### `gitops/apps/infra-tools/renovate/` (new wrapper app)
- `Chart.yaml` — depends on `renovate` chart `46.198.4` (appVersion 43.231.4).
- `values.yaml` — CronJob `0 6 * * *` America/Denver; `config.js` (token read from a
  shared volume); init container `mint-github-token`; shared `auth` emptyDir;
  `fsGroup: 1000` so the non-root init container can write the token and Renovate
  can read it. No `templates/namespace.yaml` — Renovate runs baseline-PSA (no special
  privileges), and the `infra-tools` ApplicationSet auto-creates the `renovate` ns.
- `templates/externalsecret.yaml` — syncs the GitHub App credentials from OpenBao
  (`secret/data/renovate/github-app`, properties `appId`/`installationId`/`privateKey`)
  into Secret `renovate-github-app` via the `openbao` ClusterSecretStore.
- `templates/mint-token-configmap.yaml` — Node script (built-in crypto + fetch, no
  deps) that mints a ~1h GitHub App installation token. Renovate self-hosted can't
  mint App tokens itself; this init-container pattern is the documented approach.

### Image tags pinned off `latest` (so Renovate can track them)
- `gitops/apps/media/radarr` → `6.2.1.10461-ls306`
- `gitops/apps/media/sonarr` → `4.0.17.2952-ls314`
- `gitops/apps/media/seerr`  → `v3.3.0`

## Manual one-time setup (NOT done by this PR)

1. **Create the GitHub App** `chalupa-renovate` (org Chalupa-Tech). Repository
   permissions: Contents RW, Pull requests RW, Issues RW (Dependency Dashboard),
   Workflows RW (to update `.github/workflows`), Checks RO, Metadata RO. Install it
   on `chalupa-tech-local` only. Note the **App ID**, generate a **private key**, and
   read the **Installation ID** (from the install URL or `GET /app/installations`).
2. **Store credentials in OpenBao** at `secret/renovate/github-app` with keys
   `appId`, `installationId`, `privateKey` (the full PEM). All three must go in a
   single `put` (KV v2 replaces the secret each call), e.g. with the helper:

   ```bash
   export KUBECONFIG=~/.kube/chalupa-cluster.yaml
   export OPENBAO_TOKEN=<openbao-write-token>
   ./scripts/openbao/kv-put.sh renovate/github-app \
     appId=<APP_ID> \
     installationId=<INSTALLATION_ID> \
     privateKey=@chalupa-renovate.<...>.private-key.pem
   ```

   App ID is on the app's settings page; Installation ID is the number in the
   install URL (`.../installations/<INSTALLATION_ID>`). Verify with
   `bao kv get -mount=secret renovate/github-app` inside an OpenBao pod.
3. **Branch protection** on `main`: require the gitops/pulumi/ansible PR status checks
   and enable "Allow auto-merge", so Balanced auto-merge only fires once CI is green.

## Verification

- `npx --yes --package renovate@43.231.4 renovate-config-validator renovate.json`
- `helm dependency update gitops/apps/infra-tools/renovate && helm template gitops/apps/infra-tools/renovate | kubeconform -strict` (mirrors `gitops.yml`)
- Dry run with no writes: a one-off Job from the CronJob with `RENOVATE_DRY_RUN=full`
  and `LOG_LEVEL=debug`; confirm it discovers the managers and lists expected updates.
- Live: `kubectl create job --from=cronjob/renovate renovate-manual -n renovate`,
  watch logs; confirm the **Dependency Dashboard** issue appears and PRs open.

## PR

<!-- fill in once opened -->
