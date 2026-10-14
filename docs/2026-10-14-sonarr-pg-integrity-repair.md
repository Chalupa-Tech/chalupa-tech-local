# Sonarr Postgres integrity repair (sonarr_main on arrs-pg)

**Date:** 2026-10-14
**Related PRs:** #386 (scraparr seerr-connector migration, merged the same
session); the repair itself was live DB surgery, not a code change.
**Backup:** `pg_dump -Fc` taken immediately before surgery →
`~/sonarr_main-pre-repair-20261014.dump` on the operator Mac.

## Symptom

Sonarr's `GET /api/v3/rootfolder` returned HTTP 500
(`ArgumentException: An item with the same key has already been added.
Key: 64` in `SeriesRepository.AllSeriesPaths()`), which surfaced as
scraparr's recurring `[sonarr] No rootfolder data found` warning and
`scrape failed: 'NoneType' object is not iterable` error.

## Root cause

`sonarr_main` carried scars of a migration-tool import (contrary to the
fresh-start policy — see `docs/` pgloader notes): **no primary keys on
any table**, scrambled sequence↔table `pg_depend` links, two sequences
still named for upstream-renamed tables (`Blacklist_Id_seq` →
`Blocklist`, `Restrictions_Id_seq` → `ReleaseProfiles`), and — the
active defect — **every `*_Id_seq` far behind its table's `MAX(Id)`**
(e.g. `Series_Id_seq` at 64 vs max 400; `Episodes_Id_seq` at 2,105 vs
26,117). With no PK to reject them, every insert minted a colliding id.

Damage at diagnosis time:

| Table | Colliding ids | Nature |
|---|---|---|
| Series | 1 | byte-identical pair (id 64) |
| Config | 1 | two different keys sharing id 2 |
| CustomFilters | 1 | identical pair |
| Blocklist | 2,237 | different rows sharing ids |
| EpisodeFiles | 3,794 | different real files sharing ids (19 same-series) |
| History | 25,738 | log rows sharing ids |
| DownloadHistory | 24,910 | log rows sharing ids |

`radarr_main` was checked and is healthy (sequence aligned, PK present,
zero dups) — only sonarr was imported with tooling.

## Repair (executed 2026-10-14, Sonarr briefly scaled to 0)

One transaction (`ON_ERROR_STOP`, single txn), after the backup:

1. `setval` every `*_Id_seq` to its table's `MAX(Id)+1`, name-matched
   with the two rename aliases — stops new collisions (root cause).
2. `Series`: deleted one of the two identical id-64 rows (ctid+content
   guarded).
3. `CustomFilters`: deleted one of the identical pair.
4. `Config`: re-id'd the `applicationurl` row (Sonarr reads Config by
   Key; the Id is cosmetic).
5. `History` / `DownloadHistory` / `Blocklist`: kept the first row of
   each colliding set, re-id'd the extras from the fixed sequences
   (nothing references these tables' ids).
6. `EpisodeFiles`: colliding pairs are *different* files and 19 pairs
   were same-series (not auto-disambiguable), so all colliding rows
   (7,588) were deleted and the 7,616 affected `Episodes.EpisodeFileId`
   links zeroed; a `RescanSeries` rebuilt the file records from disk
   with clean ids (16,077 files, 16,158 episodes relinked, 0 dups).
   Cost: manual per-file quality overrides on those episodes were lost;
   quality re-detected from filenames.
7. **Prevention:** added `PRIMARY KEY ("Id")` to `Series`, `Episodes`,
   `EpisodeFiles`, `History`, `DownloadHistory`, `Blocklist`, `Config`,
   `CustomFilters` — a recurrence now fails loudly instead of
   corrupting.

## Verification

- Full-table duplicate sweep: zero across all tables.
- `GET /api/v3/rootfolder` → 200.
- scraparr logs: `[sonarr] metrics updated` every cycle; the rootfolder
  warning and NoneType error are gone.

## Lessons

- A Servarr app that "mostly works" can hide a corrupt PG import for
  months; the breakage only surfaced via an endpoint that builds a
  dictionary keyed by id.
- When auditing: compare `pg_sequence_last_value` to `MAX(Id)` per
  table and confirm PKs exist — either mismatch means tool-damaged
  schema.
- Keep the pre-repair dump until Sonarr has run clean for a while, then
  delete it.
