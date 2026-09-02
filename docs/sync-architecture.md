# Shared synchronization architecture

## Goals and ownership

Normal WebDAV synchronization is automatic, directionless, and domain based.
It discovers remote documents, validates and deterministically merges them,
projects shared semantics locally, verifies immutable assets, and flushes a
durable outbox. It never chooses an upload/download direction and never
transfers a SQLite database.

`app_database.db` contains the device-local application model and projections.
Its integer IDs and filesystem paths have meaning only on that device.
`shared_state.db` contains canonical portable documents, strong ETags, local
revisions, migration receipts, and the durable outbox. Both databases remain
local files and are never uploaded, downloaded, or replaced by sync.

Shared canonical state includes annotations, bookmarks, annotation
presentations, reading position, catalog membership and metadata, organization,
custom themes, and reading activity. Immutable book and custom-cover assets
are shared by exact-byte content hash. Translation cache remains an independent
shared cache.

Device-local state includes SQLite IDs, filesystem paths, verified local asset
bindings, offload/release markers, active theme selection, reader presentation
preferences, WebDAV credentials, most `SharedPreferences`, AI history/cache,
and local UI state. Statistics are rebuilt from reading events. Extractable
covers and built-in themes are derived defaults. SQLite WAL/SHM state and
historical non-tag `tb_styles` rows are neither canonical nor transmitted.

## Local flow and durability

```text
user mutation
  -> domain validation and deterministic mutation stamp/event UUID
  -> shared_state.db canonical document + outbox (one transaction)
  -> app_database.db projection
  -> conditional WebDAV convergence when the network policy permits
```

Canonical durability precedes network scheduling. An outbox row records the
exact local revision. Process restart changes interrupted `syncing` work back
to `pending`; later startup, resume, reconnect, mutation, book-open/close, or
manual synchronization flushes it. Remote reconciliation does not erase a
newer expected local revision.

## Remote layout

The configurable shared root defaults to `Lingua Reader`. All identifiers are
validated safe path segments.

```text
<shared root>/annotations/<book-md5>.json
<shared root>/anx/annotation-presentations.json
<shared root>/shared/v1/catalog/books/<book-md5>.json
<shared root>/shared/v1/reading-state/<book-md5>.json
<shared root>/shared/v1/reading-activity/<book-md5>/<yyyy-mm-dd>.json
<shared root>/shared/v1/groups/<uuid>.json
<shared root>/shared/v1/tags/<uuid>.json
<shared root>/shared/v1/book-tags/<book-md5>/<tag-uuid>.json
<shared root>/shared/v1/themes/<uuid>.json
anx/data/translation-cache/v1/<book-md5>.json
anx/assets/books/sha256/<exact-byte-sha256>
anx/assets/covers/sha256/<exact-byte-sha256>
```

JSON documents carry a schema version and portable identities. JSON is
canonicalized before writes. Asset objects are immutable and the transport has
no delete operation. Catalog tombstones can therefore leave orphaned bytes;
distributed garbage collection is intentionally deferred because deleting a
still-referenced asset is worse than retaining it.

## Identity and merge semantics

The lowercase MD5 book fingerprint is semantic cross-domain book identity. It
is not assumed to hash the current stored bytes: TXT import computes semantic
identity before conversion to EPUB. Every stored asset independently carries a
SHA-256 digest of its exact bytes plus a sanitized format extension.

Portable field mutations use `(modifiedAt UTC, stable device UUID)` stamps.
The timestamp is compared first and the device UUID is the deterministic tie
breaker. No domain performs an arbitrary recursive JSON merge.

- Catalog membership is a stamped live/tombstone value. A stale live replica
  cannot resurrect a newer deletion; an explicit newer re-import can restore
  it. Title, author, description, rating, group membership, book asset, and
  optional cover asset are independently stamped.
- Reading position is per-book LWW by the mutation stamp. Percentage is only a
  payload and is never merged with `max(readingPercentage)`.
- Annotations use their protocol-v2 merge, including bookmarks, selections,
  personal notes, tombstones, and enrichment. Presentation metadata uses its
  own Anx document and merge.
- Reading activity is split into bounded per-book/day documents. Stable UUID
  events merge by set union. Event tombstones use newer stamps, so history
  deletion defeats stale live copies without LWW-replacing a day's total.
- Groups, tags, and custom themes use stable UUID records with stamped fields
  and tombstones. Parents are group UUIDs. Book-group membership uses book
  fingerprint plus group UUID. Book-tag relations use book fingerprint plus
  tag UUID and a stamped add/remove value. Semantic group deletion durably
  writes `deleted=true` before local projection cleanup; the tombstoned remote
  JSON remains shared state and is not deleted from WebDAV.

WebDAV creation uses `If-None-Match: *`. Replacement requires the current
strong ETag with `If-Match`. HTTP 412 triggers bounded reread, domain merge,
and retry. Malformed or identity-mismatched remote documents are rejected and
are never blindly overwritten.

## Discovery, projections, and assets

A full cycle discovers organization and catalog collections first. It projects
group UUID mappings and remote catalog records before deriving the complete
book fingerprint set used for annotations and reading state. Thus a fresh
device can create `tb_books` rows with independent local integer IDs and empty
local paths before acquiring assets.

`sync_group_ids`, `sync_tag_ids`, and `sync_theme_ids` explicitly map shared
UUIDs to device-local integer IDs. Tag relations may continue using sentinel
`tb_styles` rows as a UI projection, never as a wire identity. Reading events
rebuild `tb_reading_time`; dashboard/statistics aggregates are not synced.

Group hierarchy projection is two-phase. The first pass establishes every live
group UUID-to-local-ID mapping; the second resolves parent UUIDs and writes
local `parent_id` values. A canonical null parent alone means local root (`0`).
An unresolved non-null parent is left unresolved rather than silently changed
to root, so remote document completion order cannot alter hierarchy semantics.
Local hard deletion is projection cleanup, never the distributed delete action.

Book and cover uploads occur only when the exact SHA-256 object is absent.
Downloads go to a partial file, are SHA-256 verified, and are atomically bound
to a locally generated path. A valid existing randomized local filename can
upload and bind to the same digest. Corrupt downloads are discarded. Opening
or explicitly downloading a remote-only book acquires its asset. Releasing a
book writes a durable device-local release marker and removes only the local
copy; automatic cycles do not reacquire that digest, and no remote object is
deleted. A later explicit download supersedes the release state.

Custom covers use the same immutable SHA-256 rules. Extracted covers may also
be reconstructed locally. Theme `background_image_path` is never serialized;
the current theme protocol shares portable colors only, so a background-image
binding remains local until a dedicated theme-asset field is introduced.

## Reading activity migration

New completed and paused reading segments create canonical events before the
network is used, then update the local daily aggregate. Existing
`tb_reading_time` rows bootstrap idempotently. Their deterministic UUIDv5 name
is:

```text
namespace = UUID URL namespace
name = anx:legacy-reading:v1:<book-md5>:<yyyy-mm-dd>:<duration-seconds>
```

Two replicas descended from the same legacy database therefore generate the
same event ID and do not double-count. Explicit history deletion tombstones all
known events and reprojects the affected daily totals.

## Automatic cycle and translation cache

Lifecycle-wide runs are coalesced with at most one follow-up pass. Automatic
runs obey the master `autoSync` preference; all network work obeys the Wi-Fi
only preference. Manual **Sync now** remains available whenever WebDAV is
enabled, regardless of `autoSync`. No periodic WorkManager polling is used.

A full cycle validates configuration/network, discovers organization and
catalog state, projects catalog rows, converges fingerprint-dependent domains,
rebuilds reading projections, resolves assets, synchronizes translation cache
best-effort, and publishes an aggregate status. Translation-cache failure is
isolated and cannot abort canonical-domain convergence. Its existing per-book
format, identity validation, merge, deduplication, and remote path are retained.

## Status, logging, and troubleshooting

The UI exposes WebDAV enablement/configuration, Wi-Fi-only, automatic sync,
directionless **Sync now**, overall/domain state, and local/remote/both/
downloading/uploading/released asset availability. Local book IDs are UI keys
only after portable state is resolved. Database timestamps, database versions,
and upload/download choices are not synchronization concepts.

`AnxLog` reports cycle lifecycle and count-only summaries at INFO, per-domain
decisions at DEBUG, retryable malformed/conflict/deferred cases at WARNING,
and unresolved failures at ERROR/SEVERE. Logs may include cycle/trigger/domain,
revisions, ETags, action type, pending counts, asset digest, verification, and
outcome when useful. They must not include credentials, Authorization headers,
annotation/book/translation content, AI commentary, or serialized documents.

For a stuck sync, verify WebDAV configuration, connectivity and Wi-Fi policy,
then inspect pending/error counts and sanitized logs. A missing book file with
a catalog record is remote-only; use explicit download unless it was released.
A verification failure means the downloaded bytes did not match the catalog
SHA-256 and were intentionally rejected.

## Legacy migration and backups

Local books with valid fingerprints bootstrap once into catalog documents;
durable receipts make restart idempotent. Books without a usable fingerprint
remain local and are reported rather than assigned an invented distributed
identity. Groups/tags/themes receive deterministic legacy UUID mappings.
Annotations and reading state retain their existing idempotent migrations.

Whole-database WebDAV synchronization, DB/WAL mtime direction selection,
database snapshot upload/download/replacement, filename-based file sync, and
the upload/download conflict UI are removed. Existing remote
`database<version>.db` objects are ignored and left untouched for manual
rollback. Explicit user-controlled ZIP export/import remains a separate backup
and restore feature and may contain local databases.

## Known limitations

There is no distributed immutable-asset garbage collection. Books without a
valid semantic fingerprint cannot participate. Theme background images remain
local. Live two-device interoperability and platform UI behavior still benefit
from manual device testing even though protocol, restart, migration, and
architecture regressions are automated.
