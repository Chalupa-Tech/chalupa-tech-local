# Handoff: Sportarr — deploy to media stack, wire into Prowlarr + scraparr

**For:** a fresh agent with no context of the prior sessions.
**Your first move:** read this handoff fully, then use
`superpowers:writing-plans` to produce
`docs/superpowers/plans/YYYY-MM-DD-sportarr.md`, then execute it with
`superpowers:subagent-driven-development` in a fresh worktree branched
from **origin/main**. Suggested branch: `feat/sportarr`.

Design decisions below were approved by Tayven on 2026-10-08. Facts
marked **(verified)** were checked live that day; re-verify anything
load-bearing that could have drifted.

## What this builds

[Sportarr](https://github.com/Sportarr/Sportarr) is a sports PVR —
Sonarr/Radarr for sports events. Deploy it as a new media-stack app,
give it a new `Sports/` library on the TrueNAS share, connect it to
Prowlarr (indexers) and NZBGet (downloads), and wire its metrics into
scraparr.

## State of the world (verified live, 2026-10-08)

- **scraparr is healthy again.** It crash-looped for 3 weeks because
  chart 1.5.0 added a `sportarr: {}` default; PR #370 (merged
  2026-10-08) suppressed it with `sportarr: []` in
  `gitops/apps/media/scraparr/values.yaml`. This handoff *replaces*
  that `[]` with a real instance — see Part C.
- **scraparr v3.2.0 has a native `sportarr` connector**, api_version
  `v3` (verified in `src/scraparr/const.py` at tag v3.2.0). Config
  shape is identical to the sonarr/radarr stanzas already in
  values.yaml.
- **Image tag verified on Docker Hub**: `sportarr/sportarr:4.1.9.1119`
  is the current stable (what `latest` points at, pushed 2026-09-27).
  Dev builds use `-dev` suffixes — never pin those. Re-run the tag
  check before pinning (memory rule: verify image tags on the
  registry, don't infer).
- **ArgoCD auto-discovers** any new dir under `gitops/apps/media/*`
  via the `media-apps` ApplicationSet
  (`gitops/bootstrap/applicationsets/media.yaml`) — no bootstrap
  change needed. Sync policy: automated + prune + selfHeal,
  CreateNamespace, ServerSideApply, retry x5.
- **Reference app:** `gitops/apps/media/radarr/` is the canonical
  pattern — app-template 4.4.0 chart dep, lscr-style values,
  `templates/ingressroute.yaml`. Mirror it.
- **Storage:** all media apps mount the `media-plexmedia` PVC (NFS →
  TrueNAS 10.10.10.40, export rewrites all UIDs to root via
  mapall=root, so no UID alignment needed). Radarr uses subPaths
  `Configs/radarr`, `Movies`, `Downloads`.
- **arrs-pg** (CNPG cluster, `gitops/apps/media/arrs-pg/`): per-app
  managed role + `<app>-pg` ExternalSecret (OpenBao `postgres/<app>`
  with username/password/main_db/log_db) + `Database` CRs
  (`readmebook-databases.yaml` is the post-initdb pattern). The
  `bootstrap.initdb.postInitApplicationSQL` block only runs on
  cluster creation — but keep it in sync anyway: the Talos cluster is
  fully destroyable/recreatable.
- **OpenBao**: one-key-per-path convention for scraparr API keys
  (`scraparr/<svc>-api-key`, single property `apikey`) — documented in
  `scripts/openbao/README.md`, written with `scripts/openbao/kv-put.sh`.
  Check `bao status` first — OpenBao seals on every reboot and sealed
  OpenBao breaks all ExternalSecrets.
- **Prowlarr** is deployed in-cluster (`prowlarr.media.svc.cluster.local:9696`).
  Prowlarr has **no native Sportarr app type yet** (upstream PR in
  review) — the supported path is adding Sportarr as a **Sonarr**
  application type ([Sportarr wiki](https://wiki.sportarr.net/integrations/prowlarr/)).

## Part A — the Sportarr app (`gitops/apps/media/sportarr/`)

Mirror radarr exactly, adjusted:

- `Chart.yaml`: app-template `4.4.0` dependency
  (`https://bjw-s-labs.github.io/helm-charts`), matching radarr's.
- Image: `sportarr/sportarr:4.1.9.1119` (Docker Hub, not lscr).
- Port **1867**; service named `sportarr`.
- Env: `TZ: America/Los_Angeles`, `PUID: "1000"`, `PGID: "1000"`.
- Probes: radarr uses `/ping`. Sportarr's Sonarr lineage suggests
  `/ping` exists, but **verify before pinning the probe path**
  (`curl http://<pod>:1867/ping` on a test deploy, or check
  Sportarr's repo). If absent, probe `/` or the API health endpoint.
- Persistence (all on `media-plexmedia` PVC):
  - `/config` → subPath `Configs/sportarr`
  - `/sports` → subPath `Sports` ← **new library folder** (kubelet
    auto-creates subPath dirs; mapall=root handles ownership)
  - `/downloads` → subPath `Downloads` (same mount as NZBGet so
    imports hardlink instead of copying)
- `templates/ingressroute.yaml`: copy radarr's http+https pair,
  hostname `sportarr.frame.chalupatech.com`, port 1867. **Keep the
  `external-dns.alpha.kubernetes.io/target: "192.168.1.230"`
  annotation on both** — without it external-dns silently skips the
  record (memory rule).

## Part B — database

**First verify whether Sportarr supports Postgres.** Its 4.x
versioning suggests Sonarr-v4 lineage (`Sportarr__Postgres__Host`
etc.), but this was NOT confirmed — check the wiki
(wiki.sportarr.net) or the repo's config code before deciding.

- **If Postgres is supported** (preferred — matches every other arr):
  follow the radarr pattern end-to-end:
  1. `arrs-pg/templates/cluster.yaml`: add `sportarr` to
     `managed.roles` (passwordSecret `sportarr-pg`, connectionLimit 25)
     AND append the role/DB/grant lines to
     `bootstrap.initdb.postInitApplicationSQL` (rebuild parity).
  2. New `arrs-pg/templates/sportarr-databases.yaml`: `Database` CRs
     for `sportarr_main` + `sportarr_log` (copy
     `readmebook-databases.yaml`).
  3. New `arrs-pg/templates/sportarr-externalsecret.yaml` → secret
     `sportarr-pg` from OpenBao `postgres/sportarr` (copy radarr's).
  4. Seed OpenBao: `postgres/sportarr` with
     username/password/main_db(`sportarr_main`)/log_db(`sportarr_log`).
     Check whether `secret/postgres/*` is covered by the
     external-secrets policy; if not, extend the relevant `.hcl` in
     `scripts/openbao/policies/` + `apply-policy.sh` (pattern: the
     radarr secret already syncs, so the policy almost certainly
     covers it — verify, don't assume).
  5. Env block in sportarr values: `Sportarr__Postgres__*` mirroring
     radarr's `Radarr__Postgres__*` (verify exact prefix from
     Sportarr docs).
- **If SQLite only:** skip all of the above; the DB lives in
  `/config` (NFS). Add a code comment + docs note flagging the
  SQLite-on-NFS locking risk and that PG should be revisited when
  upstream supports it.

## Part C — scraparr wiring

1. In `gitops/apps/media/scraparr/values.yaml`: delete `sportarr: []`
   from the suppression list (keep the list's comment block — update
   its "sportarr" example if it reads oddly once sportarr is real)
   and add a configured stanza next to sonarr/radarr:
   ```yaml
   sportarr:
     - url: http://sportarr.media.svc.cluster.local:1867
       alias: sportarr
       api_version: v3
       interval: 30
       detailed: true
       api_key:
         type: ref
         name: SCRAPARR_SPORTARR_API_KEY
         valueFrom:
           secretKeyRef:
             name: scraparr-apikeys
             key: sportarr
   ```
2. In `templates/scraparr-apikeys-externalsecret.yaml`: add the
   `sportarr` data entry → remoteRef `scraparr/sportarr-api-key`,
   property `apikey` (one-key-per-path convention).
3. **Ordering gotcha:** the ExternalSecret has all keys mandatory. If
   the scraparr change merges before the OpenBao key exists, the
   secret fails to sync and scraparr's deploy wedges. Either seed a
   placeholder `apikey` value in OpenBao *before* merging, or ship
   the scraparr stanza in a follow-up PR after Sportarr is up and its
   real key is seeded (simplest: two PRs — app first, scraparr after).
4. Check whether the scraparr chart's `wait-for-*` init-container
   regex now includes sportarr (render with `helm template`); if yes,
   expect a `wait-for-sportarr` init container — harmless, but it
   means scraparr won't start while Sportarr is down.
5. Optional cleanup while in the file: scraparr 3.2.0 added a native
   `seerr` connector — the overseerr-key workaround from PR #213 can
   be migrated to a `seerr:` stanza. Separate commit if done; not
   required.

## Part D — alerts

Check `gitops/apps/observability/vmalert/templates/rules/arrs.yaml`:
if the rules enumerate per-service scraparr metrics, add sportarr
rows. The generic TargetDown rule in `meta.yaml` covers the scrape
job automatically — no new absent-guard needed since sportarr rides
scraparr's existing job.

## Manual steps (after merge, in order)

1. `bao status` — unseal first if sealed (`scripts/openbao/unseal.sh`).
2. Wait for ArgoCD to sync the `sportarr` app; pod Running at
   `kubectl -n media get pods`.
3. Sportarr UI (https://sportarr.frame.chalupatech.com — LAN DNS via
   the existing Unifi `*.frame` wildcard): initial setup, set
   authentication, add root folder `/sports`.
4. Copy the API key from Sportarr → Settings > General, then:
   `scripts/openbao/kv-put.sh scraparr/sportarr-api-key apikey=<key>`
   (kv-put replaces the whole record at a path — fine here, one key
   per path; NEVER use it on multi-key paths).
5. **Prowlarr** (UI: Settings > Apps > Add > **Sonarr** — native
   Sportarr type not shipped yet):
   - Name: `Sportarr`
   - Sync Level: Full Sync
   - Prowlarr Server: `http://prowlarr.media.svc.cluster.local:9696`
   - Sportarr Server: `http://sportarr.media.svc.cluster.local:1867`
   - API key: from step 4
   - Categories: TV (5000) incl. TV/Sport (5060)
   - Test → Save; confirm indexers appear in Sportarr →
     Settings > Indexers.
   - Revisit when Prowlarr ships the native Sportarr app type.
6. Sportarr → Settings > Download Clients: add NZBGet (mirror the
   sonarr/radarr client config; category e.g. `sports`, paths under
   `/downloads`).
7. If the scraparr change shipped as a follow-up PR, merge it now;
   otherwise force-refresh the ExternalSecret (annotate) and restart
   scraparr; confirm no config-validation errors in its log.
8. Plex (LXC 192.168.1.224): add a `Sports` library pointing at the
   new Sports folder on the media share. (Plex mounts the share via
   NFS fstab — path visible as soon as the folder has content.)
9. Document the change in `docs/` with rationale + PR links
   (critical rule).

## Gotchas carried forward

- All changes via PRs; CI applies them. No local `pulumi up` /
  `ansible-playbook` without `--check`.
- PSA: media namespace is baseline — Sportarr needs nothing
  privileged, no namespace label changes.
- Renovate will start bumping the sportarr image — plain semver tag,
  no custom regex needed. After any **scraparr chart** bump, diff
  `helm show values` service keys against the `[]` suppression list
  (that's what bit us for 3 weeks — see PR #370).
- vm-operator CRs use `interval`, not `scrapeInterval`, if any
  VMServiceScrape gets touched.
- ArgoCD selfHeal does NOT retry failed initial syncs — the appset
  already has retry config, but if the app wedges on first sync,
  check for the ExternalSecret-ordering issue in Part C.3.

## Verification checklist (before claiming done)

- [ ] `sportarr` pod Running + Ready in `media`, survives a restart
      with config intact (PVC-backed).
- [ ] `https://sportarr.frame.chalupatech.com` loads from LAN.
- [ ] Prowlarr test passes; indexers synced into Sportarr.
- [ ] A test grab reaches NZBGet and imports into `/sports`
      (hardlink, not copy — check link count).
- [ ] scraparr pod Running, 0 restarts, log free of
      "Invalid config"; `sportarr_*` series present on its /metrics
      (port-forward 7100, basic auth scraparr/scraparr-internal).
- [ ] VictoriaMetrics shows the new series; arrs.yaml rules (if
      extended) load without vmalert errors.
- [ ] ArgoCD apps all Synced/Healthy — including arrs-pg if Part B
      touched it (CNPG Cluster changes can show benign drift; see
      appset ignoreDifferences).
