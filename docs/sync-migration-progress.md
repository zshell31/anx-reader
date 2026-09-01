# Automatic shared-state synchronization migration

## Goal and baseline

- Overall goal: replace legacy whole-`app_database.db` WebDAV synchronization with automatic, domain-oriented shared documents and content-addressed assets.
- Baseline branch / initial commit: `develop` / `699b114b`.
- Feature branch: `feature/automatic-shared-state-sync`.
- Target: `SharedStateDatabase` is the durable canonical document/outbox layer; WebDAV carries versioned JSON documents and immutable assets; `app_database.db` is a local UI projection only.

## Milestones

| Milestone | Status | Summary |
| --- | --- | --- |
| 0. Audit and migration map | completed | Inventoried v8 database and existing legacy/modern sync; defined protocol and migration map. |
| 1. General shared-document sync | not_started | Extract reusable coordinator mechanics without changing annotation semantics. |
| 2. Library and reading position | not_started | Per-book catalog and reading-state documents, projection and bootstrap. |
| 3. Library assets | not_started | Content-addressed book assets and safe local binding. |
| 4. Reading activity | not_started | Immutable session events and aggregate projection. |
| 5. Groups, tags, themes | not_started | UUID identities, tombstones, mappings and projections. |
| 6. Retire database sync | not_started | Remove direction choice and whole-database/file sync from normal behavior. |
| 7. Automatic integration and diagnostics | not_started | Lifecycle orchestration, coalescing, summaries and privacy-safe logs. |
| 8. Documentation and validation | not_started | Refresh all sync docs and complete end-to-end validation. |

## Current audit (database version 8)

| Existing state | Classification | Migration rule |
| --- | --- | --- |
| `tb_books.file_md5` | shared portable identity | Canonical lowercase MD5 fingerprint; never use `id`. |
| Book title, author, description, rating | shared canonical + local projection | Per-field stamped catalog metadata. |
| `is_deleted` / membership | shared canonical + local projection | Stamped tombstone; absence is not deletion. |
| `last_read_position`, `reading_percentage` | shared canonical + local projection | Separate per-book LWW reading-state document; restoration is not a mutation. |
| `tb_books.id`, `file_path`, `cover_path` | device-local projection | Never serialized. Paths are selected on each device. |
| `create_time`, `update_time` | mixed | Portable timestamps inform migration/stamps; local row time remains projection metadata. |
| Book bytes | immutable asset | Address by book fingerprint and verify after download. |
| Covers | rebuildable/optional immutable asset | Prefer regeneration; if referenced, address by content hash, never path. |
| `tb_reading_time` | rebuildable local aggregate | Migrate deterministically to immutable session events; recompute rows from events. |
| `tb_notes` | local annotation projection | Existing annotation v2 protocol remains canonical; local integer IDs stay local. |
| `tb_groups` and book `group_id` | shared canonical + local projection | UUID group records and UUID-to-local-ID mapping; tombstones. |
| Tags/relations encoded in `tb_styles` | shared canonical + local projection | UUID tag records and explicit stamped memberships; sentinel rows stay local-only. |
| `tb_themes` colors | shared canonical + local projection | UUID records with LWW/tombstones. |
| Theme background image path | device-local | Not serialized; portable colors remain shared. |
| Reader style rows and SharedPreferences | device-local | Typography/layout/UI/window/providers/TTS/credentials remain local. |
| Translation cache | independent shared cache | Preserve existing per-book merge sync unchanged. |

## Architecture decisions

- Extend the existing `shared_documents`, `sync_outbox`, and `sync_metadata` tables; do not introduce another synchronization database.
- Documents are small and independently mergeable. Remote roots are under `anx/shared/v1/`; immutable book assets are under `anx/assets/books/md5/`.
- Conditional `If-None-Match` / strong-ETag `If-Match` writes remain the concurrency boundary. HTTP 412 causes GET, domain merge, and retry.
- Version stamps are UTC timestamp plus a persisted stable device UUID tie-breaker. Comparison is lexicographic by instant then device ID.
- Reading position uses per-book LWW, not maximum percentage. Catalog metadata uses field-level LWW. Tombstones prevent resurrection.
- Reading activity uses bounded per-book/day documents containing immutable UUID events; merge is set union by event ID.
- Annotations retain their existing v2 merge rules. Translation cache remains independent.

## Migrations / schema changes

- None yet. Milestone 0 is documentation/audit only.

## Important files inspected/changed

- Inspected `lib/dao/database.dart`, database version/migrations and all DAOs/models for books, reading time, groups, tags, themes and notes.
- Inspected `lib/providers/sync.dart`, `lib/service/database_sync_manager.dart`, shared-state database, annotation coordinator/runtime/protocol, conditional WebDAV transport and translation-cache sync.
- Changed this progress document and `docs/sync-architecture.md`.

## Tests by milestone

- Milestone 0: documentation-only validation with repository searches; no executable behavior changed.

## Known limitations / unresolved issues

- Until Milestone 6, legacy database sync remains callable.
- Existing books without a valid fingerprint cannot be published until their fingerprint is calculated.
- Remote collection discovery must be added to the general runtime; current annotation discovery is based mainly on known fingerprints.

## Exact next step

Mark Milestone 1 in progress and extract `SharedDocumentSyncCoordinator` from the annotation-named coordinator while preserving compatibility and tests.

## Milestone commits

- Milestone 0: `docs(sync): define automatic shared-state migration` (commit recorded by subject until hash is available in the following milestone update).
