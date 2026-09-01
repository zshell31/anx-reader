# Shared-state synchronization architecture

> This document defines the migration target. While the migration progress file shows a milestone as incomplete, the corresponding section here is planned rather than active behavior.

## Boundary and goals

Synchronization is automatic and directionless: pull/discover, merge, project, then flush. Offline local changes are durable and retry after restart/connectivity recovery. The design assumes one active reading device most of the time and uses deterministic domain merges rather than a global CRDT or global last-write-wins rule.

`app_database.db` is local application/projection state. It is not a synchronization artifact. `shared_state.db` is the durable local canonical-document/outbox store and is also never uploaded as SQLite. WebDAV transfers only explicitly versioned documents and immutable assets.

```text
portable domain mutation
  -> shared_state.db (canonical document + atomic outbox)
  -> conditional WebDAV JSON/assets
  -> deterministic domain merge
  -> app_database.db projection
```

## Protocol layout

All identifiers are safe path segments. JSON is canonicalized before writes.

```text
anx/shared/v1/catalog/books/<md5>.json
anx/shared/v1/reading-state/<md5>.json
anx/shared/v1/reading-activity/<md5>/<yyyy-mm-dd>.json
anx/shared/v1/groups/<uuid>.json
anx/shared/v1/tags/<uuid>.json
anx/shared/v1/book-tags/<md5>/<uuid>.json
anx/shared/v1/themes/<uuid>.json
anx/annotations/<md5>.json                 (existing annotation protocol)
anx/translation-cache/<md5>.json           (existing independent cache)
anx/assets/books/md5/<md5>                 (immutable, verified bytes)
```

Every new JSON document has an integer `schemaVersion` and explicit identity fields. Portable identities are lowercase book fingerprints, shared UUIDs, and document IDs. SQLite IDs, file paths, cover paths, provider credentials, note contents in logs, and device UI state are never protocol identities.

## Merge rules

- Catalog membership is a stamped live/tombstone state. A newer tombstone wins and local absence never creates deletion.
- Portable book metadata has independent field values and stamps so unrelated edits converge without overwriting each other.
- Reading position is per-book LWW by `(modifiedAt UTC, deviceId)`. Percentage is payload, never a maximum-based merge key. Opening/restoring does not generate a stamp.
- Book bytes are immutable and content-addressed. A downloaded asset is fingerprint-verified before local binding. Tombstoning does not immediately delete shared bytes.
- Reading activity contains immutable UUID events in bounded per-book/day documents. Merge is union/deduplication by event ID; daily SQLite totals are projections.
- Groups, tags and themes have UUID identities and stamped tombstones. Book/group and book/tag relations refer only to portable identities.
- Annotations continue their existing annotation-specific deterministic v2 merge protocol.
- WebDAV create uses `If-None-Match: *`; replacement uses a strong ETag. A 412 fetches the winner, reruns the domain merge, and retries.

## Automatic triggers and offline behavior

Startup and resume perform discovery/pull followed by outbox flush. Connectivity restoration retries pending work while respecting the Wi-Fi-only preference. Local shared mutations update canonical state and outbox atomically, update the UI projection immediately, and schedule asynchronous sync. Book open refreshes relevant per-book state; book close performs a best-effort flush. Manual **Sync now** is directionless.

Lifecycle-wide runs are single-flight. Triggers arriving during a run request one follow-up pass, so startup/resume/connectivity/manual triggers do not fan out duplicate collection scans. Depth-one WebDAV `PROPFIND` discovers validated document IDs in each flat collection and in the bounded reading-activity/book-tag subcollections; invalid or unexpectedly nested entries are ignored. This allows a fresh device to discover a remote catalog before it has local fingerprints.

Outbox rows survive process death. Interrupted `syncing` metadata is recovered to pending on database open. Malformed remote documents produce observable errors and are not blindly overwritten.

Diagnostics aggregate every domain coordinator into synced, syncing, pending/offline or error state and report only counts, completion time and run duration. Logs do not include document IDs, fingerprints, paths, credentials or document content.

## Retired legacy synchronization

Normal synchronization no longer uploads or downloads a database snapshot, chooses a direction from modification times, replaces the live database, or deletes remote files from the local `tb_books` projection. Existing remote database files are ignored and left untouched for rollback/recovery. Explicit ZIP backup import/export remains a separate user-controlled local operation.
