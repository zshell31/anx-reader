# WebDAV warm sync optimization progress

Branch: `feature/webdav-warm-sync`

Base commit: `bf6c9196 perf(sync): persist local asset verification`

## Scope

1. Stop repeated legacy reading-activity bootstrap imports.
2. Skip clean document downloads when the WebDAV ETag is unchanged.
3. Persist translation-cache synchronization checkpoints across restarts.

Each completed stage is committed separately together with an update to this
file. The full relevant test suite and static analysis must pass before the
branch is considered complete.

## Current stage

All three planned implementation stages, repository verification, and Samsung
release-device timing validation are complete.

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
about 1.454 s waiting for the shared work to finish. Discovery still took
about 1.323 s. Further work should target asset-status initialization/locking
first, then discovery round trips.

## Stage commits

- `b7cd6b7f fix(sync): stop repeated reading bootstrap imports`
- `ded9efeb perf(sync): skip unchanged WebDAV documents by ETag`
- `perf(sync): persist translation sync checkpoints` (stage 3 commit subject)
