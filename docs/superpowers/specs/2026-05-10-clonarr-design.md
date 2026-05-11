# Clonarr — Design

**Date:** 2026-05-10
**Status:** Approved (pending implementation plan)
**Sub-project:** Follow-on to #3 (media stack)

## Context

Sub-projects #1 (ArgoCD foundation) and #2 (Secrets + TLS Ingress) delivered the GitOps platform. Sub-project #3 landed the *arrs media stack* — Sonarr, Radarr, Seerr, NzbGet, Tdarr, plus a shared CNPG Postgres cluster — under `gitops/apps/media/`, all picked up by the `media-apps` ApplicationSet, all exposed at `<name>.frame.chalupatech.com` over HTTPS, all backed by the shared `media-plexmedia` NFS PVC.

This spec adds **[Clonarr](https://github.com/ProphetSe7en/clonarr)** as a sixth media-tier application. Clonarr is a single-binary Go web UI that syncs [TRaSH Guides](https://trash-guides.info/) Custom Formats and Quality Profiles to Radarr and Sonarr instances via their v3 HTTP APIs. It is a *companion* to the arr stack: it has no media-library access, no downloader role, no Postgres dependency. Its only state is a `/config` directory with JSON files (clonarr config, profiles, sync history, bcrypt-hashed admin credentials) plus a cloned copy of the TRaSH Guides git repository.

The deploy slots into the established media-app pattern with the lightest possible footprint: one wrapper chart, no new infra resources, no new secrets, no ApplicationSet changes.

## Goals

- Run Clonarr in the existing `media` namespace on the Talos cluster.
- Use the bjw-s `app-template` 4.x chart, matching the rest of the media tier.
- Persist `/config` on the existing `media-plexmedia` NFS PVC under a new `Configs/clonarr/` subPath, so node loss never loses Clonarr state.
- Expose at `clonarr.frame.chalupatech.com` over HTTPS using Traefik's wildcard cert and the existing external-dns + Unifi DNS override pattern.
- Reach Sonarr and Radarr via in-cluster Service DNS (`http://sonarr.media.svc:8989`, `http://radarr.media.svc:7878`) — no egress needed.

## Non-goals (explicitly out of scope)

- **ServiceMonitor / Prometheus / metrics.** Observability tier covers this separately; no metrics from Clonarr in this PR.
- **OpenBao-backed credential pre-seeding.** Clonarr does not accept Radarr/Sonarr URLs or API keys via environment variables — its config lives in `/config/clonarr.json` and is written via the web UI. Pre-seeding would require an init container that merges secrets into that JSON. Not worth the complexity for a single-user homelab tool. **The operator pastes Radarr + Sonarr API keys via the Settings UI post-deploy.**
- **OIDC / SSO.** Clonarr has its own forms-based login; first-run setup creates a bcrypt-hashed admin account. Sufficient for homelab.
- **Renovate / image automation.** Manual chart and image bumps for now, same as the rest of the stack.
- **A dedicated namespace or PSA elevation.** Clonarr is non-root, no privileged capabilities, no hostNetwork — baseline PSA is sufficient. Reuses the `media` namespace and the existing PSA posture.
- **Auto-sync configuration in code.** Clonarr's auto-sync schedule, Discord/Gotify hooks, and per-profile sync rules are operator settings configured via the web UI; not GitOps-managed.

## Architecture

### Tiering

No new tier. The wrapper chart lands at `gitops/apps/media/clonarr/` and the existing `media-apps` ApplicationSet (`gitops/bootstrap/applicationsets/media.yaml`) picks it up via its `directories.path: gitops/apps/media/*` generator. Sync policy, retry, and `ignoreDifferences` block are inherited unchanged. Destination namespace `media` is already pinned in the ApplicationSet.

### Wrapper-chart shape

The chart mirrors the existing seerr wrapper (`gitops/apps/media/seerr/`) — the closest sibling, since Seerr is also single-controller, single-mount, no NFS media access, no shared PV/PVC ownership.

```
gitops/apps/media/clonarr/
├── Chart.yaml          # depends on app-template 4.4.0 (matches sonarr-wrapper, seerr-wrapper)
├── Chart.lock          # committed (matches convention)
├── .helmignore
├── values.yaml         # the controller, service, persistence definition
└── templates/
    └── ingressroute.yaml   # web + websecure pair, both with external-dns target annotation
```

No `Namespace` template (the ApplicationSet's `CreateNamespace=true` + Talos baseline PSA cover it). No ExternalSecret (no secrets needed). No PV/PVC (reuses `media-plexmedia` owned by the NzbGet wrapper). No Middleware (reuses `redirect-to-https` owned by the NzbGet wrapper).

### values.yaml details

```yaml
app-template:
  defaultPodOptions:
    securityContext:
      runAsNonRoot: false
      fsGroup: 568
      fsGroupChangePolicy: OnRootMismatch

  controllers:
    clonarr:
      type: deployment
      replicas: 1
      strategy: Recreate
      containers:
        main:
          image:
            repository: ghcr.io/prophetse7en/clonarr
            tag: 2.5.6           # pin to current latest at implementation time
          env:
            TZ: America/Los_Angeles
            PUID: "1000"
            PGID: "1000"
            PORT: "6060"
          probes:
            liveness:
              enabled: true
              custom: true
              spec:
                httpGet:
                  path: /api/health
                  port: 6060
                initialDelaySeconds: 30
                periodSeconds: 30
                timeoutSeconds: 10
                failureThreshold: 5
            readiness:
              enabled: true
              custom: true
              spec:
                httpGet:
                  path: /api/health
                  port: 6060
                initialDelaySeconds: 5
                periodSeconds: 10
                timeoutSeconds: 5
                failureThreshold: 5
            startup:
              enabled: true
              custom: true
              spec:
                httpGet:
                  path: /api/health
                  port: 6060
                initialDelaySeconds: 10
                periodSeconds: 10
                timeoutSeconds: 5
                failureThreshold: 30
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              memory: 256Mi

  service:
    clonarr:
      controller: clonarr
      ports:
        http:
          port: 6060

  persistence:
    config:
      enabled: true
      type: persistentVolumeClaim
      existingClaim: media-plexmedia
      globalMounts:
        - path: /config
          subPath: Configs/clonarr
```

Notes on field choices:

- **`runAsNonRoot: false` + `fsGroup: 568`** matches every other media wrapper. The clonarr image uses `su-exec` to drop to PUID:PGID after start, so the container does need to start as root.
- **`PUID/PGID: "1000"`** matches the rest of the media tier. Functionally irrelevant for NFS writes because TrueNAS Maproot=root squashes the in-pod UID; kept for behavioral consistency with neighbors.
- **`/api/health` probe path** is verified from Clonarr's `Dockerfile` HEALTHCHECK directive (`wget -qO- "http://localhost:${PORT}${URL_BASE:-}/api/health"`). Returns `200` when the web UI is up. Does not require authentication.
- **Resource bounds** are conservatively small: Clonarr's heaviest operation is cloning the TRaSH Guides repo (a few MB git repo + JSON parsing) and serving a small Alpine.js SPA. 256Mi limit gives plenty of headroom; if it OOMs in practice the bump is one-line.
- **`PORT` env is set explicitly to `6060`** even though it's the default, so the probe + Service + IngressRoute backend port all read off the same explicit value.
- **No `URL_BASE` env.** We're using subdomain hosting (`clonarr.frame.chalupatech.com`), not subpath. Clonarr's default (empty `URL_BASE`) is correct.
- **No `TRUSTED_PROXIES` env.** Clonarr's default trust list covers all RFC1918 ranges, which includes the cluster pod CIDR Traefik egresses from. `X-Forwarded-Proto` from Traefik is honored without explicit configuration. Acceptable for the homelab threat model; the spec's Risks section documents the implication.

### Storage

Reuses the shared `media-plexmedia` PVC (RWX, NFS, served by TrueNAS at `192.168.1.40:/mnt/PlexMedia/frame`). Owned by the NzbGet wrapper.

One new subPath inside that share: `Configs/clonarr/`. Holds:

- `/config/clonarr.json` — Clonarr's main config (instance URLs, API keys, sync rules, notification tokens). Mode 0600 inside the container.
- `/config/auth.json` — bcrypt-hashed admin credentials.
- `/config/sessions.json` — active session cookies.
- `/config/profiles/` — synced quality profile JSON files.
- `/config/data/trash-guides/` — the cloned TRaSH Guides git repo (auto-updated every 24h).

**Pre-merge operator step:** create `/mnt/PlexMedia/frame/Configs/clonarr/` on TrueNAS (empty directory, Maproot=root means owner doesn't matter). bjw-s `subPath` mounts require the path to exist before pod start. Same pattern as `Configs/sonarr/`, `Configs/seerr/`, etc.

### Networking

Service `clonarr.media.svc` on port 6060, `ClusterIP`.

IngressRoute pair, both annotated with `external-dns.alpha.kubernetes.io/target: "192.168.1.230"` (the Traefik MetalLB IP). Without this annotation external-dns silently skips the record — encoded in project memory and verified across the rest of the media tier.

`clonarr-http`:
- entryPoint `web`
- match: `Host(\`clonarr.frame.chalupatech.com\`)`
- middleware: `name: redirect-to-https, namespace: media` (the shared one owned by NzbGet)
- backend reference is required by IngressRoute schema but the middleware terminates the response; uses `name: clonarr, port: 6060` for that schema requirement.

`clonarr-https`:
- entryPoint `websecure`
- match: `Host(\`clonarr.frame.chalupatech.com\`)`
- `tls: {}` — uses Traefik's default TLSStore for the wildcard `*.frame.chalupatech.com` cert.
- backend: `name: clonarr, port: 6060`.

LAN resolution: the existing Unifi `*.frame.chalupatech.com → 192.168.1.230` wildcard override. external-dns creates the audit-trail TXT records in Cloudflare; no public A record (per memory: Cloudflare free tier filters RFC 1918 responses).

### Secrets and authentication

**No K8s Secrets created.** No ExternalSecret, no OpenBao path, no policy change.

On first browser visit to `https://clonarr.frame.chalupatech.com`, Clonarr's auth middleware redirects to `/setup`. The operator creates an admin account (min 10 chars; 16+ skips the character-class rule). Credentials are bcrypt-hashed (cost 12) and persisted to `/config/auth.json` on the NFS share. Sessions persist to `/config/sessions.json` (30-day TTL), so admin login survives pod restarts.

**Recovery:** if the password is lost, `kubectl -n media exec deploy/clonarr -- rm /config/auth.json` then restart drops the app back to `/setup`. Documented in the verification checklist below.

**Radarr/Sonarr API keys** are configured via Settings → Instances in the Clonarr UI, post-deploy. Each arr's API key is found in Settings → General of that app's UI. Keys persist in `/config/clonarr.json`. **This is the deliberate trade-off vs. OpenBao seeding** — Clonarr does not accept instance config via env vars, so pre-seeding would require an init container to merge secrets into the JSON. Not worth the complexity for a single-user homelab tool.

### Reachability between Clonarr and the arrs

Clonarr talks to Radarr and Sonarr via their cluster Services. No external DNS, no Traefik traversal — pod-to-Service traffic stays inside the cluster.

| Clonarr instance config (UI) | Target |
|---|---|
| Radarr URL | `http://radarr.media.svc:7878` |
| Radarr API key | from Radarr Settings → General |
| Sonarr URL | `http://sonarr.media.svc:8989` |
| Sonarr API key | from Sonarr Settings → General |

Both arrs already serve on these Services per their existing wrappers (`gitops/apps/media/radarr/values.yaml`, `gitops/apps/media/sonarr/values.yaml`).

## Repository layout (additions only)

```
gitops/apps/media/clonarr/        NEW
├── Chart.yaml
├── Chart.lock
├── .helmignore
├── values.yaml
└── templates/
    └── ingressroute.yaml         # web + websecure pair
```

No changes to:
- `gitops/bootstrap/applicationsets/media.yaml` — ApplicationSet picks up the new directory automatically.
- Any other wrapper in `gitops/apps/media/*`.
- `gitops/apps/platform/*` or `gitops/apps/infra-tools/*`.
- Any OpenBao policy, ESO ClusterSecretStore, or Vault path.

## Sync ordering and reconciliation

The new Clonarr Application syncs in parallel with the existing five on its first reconcile. Resource dependencies are:

- Shared PVC `media-plexmedia` — already bound (owned by NzbGet, present since sub-project #3).
- Shared Middleware `redirect-to-https` — already applied (owned by NzbGet).
- TLS — Traefik default TLSStore + existing wildcard cert (no per-app cert).

There is no chicken-and-egg case on this deploy. The Application materializes, pulls the chart, renders the manifests, applies them, and the pod schedules immediately once the (already-bound) PVC mounts. End-state: Argo shows `Synced/Healthy`; pod is `1/1 Ready` within ~60s.

## Verification

End-of-step checklist (run after the PR merges):

1. `kubectl -n argocd get application clonarr` → `Synced/Healthy`.
2. `kubectl -n media get pods -l app.kubernetes.io/name=clonarr` → 1/1 Ready.
3. `kubectl -n media exec deploy/clonarr -- ls /config` → directory readable; on first start contains nothing or only what the entrypoint scaffolded.
4. `kubectl -n media exec deploy/clonarr -- wget -qO- http://localhost:6060/api/health` → returns a 200 health JSON.
5. `kubectl get ingressroute -n media | grep clonarr` → two routes (`clonarr-http`, `clonarr-https`).
6. From a LAN client:
   - `dig +short clonarr.frame.chalupatech.com` → `192.168.1.230`.
   - `curl -I https://clonarr.frame.chalupatech.com/api/health` → `HTTP/2 200`, no `-k` needed.
7. Browser to `https://clonarr.frame.chalupatech.com` → green padlock, redirected to `/setup`.
8. Create admin account → log in → land in main UI.
9. Settings → Instances → add Sonarr (`http://sonarr.media.svc:8989`, API key from Sonarr) → "Test" returns success. Repeat for Radarr (`http://radarr.media.svc:7878`).
10. Click **Pull** in the header → TRaSH guide repo clones. Verify: `kubectl -n media exec deploy/clonarr -- ls /config/data/trash-guides/` → non-empty.
11. Browse the Sonarr or Radarr tab → quality profiles render → smoke-sync a single profile in **Dry Run** mode → preview shows the diff against the live arr instance.
12. The `Verify GitOps reconciliation` step in `.github/workflows/deploy.yml` returns clean after merge.

## Risks and mitigations

- **API keys in plaintext on NFS.** Once the operator pastes Sonarr/Radarr API keys via Settings, they live in `/config/clonarr.json` (mode 0600 inside the container) on the NFS share. Anyone with NFS read access to `/mnt/PlexMedia/frame/Configs/clonarr/` can read those keys. Acceptable in the homelab (the NFS share is already trusted by Talos nodes + Plex LXC; no untrusted hosts have access). If we ever want to tighten this, the migration path is an init container that pulls a K8s Secret (synced from OpenBao) and merges into the JSON at pod start — same pattern other tools use.
- **Image churn.** Clonarr is an actively developed project (current 2.5.6, frequent releases). Pinning to a specific tag avoids surprise breakage; manual bumps via PR keep the trail in git. Same posture as the rest of the stack.
- **Admin-credential recovery is destructive.** If the admin password is lost, the only recovery is `kubectl exec ... rm /config/auth.json` and re-running setup. No email reset (intentional per Clonarr's design). Mitigation: the recovery command is in the verification section above and the post-deploy runbook. Sessions persist for 30 days so day-to-day use isn't affected.
- **NFS soft mount.** The shared PV mounts with `soft,timeo=150,retrans=5` (inherited from the NzbGet wrapper). For Clonarr's tiny JSON writes this is a non-issue; for the TRaSH guide git clone (`/config/data/trash-guides/`) a mid-clone NFS hiccup would corrupt the working tree, but Clonarr's auto-update logic re-clones on next pull. No mitigation needed.
- **Cluster reboot + admin lockout.** Unlike NzbGet, Clonarr does not depend on an ExternalSecret, so OpenBao seal does **not** block its pod from starting. Login still requires the credentials in `/config/auth.json` (which is on NFS and survives reboot), so admin access works the moment the pod is `Ready` after a reboot.
- **`TRUSTED_PROXIES` is left at default (all RFC1918).** A malicious workload that lands in any pod on the cluster bridge could spoof `X-Forwarded-For` and bypass Clonarr's brute-force lockout. Mitigation: the cluster currently runs only first-party workloads, so this is a defense-in-depth gap, not an exposure. If we later run untrusted workloads, set `TRUSTED_PROXIES` to Traefik's specific Service ClusterIP via values.

## Open questions

None blocking. Resolved at implementation time:

- Exact pinned image tag (current `2.5.6`; pull whatever is current at PR time).
- Final probe tuning (initial values are conservative; tune if liveness/readiness flaps during first 24h).

## Implementation PR plan (preview — full plan written by writing-plans)

**One PR:** the wrapper chart at `gitops/apps/media/clonarr/`. Pre-merge step: create `Configs/clonarr/` on TrueNAS. Post-merge: verification checklist above. Cross-app wiring (pasting API keys, configuring sync rules) is operator runbook — explicitly not part of the PR.

## References

- Clonarr repo: https://github.com/ProphetSe7en/clonarr
- Clonarr README (rendered at the linked commit): documents env vars, ports, volumes, auth, and `/api/health` healthcheck.
- bjw-s `app-template` chart: https://github.com/bjw-s-labs/helm-charts/tree/main/charts/other/app-template
- Sub-project #3 spec: `docs/superpowers/specs/2026-05-07-media-stack-design.md` — the canonical media-tier pattern Clonarr inherits from.
- Closest existing wrapper for shape reference: `gitops/apps/media/seerr/` (single-controller, single-mount, no NFS media access).
- Project conventions: `CLAUDE.md`.
- Memory: `project_homelab_roadmap.md`, `project_talos_psa_constraint.md`, `project_argocd_sync_config.md`, `project_external_dns_target_annotation.md`, `project_cloudflare_rfc1918_filter.md`.
