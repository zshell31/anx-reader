# WebDAV warm sync optimization progress

Branch: `feature/webdav-warm-sync`

Base commit: `bf6c9196 perf(sync): persist local asset verification`

## Scope

1. Stop repeated legacy reading-activity bootstrap imports.
2. Skip clean document downloads when the WebDAV ETag is unchanged.
3. Persist translation-cache synchronization checkpoints across restarts.
4. Reuse recent persisted remote asset-presence checks during warm sync.
5. Avoid object GETs for locally known documents absent from successful
   discovery.
6. Diagnose cold local asset-verification misses without exposing file paths.
7. Preserve local asset-verification hits across local/UTC timestamp
   serialization.
8. Finish all durable bootstrap imports before connectivity can start a sync.
9. Schedule each dirty shared document only once per synchronization pass.
10. Normalize legacy reading-event wire variants before merging.

Each completed stage is committed separately together with an update to this
file. The full relevant test suite and static analysis must pass before the
branch is considered complete.

## Current stage

Stages 1-10 and cross-device release validation are complete. Historical
reading-activity aggregate-cascade cleanup is intentionally left as a separate
migration stage because it requires different retention rules for legacy-only
days and days which also contain real session events.

Observed failure mechanism: the legacy import key contains the mutable daily
aggregate duration. Canonical projection writes a larger aggregate back to the
legacy table after a new event, so the next startup creates another legacy
event for the same book and day.

Planned compatibility rule: before importing, recognize a legacy aggregate as
already represented when its value equals the sum of live canonical events.
This also recognizes documents created by older app versions without changing
their event IDs or WebDAV representation.

Implemented:

- Added a stable per-book/day bootstrap receipt (`reading-activity-v2`).
- Reused the live canonical duration calculation before creating a legacy
  event, preventing projected totals from being imported again.
- Preserved v1 event IDs and receipts for wire and downgrade compatibility.
- Added a regression test that imports 90 seconds, records another 30 seconds,
  simulates the projected 120-second legacy row, and verifies that only the two
  real events remain after repeated startups.

Stage 2 implementation:

- The existing depth-1 `PROPFIND` now requests `getetag` together with
  `resourcetype`.
- Discovery retains only syntactically valid strong ETags returned by a
  successful property status; weak, malformed, and absent ETags are ignored.
- Discovered ETags are routed to all discovered shared-document domains.
- A clean local document skips `GET`, decoding, merging, and projection only
  when its persisted convergence ETag exactly matches discovery.
- Dirty documents, changed ETags, missing local documents, and servers without
  usable ETags retain the previous synchronization path.
- ETag hints are one-shot per coordinator pass so a stale discovery result
  cannot be reused after an upload.

Stage 3 implementation:

- Bumped `translation_cache.db` from schema v1 to v2 and added a narrow
  `translation_sync_checkpoints` table with a tested v1-to-v2 migration.
- Replaced process-memory checkpoints with database-backed remote/local token
  pairs, so unchanged translation documents remain skippable after a process
  restart.
- Namespaced each checkpoint by a SHA-256 fingerprint of the sync client
  protocol and configuration. No WebDAV credentials are stored in plaintext,
  and a checkpoint from a different remote configuration cannot suppress a
  download.
- A local cache mutation still invalidates the checkpoint through the existing
  per-book local token comparison. Missing remote metadata still uses the
  previous conservative synchronization path.
- Updated the runtime-order boundary test to match the ETag-enabled multiline
  calls without weakening its ordering assertion.

Stage 4 implementation:

- Remote book assets are immutable and content-addressed, so a successful
  presence check is now reused by both startup status and the asset sync pass
  for up to 24 hours when the catalog still references the same SHA-256.
- Once the bounded receipt expires, the normal WebDAV existence check runs
  again. Its result refreshes the receipt, so remote deletion is eventually
  detected and a valid local asset can repair it.
- Missing assets are never negatively cached: another device can upload them
  and the next sync will discover them normally.
- Added `trustedRemote` to asset-phase diagnostics for device validation and a
  regression test proving that a fresh persisted presence avoids a cold
  network request without changing local digest verification.

Stage 5 implementation:

- A successful WebDAV collection discovery is now treated as authoritative
  for pull targets. Locally retained documents which were not listed no longer
  generate redundant object `GET` requests and expected 404 responses.
- Durable outbox work remains independent and still uploads local mutations,
  including documents absent from the remote listing.
- If discovery fails, pull target selection falls back to the previous union
  of local and remotely discovered IDs, preserving conservative recovery.
- Added direct regression coverage for both authoritative and fallback target
  selection. The configured WebDAV was also probed read-only: recursive
  `Depth: infinity` returned HTTP 403, and its advertised DAV capabilities do
  not include `sync-collection`, so a safe one-request incremental discovery
  is not available on this server.

Stage 6 diagnostics:

- Local asset checks now report whether verification was restored from a
  persisted receipt or reused from memory.
- A cold miss identifies `receipt-missing`, `digest-changed`, `size-changed`,
  `modified-changed`, or `file-absent`, and records the complete SHA-256
  fallback duration separately.
- Diagnostics include only the existing shortened content digest; local paths,
  timestamps, sizes, and full hashes are not logged.
- Added direct coverage for every receipt invalidation reason. The existing
  persistence/restart test remains unchanged and continues to prove that a
  stable file avoids a second digest calculation.

Stage 7 implementation:

- Samsung diagnostics showed that every persisted book and cover receipt was
  rejected solely as `modified-changed`; digest and size checks had passed.
- Android `FileStat.modified` uses a local `DateTime`, while the persisted ISO
  value is canonicalized and restored as UTC. The cache now compares whether
  both values identify the same instant instead of comparing their timezone
  representation.
- Digest, size, and genuine modification-time changes still invalidate the
  receipt and trigger the full SHA-256 safety check.
- Added a regression assertion for equal local/UTC timestamps while retaining
  the existing assertion that a real one-second modification is rejected.

Stage 8 implementation:

- Connectivity-triggered synchronization is now subscribed only after the
  library, reading-activity, and organization bootstrap imports finish.
- This prevents a startup sync from racing a late legacy import. On the Onyx
  trace, that race imported a library row after the content phase had already
  converged and left new pending work immediately after a nominally completed
  sync.
- Added a source-boundary regression assertion that all bootstrap calls remain
  before the connectivity subscription.

Stage 9 implementation:

- Added a coordinated known-document pass which snapshots dirty IDs, pushes
  those documents first, and excludes them from the clean pull batch.
- Library, reading-activity, presentation, and runtime content synchronization
  now use that pass instead of independently scheduling the same dirty object
  through both dirty and pull paths.
- A dirty known document is covered by a regression test which verifies one
  remote fetch and successful convergence.
- Per-document failures now emit a safe diagnostic containing only the action
  and normalized error type/status. Document payloads, remote response bodies,
  credentials, and raw exception text are not logged.

Stage 10 implementation:

- The Onyx validation trace identified the remaining failure as a
  `FormatException` while merging a dirty reading-activity document.
- Historical builds generated deterministic UUIDv5 IDs for legacy daily
  aggregates but embedded the current device and local-midnight timestamp in
  the event. A later idempotency fix retained the ID while switching those
  fields to stable values, so the same logical event could fail as an immutable
  ID collision across versions.
- Reading-activity decoding now recognizes the exact deterministic migration
  ID from fingerprint, day, and duration, then canonicalizes both historical
  and current live forms to the same stable source, UTC timestamp, and stamp.
- Real UUIDv4 sessions retain strict collision checks. A newer legacy deletion
  also retains its deletion stamp, so compatibility normalization cannot
  resurrect deleted history.

## Verification log

- Stage 1: `flutter test test/service/sync/reading_activity_test.dart
  test/service/sync/library_protocol_test.dart` passed (16 tests).
- Stage 1 analyzer: no issues.
- Stage 2: the five existing affected suites plus new ETag regression tests
  passed (103 tests).
- Stage 2 analyzer: no issues across all 11 changed Dart files.
- Stage 3 focused cache/migration suites passed (37 tests); analyzer reported
  no issues.
- Final combined `test/service/sync` and `test/service/translate` run passed
  all 344 tests.
- Stage 4 focused asset/database suites passed all 32 tests; focused analysis
  of the four affected Dart files reported no issues.
- Stage 5 focused discovery/runtime/organization suites passed all 23 tests;
  focused analysis of all four affected files reported no issues.
- After stages 4 and 5, the combined `test/service/sync` and
  `test/service/translate` run passed all 347 tests.
- Stage 6 asset diagnostics suite passed all 15 tests; focused analysis of the
  implementation and tests reported no issues.
- Stage 7 asset suite passed all 15 tests; focused analysis of the
  implementation and tests reported no issues.
- After stage 7, the combined `test/service/sync` and
  `test/service/translate` run passed all 348 tests.
- Stage 8 runtime boundary suite passed all 6 tests; focused analysis reported
  no issues.
- Stage 9 affected suites passed all 70 tests, including all 48 coordinator
  tests; focused analysis reported no issues.
- After stages 8-9, the combined `test/service/sync` and
  `test/service/translate` run passed all 349 tests.
- Stage 10 focused reading-activity/coordinator suites passed all 60 tests;
  focused analysis reported no issues.
- After stage 10, the combined `test/service/sync` and
  `test/service/translate` run passed all 351 tests.
- Full-project analyzer reported no errors or warnings. It exits non-zero for
  43 existing info-level notices elsewhere in the project; focused analysis of
  every changed Dart file is clean.

## Samsung release validation

Release commit `9d06ca4f` was installed on Samsung SM-M315F. Two startup syncs
were captured after installation:

- First run: 5.033 s total. Translation cache took about 1.204 s and created
  its persistent checkpoint (`unchanged=0`). Reading bootstrap recognized the
  three existing book/day aggregates without importing new events.
- Second run after restart: 3.493 s total. Translation cache took about 29 ms
  and reused its persisted checkpoint (`unchanged=1`). Reading bootstrap did
  no work (`imported=0 recognized=0 deferred=0`).
- All 22 remotely discovered shared documents used `skip-unchanged` where
  their strong ETags matched. Content-domain time fell from the previous
  device baseline of about 1.337 s to about 0.137 s.
- Both runs completed with `pending=0 failed=0` and no sync errors.

The remaining warm-run critical path is the startup book-asset status task. It
took 3.092 s and overlapped earlier phases; the explicit asset phase then spent
about 1.454 s waiting for the shared work to finish. Stage 4 removes the
per-book remote-presence requests from that path while the receipt is fresh;
device timing validation is still required. Discovery still takes about
1.323 s. Stage 5 reduces post-discovery object requests without caching away
cross-device changes; device timing validation is still required.

### Stages 4-5 device validation

Release commit `2165da47` was installed on Samsung SM-M315F without clearing
application data. Two startup runs were captured:

- First run: 3.857 s total; discovery 1.888 s, organization 0.194 s,
  catalog 0.108 s, assets 1.303 s, content domains 0.131 s, and translation
  cache 0.043 s.
- Second run: 3.541 s total; discovery 1.289 s, organization 0.179 s,
  catalog 0.089 s, assets 1.549 s, content domains 0.116 s, and translation
  cache 0.032 s.
- Both runs reported `trustedRemote=2`, `pending=0`, and `failed=0`. This
  confirms that the asset phase reused both persisted remote-presence receipts
  and made no per-book remote existence checks.
- Authoritative discovery reduced catalog pull targets from 5 to 2 and
  reading-state targets from 5 to 2. Annotation targets fell from 5 to the 4
  objects actually present remotely. No fallback or expected 404 pull was
  observed.
- Total warm time remained within noise of the earlier 3.493 s baseline. The
  cold startup asset-status task still took 3.115-3.434 s and the asset phase
  waited 1.303-1.549 s for its in-flight local verification. Its immediate
  post-asset refresh took only 45-53 ms. The next investigation must determine
  why persisted local verification misses after a process restart (receipt
  absence versus file-stat mismatch) before changing trust semantics.

### Stage 6 device diagnosis

Release commit `2cda24c0` was installed on Samsung SM-M315F without clearing
application data. One startup run was sufficient to identify the invalidation
reason:

- Total sync time was 4.025 s; discovery took about 1.288 s and the startup
  asset-status task took 3.550 s.
- Both book assets and both covers reported `modified-changed`, then passed
  their SHA-256 fallback. The large book digest alone took 3.432 s.
- The asset phase reused both remote-presence receipts (`trustedRemote=2`) and
  completed as soon as the shared local verification finished. The immediate
  post-asset status refresh took 44 ms.
- This isolates the remaining delay to timezone-sensitive `DateTime` equality,
  not WebDAV, missing receipts, changed content, or status propagation.

### Stage 7 device validation

Release commit `0fbe9a14` was installed on Samsung SM-M315F without clearing
application data. One startup run confirmed the optimized warm path:

- Total sync time fell to 1.291 s from the diagnostic run's 4.025 s.
- Both book assets restored their persisted verification in 12-21 ms. Both
  cover assets also hit persisted verification, and no SHA-256 fallback ran.
- Initial asset status for both books completed in 72 ms; the post-asset
  refresh completed in 51 ms. Both books were reported as available locally
  and remotely.
- Phase timings were approximately 0.084 s bootstrap, 0.849 s discovery,
  0.023 s organization, 0.011 s catalog, 0.074 s assets, 0.135 s content
  domains, and 0.032 s translation cache.
- The run discovered 22 documents and completed with `pending=0`, `failed=0`,
  `trustedRemote=2`, and no logged synchronization errors or warnings.

### Onyx cross-device diagnosis before stages 8-9

Onyx LOMONOSOV3 first downloaded the second book during synchronization. That
initial run took 15.514 s, completed both asset transfers, and ended with both
books locally and remotely available. Translation cache, annotations, reading
state, and catalog data otherwise converged.

- Subsequent warm passes took 1.729 s, 1.105 s, and 1.113 s, but consistently
  ended with one pending and one failed reading-activity document.
- After restarting the process, a pass took 2.988 s and ended with three
  pending documents and one failure. The trace showed a library bootstrap
  import occurring after the active content synchronization phase.
- The same dirty reading-activity document was fetched and processed twice in
  one pass: once through the dirty outbox and once through the known-document
  pull. The old release swallowed the per-document exception and exposed only
  the aggregate failure count.
- Stages 8-9 address both independently observed causes. A new Onyx release
  run is required to determine whether the remote reading-activity object now
  converges or whether the new safe diagnostic exposes an additional server
  error requiring a separate fix.

### Onyx validation after stages 8-9

Release commit `b33049ed` was installed on Onyx LOMONOSOV3 without clearing
application data. The startup pass took 1.751 s.

- All bootstrap imports finished before the run began, and the connectivity
  notification was correctly coalesced into the active startup run.
- Local asset status took 77 ms, both books remained available locally and
  remotely, and no asset transfer or SHA-256 fallback occurred.
- The dirty reading-activity document was scheduled for one push rather than
  both a dirty push and a duplicate pull.
- That push still failed, now explicitly as `FormatException`, leaving
  `pending=1 failed=1`. Read-only inspection showed a valid server document;
  Git history then confirmed the incompatible legacy wire variants addressed
  by stage 10.
- The 11 known activity objects are distinct daily documents. Their shortened
  diagnostics share the same book fingerprint and only appear duplicated
  because the date suffix is intentionally omitted from logs.

The read-only WebDAV audit found 12 daily activity documents. Nine older days
contain one legacy-only aggregate which must be retained as their only history.
Three affected documents contain cascades created by the retired reimport bug:
10 legacy/2 real events, 21 legacy/6 real events, and 25 legacy/31 real events.
Their projected totals are inflated. Server-only deletion is unsafe because a
device would merge its local cascade back; cleanup must be a separate protocol
migration applied identically to local and remote canonical documents.

### Stage 11 reset decision

The automatic legacy-cascade cleanup implemented experimentally in commits
`37744729` and `8242d23e` was removed before installation. Reading activity is
not important enough for this library to justify permanent recovery logic in
the protocol. Instead, the complete `reading-activity` domain will be reset
once on WebDAV and on every existing device, with a server backup retained.
A temporary uncommitted maintenance APK may perform the local reset before
normal synchronization starts; that reset code must not remain in the final
application or branch history.

The stage 1 bootstrap-receipt fix prevents the legacy aggregate feedback loop
from being created by current builds. Stage 10 normalization remains because
it is the small compatibility fix required to read old deterministic events
without event-ID collisions.

On 2026-09-04 all 13 remote daily documents were backed up with SHA-256
checksums before the two book-specific WebDAV activity collections were
deleted. The root activity collection was deliberately retained so discovery
continues to return an empty collection rather than 404. A temporary,
uncommitted maintenance APK cleared `tb_reading_time`, all local shared
documents for the domain, its outbox/metadata rows, and both activity bootstrap
receipt generations on Onyx before sync startup. A read-only WebDAV check after
that launch still reported zero child collections. The clean release from
commit `a9b9d116`, without the maintenance hook, was then reinstalled. Samsung
subsequently received the identical maintenance APK before its old application
was allowed to run. Its controlled launch remained healthy and a second
read-only WebDAV check still reported zero activity child collections. The
clean release was then reinstalled on Samsung as well. The one-time reset is
therefore complete across both known replicas, and neither installed APK
contains the maintenance hook.

### Post-reset reading activity validation

Onyx opened `Mystic Game Master Emulator` after the two-device reset, read for
30 seconds, closed the reader, and synchronized. The exported 2026-09-04 log
showed a new revision-1 activity document and a complete automatic run with
`pending=0`, `failed=0`, and `durationMs=1015`.

The subsequent read-only WebDAV audit found exactly one activity collection,
one daily document, and one live event. Its duration was 30 seconds, matching
the interval from `08:24:34Z` to `08:25:04Z`; its event ID was a random UUIDv4,
not a deterministic legacy UUIDv5. There were no deleted entries, duplicate
events, legacy aggregates, or old daily documents. During first-create
reconciliation one request briefly received 412; the existing bounded LOCK
fallback converged revision 1 and did not duplicate data or leave failed work.

### Cross-device reading activity validation

Onyx then created a fresh 13-second UUIDv4 activity event for the second book.
The server contained exactly two 2026-09-04 documents with one event each,
totalling 30 and 13 seconds, with no legacy or deleted entries. The second
first-create also exercised the bounded 412/LOCK fallback and converged with
`pending=0` and `failed=0`; its full run took 1.860 s.

Samsung started from the post-reset empty local activity state. Its startup run
discovered both remote documents, stored them as clean revision-zero pulls,
and projected them locally without any activity push, create, or replace. It
completed in 2.310 s with `pending=0` and `failed=0`. An immediate manual run
then skipped both documents by matching ETag and completed in 1.013 s. A final
read-only WebDAV audit and byte comparison confirmed that both server JSON
files were unchanged: two documents, two unique events, zero legacy events,
and the same 43-second total.

Samsung then opened the second book and recorded an independent 26-second
session. Because that daily document already existed, synchronization followed
the expected `merge -> replace -> converged` path without a create conflict.
The full automatic run completed in 1.340 s with `pending=0` and `failed=0`.
The final WebDAV audit found two UUIDv4 events for that book: the existing
13-second Onyx event and the new 26-second Samsung event, with distinct event
and device IDs. The first book remained byte-for-byte unchanged at 30 seconds.
Across both documents there were three unique events, two devices, zero legacy
events, zero tombstones, and a correct total of 69 seconds.

The Samsung log also contained an unrelated foliate WebView error while
paging. It did not interrupt sync and is tracked separately as `BUG-001` in
[`known-bugs.md`](known-bugs.md).

### Stage 10 device validation

Release commit `0072d48a` was installed on Onyx LOMONOSOV3 without clearing
application data. The first attempted run had no network and was correctly
skipped. The subsequent connected startup pass completed in 1.883 s.

- The formerly failing dirty reading-activity document completed
  `merge -> replace -> converged` at revision 16.
- The run discovered 22 documents and ended with `pending=0 failed=0`; no
  synchronization warning or error was emitted.
- Discovery took about 1.258 s. Content domains, including the one-time repair
  upload, took about 0.387 s. Initial two-book asset status took 67 ms, and no
  asset transfer or SHA-256 fallback occurred.
- A fresh read-only server check identified the repaired object as the
  `2026-09-02` document. It contains 32 deterministic legacy events and 6 real
  events; all 32 legacy events now use the stable canonical representation.
- The merge deliberately retained legacy events which existed on only one
  side, so compatibility repair loses no data but does not reduce the inflated
  aggregate cascade. The independent cleanup migration remains necessary.

## Stage commits

- `b7cd6b7f fix(sync): stop repeated reading bootstrap imports`
- `ded9efeb perf(sync): skip unchanged WebDAV documents by ETag`
- `perf(sync): persist translation sync checkpoints` (stage 3 commit subject)
- `b4a96865 perf(sync): reuse recent remote asset presence`
- `c6efbb0f perf(sync): trust successful discovery targets`
- `dc7d8ea2 diagnostics(sync): explain local asset verification misses`
- `6d873e2b perf(sync): compare asset timestamps by instant`
- `8fc238ca fix(sync): finish bootstrap before connectivity runs`
- `6eebcd88 fix(sync): avoid duplicate dirty document scheduling`
- `e35507bc test(sync): follow coordinated known-document sync`
- `76bae54f fix(sync): normalize legacy reading events`
