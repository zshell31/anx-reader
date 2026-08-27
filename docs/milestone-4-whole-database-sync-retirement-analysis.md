# Milestone 4: Whole-Database Synchronization Retirement Analysis

Status: design only  
Repository: zshell31/anx-reader  
Branch analyzed: develop  
Commit analyzed: d203291b10d686d3aa13586e1b681c77423ba9e0  
Analysis date: 2026-08-28

## Executive conclusion

Whole-database synchronization can eventually be eliminated completely.

The application may continue using app_database.db as a local application
database, but that file should cease to be a synchronization unit or a shared
source of truth. Cross-device state should instead be synchronized through
portable, domain-specific documents with explicit identity, merge, tombstone,
and recovery semantics.

The recommended canonical local store is a separate shared_state.db owned by
domain synchronization. This separation is essential during migration:
downloading an older legacy app_database.db must not be able to destroy newer
canonical annotations, reading positions, or other shared state.

The intended final relationship is:

    shared domain state in shared_state.db
                 |
                 v
       deterministic domain merge
                 |
                 v
          WebDAV domain JSON
                 |
                 v
       local Anx projections/views
        including app_database.db

BookNote, Book, group, tag, theme, and reading-time rows should be treated as
Anx-local records or projections where appropriate. Their integer primary keys
must never enter cross-device protocols.

## A. Current-state inventory

### A.1 Current database mechanism

The complete application schema is defined in lib/dao/database.dart. The
current database version is 7 and the application creates six user-facing
tables:

- tb_books
- tb_themes
- tb_styles
- tb_notes
- tb_reading_time
- tb_groups

The current synchronization flow compares the local app_database.db/WAL
modification time with the remote database7.db modification time. If both
copies have changed, Sync.determineSyncDirection asks the user to upload or
download.

Upload creates a transactionally consistent database snapshot with VACUUM
INTO. Download validates the remote file, backs up the current database,
closes SQLite, removes WAL files, and replaces app_database.db.

This protects against an invalid SQLite file, but not against a valid older
snapshot replacing newer domain state. All domains are resolved as a single
winner even though they have different merge requirements.

Relevant code:

- lib/dao/database.dart
- lib/providers/sync.dart
- lib/service/database_sync_manager.dart
- lib/service/sync/sync_client_base.dart
- lib/service/sync/webdav_client.dart

### A.2 Persistent domain inventory

| Domain | SQLite storage | Main model/provider/service | Nature | Device-specific portion | Should sync | Current identity | Timestamp/version | Rebuildable |
|---|---|---|---|---|---|---|---|---|
| Library membership | tb_books row plus is_deleted | Book, BookDao, book import/delete flows | User-created | Local row ID is device-specific | Yes, if cross-device bookshelf membership remains supported | Book.id; optional file_md5 | create_time, row-wide update_time, is_deleted | Local row can be rebuilt from a shared catalog |
| Local book registry | tb_books.id, file_path, cover_path | Book, BookDao | Local binding | Yes | No | Local integer ID and relative paths | Shares book row timestamps | Yes |
| Book content asset | File referenced by tb_books.file_path | Sync.syncFiles, book import/download/release | Imported binary | Local presence and path | Remote availability should sync separately | Random filename today; MD5 is available | Filesystem mtime only | Re-downloadable if remote survives |
| Cover asset | File referenced by tb_books.cover_path | BookDetail, book import, syncFiles | Extracted or user-edited | Path and local presence | Extracted cover can be rebuilt; custom cover may need asset sync | Random filename/path | Filesystem mtime and book update_time | Extracted usually yes; custom cover no |
| Book metadata | tb_books.title, author, description, rating | Book, BookDetail, book service | Extracted and user-edited | No | Yes | Currently Book.id; fingerprint is portable candidate | One row-wide update_time | Extracted fields partly; user edits/rating no |
| Reading position | tb_books.last_read_position, reading_percentage | EpubPlayer, BookDao | User activity | No | Yes | Currently Book.id and implicit file association | Mixed-purpose tb_books.update_time | Native columns can be rebuilt |
| Highlights and underlines | tb_notes with type highlight/underline | BookNote, BookNoteDao, ExcerptMenu | User-created | No | Yes | Local BookNote.id; DAO dedupes by book_id and CFI | create_time, update_time; hard delete | Yes, from canonical annotation state |
| Personal notes | tb_notes.reader_note | ReaderNoteMenu and notes-page editor | User-created annotation payload | No | Yes | Same local BookNote.id | Shares annotation timestamps, but in-reader edit currently does not advance update_time | Yes |
| Editable excerpt/content | tb_notes.content | Notes-page editor | User-edited annotation payload | No | Yes | Same local BookNote.id | update_time on notes-page edit | Yes |
| Bookmarks | tb_notes with type bookmark; percentage encoded in color | Bookmark provider and reader handler | User-created | No | Yes | Local row ID and CFI | create_time, update_time; hard delete | Yes |
| Reading activity/history | tb_reading_time | ReadingTimeDao, ReadingPage lifecycle | User activity | Calendar-day interpretation includes device timezone | Yes if merged history/statistics are expected | Local row ID and book_id | Date reduced to YYYY-MM-DD; no row version or tombstone | Native daily totals can be rebuilt |
| Reading statistics | Queries over books, notes, and reading time | Statistics providers | Derived | No | Do not sync directly | Derived | None | Yes |
| Folder/group definitions | tb_groups | GroupDao, bookshelf organization | User-created | No | Yes | Local integer group ID | create_time, update_time, is_deleted | Local rows can be rebuilt |
| Folder membership | tb_books.group_id | BookFolder, BookList | User-created | No | Yes | Local Book.id plus local group ID | Only book row update_time | Yes |
| Tag definitions | Sentinel tb_styles rows with font_size 1.0 | TagDao, TagList | User-created | No | Yes | Local tb_styles.id and case-insensitive name | No timestamps or tombstones | Yes |
| Book-tag relations | Sentinel tb_styles rows with font_size 2.0 | BookTagDao, BookTagEditor | User-created | No | Yes | Local book and tag integers encoded as numeric style fields | No timestamps or tombstones | Yes |
| Reading theme definitions | tb_themes | ReadTheme, ThemeDao, style UI | Defaults plus user changes | background_image_path may be local | Custom definitions preferably yes; active selection local | Local integer theme ID | No timestamps or tombstones | Defaults yes; custom definitions no |
| Historical style rows | Non-sentinel rows in tb_styles | No active reader consumer | Legacy/inert | N/A | No | Local integer | None | Can be discarded after migration validation |
| SQLite bookkeeping | sqlite_sequence, WAL/SHM state | SQLite/DBHelper | Derived | Yes | No | Internal | Internal | Yes |

### A.3 Important state outside app_database.db

Almost all global reader and presentation settings live in SharedPreferences,
not SQLite. They are included in manual ZIP backup/restore but are not part of
current WebDAV database synchronization.

Examples include:

- reader layout and typography;
- active reading theme;
- annotation default type/color;
- synchronization settings and credentials;
- AI provider settings;
- translation settings;
- TTS settings;
- app appearance and window state.

The current per-book translation mode is stored in SharedPreferences using
Book.id as the map key. It is therefore non-portable even though it is outside
SQLite. It should remain a local presentation setting by default, or be
migrated to a fingerprint-keyed settings domain if cross-device behavior is
explicitly desired.

The full-text translation cache already lives in translation_cache.db and
already synchronizes per-book JSON documents. It does not depend on the
app_database.db snapshot and is not a blocker to retirement.

AI chat history is a bounded cache file named ai_history.json under the cache
directory. In-reader navigation history is in memory. Neither currently relies
on database sync.

### A.4 Current identity coupling

Whole-database copying currently makes local integers appear portable because
all devices receive the same rows:

- tb_notes.book_id references Book.id;
- tb_reading_time.book_id references Book.id;
- tb_books.group_id references tb_groups.id;
- tag relations encode Book.id and tag IDs;
- renderer annotations receive BookNote.id;
- file sync uses randomized file_path and cover_path names from tb_books.

These are copied identities, not valid distributed identities. A domain-level
replacement must not serialize these integers into JSON.

## B. Synchronization classification

### B.1 Local-only

The following state should not move between devices:

- Book.id and BookNote.id;
- group/tag/theme projection integers;
- local file path and cover path;
- storage location/volume;
- whether a book binary is currently downloaded on this device;
- temporary files, WAL state, and SQLite sequence values;
- in-reader navigation stack;
- window state;
- device-specific fonts and external dictionary components;
- active presentation selections unless a later settings feature explicitly
  makes them shared;
- AI chat cache by default.

### B.2 Shared state with simple reconciliation

The following can use a constrained deterministic LWW-style rule:

- current reading position, provided passive book-open relocations do not count
  as writes;
- individual book metadata fields and rating;
- individual custom-theme fields;
- single-folder membership for a book.

LWW should not mean an unqualified comparison of device wall clocks. Records
should include mutation ID, stable device ID, logical/causal version, UTC time,
and a deterministic tie-break. Severe server-observed clock skew should be
detected.

### B.3 Shared state requiring structural merge

The following cannot safely be replaced as whole documents without semantic
merge:

- annotations and personal note payloads;
- bookmarks;
- reading activity/history;
- library membership/tombstones;
- folder definitions;
- tags and book-tag relations;
- custom-theme collections.

Independent IDs merge by union. Deletion must be represented by tombstones.
Collections and relations require element-level merge rules.

### B.4 Rebuildable projections/caches

The following should not be synchronized directly:

- BookNote once AnnotationBookDocument is canonical;
- tb_books reading-position columns once reading state is canonical;
- tb_reading_time daily rows once reading activity events are canonical;
- local Book/group/tag/theme projection IDs;
- dashboard/statistics summaries;
- extracted covers when they can be regenerated;
- historical style rows;
- translation results in the sense that they are a cache, although retaining
  their existing optional merge sync remains useful.

## C. Can whole-database synchronization be removed?

Yes, but not immediately.

### C.1 Domains requiring new synchronization before full removal

- annotations, personal notes, edited excerpts, and tombstones;
- bookmarks, either as part of annotation protocol v2 or a separate domain;
- current reading position;
- shared library membership/catalog;
- book metadata and rating;
- association between catalog entries and remote book/cover assets;
- reading activity/history if cross-device statistics are promised;
- folders/groups and their memberships;
- tags and book-tag relations;
- custom reading-theme definitions if their current cross-device persistence is
  considered important.

### C.2 Things that do not need synchronization

- local database integers;
- paths and storage volumes;
- local file-presence state;
- derived statistics;
- cache and rendering state;
- historical unused style rows;
- most device presentation settings;
- AI cache/history by default;
- SQLite internals.

### C.3 Two separate retirement gates

The upload/download choice can disappear from normal UX before every legacy
line is deleted, but only after the high-value automatic path is complete:

- canonical shared-state foundation;
- automatic annotations/bookmarks;
- automatic reading position;
- a shared catalog able to discover and bind remote books without copying
  tb_books.

At that point legacy database handling may remain as an advanced import or
compatibility tool.

The legacy implementation cannot be deleted completely until all other
user-important shared domains have either migrated or been explicitly declared
local-only.

## D. Target synchronization architecture

### D.1 Compact architecture

                             WebDAV shared/v1
                                   |
           +-----------------------+------------------------+
           |               |               |               |
      annotations       reading-state   library/catalog  activity/org
      domain merge      meaningful LWW  field/set merge  event/set merge
           |               |               |               |
           +---------------+-------+-------+---------------+
                                   |
                            shared_state.db
                      canonical state + outbox
                                   |
                     idempotent projection repair
                                   |
           +-----------------------+------------------------+
           |                       |                        |
        tb_notes              tb_books/read time      groups/tags/themes
                                   |
                                Anx UI

### D.2 Shared infrastructure

The reusable portion should include:

- SharedStateDatabase;
- stable local device identity;
- durable dirty/outbox records;
- per-document remote ETag/head metadata;
- retry/backoff scheduling;
- connectivity and lifecycle triggers;
- typed WebDAV object operations;
- projection reconciliation scheduling;
- aggregate and per-domain sync status.

The reusable portion should not include a generic arbitrary-JSON merge engine.
Each domain must own:

- schema validation;
- canonical serialization;
- identity validation;
- merge semantics;
- tombstone behavior;
- materialization rules;
- compatibility behavior.

### D.3 Canonical mutation flow

    UI mutation
      -> domain repository transaction
           update canonical shared record
           create tombstone/version if needed
           mark document dirty in outbox
      -> return local success
      -> reconcile native projection
      -> schedule asynchronous synchronization

Local success never waits for network access.

### D.4 Remote synchronization loop

    GET document and ETag
      -> validate identity/schema
      -> merge local and remote
      -> commit merged canonical state
      -> reconcile projection
      -> conditional PUT with If-Match

For a missing document, use If-None-Match: *.

If the server returns 412:

    GET newest document and ETag
      -> merge again
      -> conditional PUT again

After bounded retries, retain dirty state and retry later.

The current SyncClientBase exposes ETags through RemoteFile but has no
conditional PUT API. WebdavClient.uploadFile may remove the previous file
before writing, which widens the race window. Conditional object operations are
a prerequisite for safe concurrent domain sync.

## E. Canonical local storage

### E.1 Option comparison

| Concern | Option A: app_database.db | Option B: shared_state.db | Option C: one store per domain |
|---|---|---|---|
| Legacy DB replacement | Canonical state is destroyed | Canonical state survives | Canonical state survives |
| Canonical mutation plus outbox | Atomic | Atomic | Atomic within each domain |
| Canonical plus native projection | Can be one transaction, but tightly coupled | Intentionally separate; recovered by reconciliation | Separate |
| Migration complexity | Low initially, unsafe in coexistence | One new schema and migration system | Multiple stores and backup paths |
| Corruption isolation | Native and shared fail together | Native DB remains separate; shared domains share one DB | Best isolation |
| Backup | Accidentally tied to legacy snapshot | Explicit and controllable | More files to enumerate |
| Testing | Entangled with app DB behavior | Clean repository boundary | Clean but operationally heavier |
| Future extensibility | Encourages legacy coupling | Good | Good but premature |

### E.2 Recommendation

Use Option B: one shared_state.db with domain-separated tables and
repositories.

Reasons:

- it satisfies the requirement that an old app_database.db download cannot
  destroy newer canonical state;
- canonical mutation and outbox state can be committed atomically;
- cross-domain fingerprint aliases and migration receipts have one durable
  home;
- native projections can be deleted and rebuilt;
- it is easier to back up and test than multiple stores;
- domain merge logic can still remain isolated in code.

The translation cache should remain in translation_cache.db because it is a
large, expendable cache with an existing lifecycle.

shared_state.db should use normal SQLite WAL, integrity checks, schema
migrations, and checkpointed manual backup. Manual export must include its
outbox. It must never be added to the legacy database uploader.

## F. Domain protocol table

| Domain | Identity | Canonical local representation | Remote representation | Merge rule | Native/local state |
|---|---|---|---|---|---|
| Annotations and personal notes | Shared annotation UUID within book fingerprint | AnnotationBookDocument records and tombstones | annotations/md5/fingerprint.json | Existing Lingua semantics; union independent IDs; deterministic same-ID merge; tombstones | Supported entries projected to tb_notes |
| Bookmarks | Bookmark UUID within book fingerprint | Dedicated record set unless annotation v2 standardizes bookmark | bookmarks/md5/fingerprint.json or annotation extension | Union by UUID, field merge, tombstone | tb_notes type bookmark |
| Reading position | Book source/rendition fingerprint | One meaningful position record with version metadata | reading-state/md5/fingerprint.json | Causal/meaningful LWW; never maximum percentage | tb_books position columns |
| Reading activity | Activity UUID plus book fingerprint | Immutable session fragments and tombstones | reading-activity/md5/fingerprint.json | Set union plus tombstones | tb_reading_time daily aggregate |
| Statistics | None | Derived queries/materializations | None | Recompute | Dashboard state |
| Library membership | Library-entry UUID plus content fingerprint | Catalog entry and tombstone | One file per library entry/book | Element/map merge | Local tb_books row |
| Book metadata/rating | Library-entry identity or content identity | Field-versioned metadata | Same per-book catalog document | Per-field deterministic LWW | Local book columns |
| Local file binding | Local binding ID referencing fingerprint | Local registry only | None | None | Book.id, path, downloaded status |
| Book binary asset | Content hash and format | Local asset registry | Content-addressed immutable file | No mutable merge | Local file presence |
| Folder definitions | Stable group UUID | Group map and tombstones | organization/collections.json | Per-record/field merge, tombstones, cycle validation | tb_groups projection |
| Folder membership | Book identity and group UUID | One versioned membership register per book | Prefer per-book catalog document | Deterministic register | tb_books.group_id |
| Tag definitions | Stable tag UUID | Tag map and tombstones | organization/tags.json | Per-record/field merge | Sentinel tb_styles rows |
| Book-tag membership | Book identity plus tag UUID | Observed-remove set or versioned memberships | Prefer per-book catalog document | Element add/remove merge | Sentinel relation rows |
| Reading themes | Stable theme UUID | Theme definitions and tombstones | preferences/reading-themes.json | Collection union and field LWW | tb_themes projection; active selection local |
| Presentation settings | Device/profile identity | SharedPreferences | None initially | None | Local |
| Translation cache | Existing request key and book fingerprint | translation_cache.db | Existing per-book JSON | Existing deterministic cache merge | Rebuildable cache |

## G. Annotation implications

### G.1 BookNote must be a projection

The target relationship is:

    SharedAnnotation.id
             |
             v
    zero or one native BookNote

A shared annotation may have no native row because it is:

- a retained tombstone;
- unsupported by the current renderer;
- based on an incompatible locator/rendition;
- awaiting projection repair;
- colliding with a native renderer limitation.

Current native limitations matter:

- BookNoteDao deduplicates highlight, underline, and bookmark rows by
  book_id plus CFI, not by stable annotation identity;
- JavaScript receives BookNote.id;
- the renderer also indexes annotations by CFI;
- multiple protocol annotations at the same location may not be representable.

Canonical state must retain every valid remote annotation even if native
materialization is impossible.

### G.2 shared_annotation_id versus binding table

Recommended hybrid:

1. Add nullable shared_annotation_id TEXT to tb_notes.
2. Make it unique when non-null.
3. Store canonical annotation identity and content only in shared_state.db.
4. Keep optional projection metadata in shared_state.db:
   - cached native row ID;
   - last projected canonical hash;
   - projection generation;
   - supported/unsupported status;
   - last projection error;
   - legacy import receipt.

The direct column makes each native row self-identifying. A separate binding
table alone is unsafe because a database replacement can make a cached integer
ID refer to a missing or unrelated row.

The cached BookNote.id is never durable shared identity and never enters the
annotation wire protocol.

### G.3 Canonical-first repository boundary

Create AnnotationRepository as the only supported mutation entry point for:

- create highlight;
- create underline;
- edit excerpt/content;
- edit personal note;
- change type;
- change color;
- delete annotation;
- materialize/import remote annotation.

Use BookmarkRepository or an explicit bookmark facet if bookmarks remain a
separate protocol.

Actual mutation paths that must be routed through the repository include:

- auto-highlight in widgets/context_menu/context_menu.dart;
- create, color, type, and delete in
  widgets/context_menu/excerpt_menu.dart;
- personal-note save in widgets/context_menu/reader_note_menu.dart;
- notes-page edit/delete in providers/book_notes.dart;
- bookmark create/delete in providers/bookmark.dart.

Projection writes need an internal projector API that bypasses repository
mutation detection, avoiding recursive canonical writes.

### G.4 Crash property

This sequence is safe:

    canonical annotation committed
    app crashes
    BookNote projection incomplete

On startup or book open, reconciliation materializes the missing row.

This sequence must be removed from all supported paths:

    native BookNote committed
    app crashes before canonical state exists

It is especially unsafe during coexistence because a later legacy database
download can erase the only copy.

### G.5 Merge and deletion

Retain Lingua Reader annotation semantics as the basis. Required properties:

- distinct shared IDs merge by union;
- all operations use stable shared IDs;
- same-ID merges are deterministic;
- deletion is a tombstone, never simple absence;
- a causally later operation wins;
- concurrent delete versus edit should be delete-wins to prevent resurrection;
- losing concurrent personal-note text should be retained as conflict/audit
  state until compaction;
- tombstones should not be compacted initially because long-offline and older
  clients make safe acknowledgement difficult.

Bookmarks should be placed in AnnotationBookDocument only if protocol v2
explicitly standardizes bookmark locator and merge semantics. Sharing tb_notes
is not by itself sufficient justification.

## H. Reading-position protocol

### H.1 Existing representation and lifecycle

The current reader receives relocation data from Foliate:

- CFI;
- total progression percentage;
- chapter title;
- chapter href;
- chapter current/total page;
- book current/total location, although Dart currently discards these fields.

Every changed onRelocated event calls saveReadingProgress. That writes
last_read_position and reading_percentage to tb_books and advances the
row-wide update_time. Progress is also saved during backgrounding and disposal.

Consequences:

- a passive book open can look like a new position update;
- position timing is mixed with metadata/group/MD5 timing;
- a naive latest tb_books.update_time rule is not a reliable position clock;
- high-frequency relocations create unnecessary database and synchronization
  churn.

Opening the reader with an explicit CFI currently avoids updating normal
progress. This is useful: visiting a note/search result should not silently
replace the user's normal reading position.

### H.2 Locator portability

Foliate exposes an EPUB-CFI-like locator across formats. If a book format does
not provide section CFIs, the view generates a synthetic CFI based on section
index.

Therefore:

- EPUB CFI is portable across byte/content-equivalent renditions with compatible
  parser behavior;
- PDF, MOBI, and FB2 locators may rely on generated sections and should be
  accepted only for the same content/rendition fingerprint;
- percentage is a useful fallback but not a precise locator;
- chapter href/index and section progression provide another fallback;
- replacing a file changes identity and should invalidate direct locator use;
- TXT requires both original source fingerprint and generated EPUB rendition
  fingerprint because initial import hashes the TXT before conversion.

### H.3 Proposed shared reading state

Conceptual shape:

    {
      "schemaVersion": 1,
      "book": {
        "sourceFingerprint": {
          "algorithm": "md5",
          "value": "..."
        },
        "renditionFingerprint": {
          "algorithm": "md5",
          "value": "..."
        },
        "format": "epub"
      },
      "position": {
        "locatorType": "epub-cfi",
        "locator": "epubcfi(...)",
        "progression": 0.42,
        "sectionHref": "chapter14.xhtml",
        "sectionIndex": 13,
        "sectionProgression": 0.17,
        "display": {
          "chapterTitle": "Chapter 14"
        }
      },
      "commit": {
        "mutationId": "uuid",
        "deviceId": "stable-random-device-id",
        "sessionId": "uuid",
        "meaningfulAt": "UTC timestamp",
        "activeReadingSeconds": 184,
        "logicalClock": 42
      }
    }

The final wire spelling may differ, but source/rendition identity, exact
locator, fallback progression, meaningful-read evidence, and deterministic
version fields are required.

### H.4 Meaningful-write semantics

Do not create a shared position mutation for the initial layout relocation.

Create a position commit only after meaningful activity, such as:

- explicit next/previous/navigation after open;
- active foreground reading beyond a small threshold;
- changed locator following user interaction;
- explicit progress-slider navigation;
- periodic debounced checkpoint during a genuine reading session;
- book close/background when a meaningful candidate exists.

Canonical local persistence should be prompt, but network upload should be
debounced.

### H.5 Merge semantics

Simple LWW is sufficient only after meaningful-write gating:

1. A causally descending commit wins.
2. Concurrent commits compare meaningful UTC/HLC time.
3. Equal versions use stable device/mutation identity as a tie-break.
4. Implausible future timestamps are clamped or quarantined relative to
   server-observed time.
5. Never choose maximum progression; rereading and intentional backward
   navigation are valid.
6. Passive book-open relocations never participate.
7. A remote position should not jump an already active reader session. Apply it
   on the next open unless the local session has not meaningfully begun.

This gives the desired chapter 14 result when one device read later than a
desktop at chapter 11, while still allowing a later intentional reread.

### H.6 Reading activity is a different domain

Reading position and reading statistics must not share one protocol.

Current tb_reading_time rows aggregate seconds into one local calendar-day row.
Synchronizing daily totals by LWW loses concurrent activity. Adding totals from
two snapshots can double-count activity already copied between devices.

Preferred shared representation:

- immutable reading-session fragments with UUIDs;
- book source fingerprint;
- active duration;
- start/end time;
- timezone offset used for grouping;
- device/session ID;
- tombstones for user-requested history deletion.

Merge is set union plus tombstones. tb_reading_time becomes a daily aggregate
projection.

Initial migration can create deterministic legacy baseline events keyed by book
fingerprint, day, and database-lineage/import identity. Import receipts prevent
the same old total from being added repeatedly.

## I. Book and library synchronization

### I.1 Why a catalog is required

Current file sync depends on copied tb_books rows:

- the row lists randomized book and cover paths;
- a remote-only book becomes visible after database download;
- the local file can then be downloaded on demand;
- syncFiles removes files not referenced by the database.

If database sync stops without a replacement catalog, a fresh device cannot
discover remote books even though the binary assets exist.

### I.2 Shared versus local split

Shared library catalog:

- stable library-entry UUID;
- source content fingerprint;
- rendition/format information;
- membership/tombstone;
- title, author, description, rating;
- optional custom-cover asset reference;
- organization references;
- immutable remote book asset reference.

Local book registry:

- local Book.id;
- local file and cover paths;
- storage volume;
- downloaded/released status;
- projection status;
- mapping to shared library-entry and content identity.

### I.3 Asset semantics

Move binary storage toward content-addressed paths:

    assets/books/<algorithm>/<fingerprint>.<format>
    assets/covers/<content-hash>

Rules:

- book assets are immutable by hash;
- local release-space is not a shared deletion;
- remove-from-library-everywhere is a shared catalog tombstone;
- remote garbage collection uses catalog tombstones and a grace period;
- one device lacking a local row/file must never cause immediate remote asset
  deletion;
- extracted covers may be regenerated;
- user-selected custom covers require immutable asset sync if they are shared.

### I.4 Fingerprint recommendations

Use tagged identities rather than a bare MD5 string:

    {
      "algorithm": "md5",
      "value": "lowercase-32-hex"
    }

MD5 is already the Anx/Lingua interoperability key and is used by translation
cache. Algorithm tagging allows a future SHA-256 identity without ambiguity.

Same bytes should normally represent one shared content identity. Different
local paths become aliases. If the product later needs two logical bookshelf
entries for identical bytes, use separate libraryEntryId values while retaining
the same content fingerprint.

Replacing a book file creates a new content/rendition identity. Annotations and
positions should not automatically transfer unless an explicit equivalence
process validates locators.

## J. Automatic synchronization lifecycle

### J.1 Triggers

- App startup: load local state immediately; schedule discovery and pull.
- App resume: retry pending/error work.
- Connectivity regained: retry dirty domains.
- Book open: reconcile projections immediately, then perform targeted
  background sync for that book.
- Local mutation: commit canonical state and dirty outbox, then debounce sync.
- Reading session: debounce position commits and append activity fragments.
- Book close/background: best-effort flush; correctness never assumes it
  completes.
- Periodic foreground retry.
- Manual Sync now: optional scheduler trigger and diagnostics.

### J.2 User-visible states

- Synced: no dirty work and the last attempt succeeded.
- Syncing.
- Pending/offline: local state is valid and queued.
- Error: authentication, malformed data, or repeated transport failure.

Normal operation must not show modal choices for upload/download,
local/remote, or overwrite/replace.

Credentials and persistent malformed remote state may require explicit user
attention, but ordinary conflicts are merged automatically.

## K. WebDAV layout

Use a namespace physically separate from legacy snapshots:

    anx/
    ├── database7.db
    ├── data/
    └── shared/
        └── v1/
            ├── annotations/
            │   └── md5/
            │       └── <fingerprint>.json
            ├── bookmarks/
            │   └── md5/
            │       └── <fingerprint>.json
            ├── reading-state/
            │   └── md5/
            │       └── <fingerprint>.json
            ├── reading-activity/
            │   └── md5/
            │       └── <fingerprint>.json
            ├── library/
            │   └── books/
            │       └── <library-entry-id>.json
            ├── organization/
            │   ├── collections.json
            │   └── tags.json
            └── preferences/
                └── reading-themes.json

bookmarks may be omitted as a separate directory if annotation protocol v2
deliberately standardizes them.

Per-book documents are appropriate for annotations, bookmarks, reading state,
reading activity, and library entries because they reduce contention and allow
targeted synchronization.

Low-write definitions such as collections, tags, and themes may initially use
one global document each.

The existing translation cache namespace can remain unchanged during
migration, while adopting conditional writes through the improved transport.

ETags are concurrency-control inputs, not merge semantics.

## L. Transitional coexistence with legacy DB sync

### L.1 Legacy download removes newer BookNote projections

shared_state.db is unaffected.

After app_database.db reopens:

1. apply native schema migration, including shared_annotation_id;
2. correlate books by fingerprint;
3. reconcile canonical annotations/bookmarks;
4. recreate supported native rows;
5. assign new local BookNote IDs as needed.

Canonical state is authoritative.

### L.2 Old notes with no shared IDs

Use an idempotent legacy importer:

- resolve the portable book fingerprint;
- derive a legacy anchor primarily from fingerprint, CFI, create time, and
  native type;
- use row ID only as a same-database-lineage hint;
- match an existing canonical annotation before creating a new one;
- record source anchor, native hash/update time, and assigned shared ID in
  shared_state.db;
- project back with shared_annotation_id.

Because current Anx usually allows one native annotation per CFI, location and
creation information are strong matching inputs, but collision handling is
still required.

An older snapshot must not resurrect a canonical tombstone. Import receipts
and tombstones prevent repeated bootstrap.

### L.3 Legacy DB contains newer reading position

Initial migration imports native position when canonical position is absent.

During coexistence, store a bridge record containing:

- last native position projected by the new client;
- projection hash and canonical mutation ID;
- last imported legacy position/hash;
- observed snapshot metadata.

After DB replacement:

- known projection or historical import: ignore;
- older than canonical: reproject canonical;
- genuinely different and plausibly newer old-client position: convert to a
  legacy position commit and run normal merge.

Do not rely only on tb_books.update_time because the same timestamp also
changes for metadata, groups, MD5, rating, and position.

### L.4 New and old Anx clients share one WebDAV account

Possible guarantees:

- old clients cannot overwrite shared/v1 because they do not know it;
- new clients can import eligible changes from legacy DB snapshots;
- new canonical supported data can be projected into app_database.db for
  limited old-client visibility while schema compatibility remains.

Impossible guarantees:

- real-time domain merge with an old client;
- old-client preservation of unsupported annotations;
- stable BookNote IDs;
- compatibility after an incompatible native database version/file change;
- protection from the old client's own destructive upload/download choice.

Mixed-version support is a migration bridge, not a permanent architecture.

### L.5 Old whole-DB upload after new domain sync

The old client updates only anx/database7.db. Files under anx/shared/v1 remain
untouched.

New clients import only genuinely unseen/newer legacy mutations and never
treat the uploaded database as canonical.

## M. Failure scenarios

| Scenario | Expected behavior and authority | User action | Data loss |
|---|---|---|---|
| 1. Two devices create different annotations offline | Union by shared annotation IDs; conditional retries converge | None | No |
| 2. Both edit the same personal note offline | Deterministic protocol merge, preferably field-level; retain losing revision/conflict shadow | Normally none | One visible winner; alternate should remain recoverable until compaction |
| 3. One deletes while another edits | Causally later operation wins; concurrent delete-wins; tombstone prevents resurrection | None | Concurrent edit may stop being active but should remain in audit/conflict state |
| 4. One device has no network for days | Local canonical writes/outbox remain valid and retry later | None | No, unless the unsynced device itself is lost |
| 5. Crash after canonical write before BookNote projection | Startup/book-open reconciler creates/updates projection | None | No |
| 6. Crash during WebDAV sync | Dirty state clears only after confirmed conditional PUT; retry later | None | No |
| 7. Conditional PUT returns 412 | Re-fetch, validate, merge, retry with new ETag | None | No |
| 8. app_database.db replaced by older snapshot | shared_state.db survives; import only eligible legacy changes; rebuild projections | None | No canonical loss |
| 9. Native BookNote rows disappear | Recreate supported rows from canonical state | None | No |
| 10. shared_state.db lost but remote survives | Rebuild canonical store from remote documents and then project | Usually none beyond credentials | Unsynced local-only mutations are lost; synced state survives |
| 11. Remote annotation document lost but local survives | Missing file is not deletion; conditional-create from local canonical state | None | No |
| 12. Same book has different local paths/IDs | Correlate through tagged fingerprint/library-entry ID; keep local bindings | None | No |
| 13. Device clock is wrong | Causal/logical metadata, skew checks, and deterministic ties reduce impact | Warn for severe skew | Pure timestamp conflict could choose wrong revision; retain recent revisions |
| 14. Remote file is malformed | Quarantine raw bytes; retain local valid state; do not overwrite blindly | Only if automatic recovery cannot resolve it | No local loss; malformed remote-only content may already be lost |
| 15. Older Anx continues DB sync | It remains isolated to legacy namespace; new client imports eligible changes | None during support window | Old client can still lose its own state, but cannot destroy domain JSON |
| 16. Annotation is remote but unsupported by Anx renderer | Keep canonical and sync onward; projection status unsupported; no BookNote row | None | No |
| 17. Same annotation receives a new BookNote ID after recreation | shared_annotation_id reconnects projection; protocol never sees local ID | None | No |

## N. Migration plan

### Phase 0: protocol and conformance

Scope:

- finalize annotation protocol v2;
- freeze canonical JSON rules;
- define fingerprints, tombstones, unsupported records, and malformed handling;
- establish shared Lingua/Anx conformance fixtures.

Dependencies:

- agreement with Lingua Reader merge semantics.

Data migration:

- none.

Acceptance:

- deterministic encode/decode and merge on both clients;
- permutation/idempotence tests;
- delete/edit and malformed fixtures.

Rollback:

- no runtime behavior changed.

Legacy DB still required:

- yes.

### Phase 1: shared-state foundation

Scope:

- shared_state.db;
- device identity;
- canonical/outbox transaction;
- per-document ETag heads;
- sync scheduler/status;
- conditional WebDAV transport.

Data migration:

- empty schema only;
- update manual backup/restore.

Acceptance:

- crash-safe outbox;
- offline/restart tests;
- conditional create/update and 412 retry tests;
- shared_state.db excluded from legacy uploader.

Rollback:

- feature remains dormant and the unused DB can be ignored.

Legacy DB still required:

- yes.

### Phase 2: annotation bootstrap and shadow projection

Scope:

- add nullable shared_annotation_id;
- import existing highlights, underlines, personal notes, and bookmarks;
- record import receipts;
- validate projection round trips while native remains active.

Data migration:

- idempotent per-book legacy import.

Acceptance:

- repeated import creates no duplicates;
- old snapshot replacement does not resurrect tombstones;
- unsupported records survive without projections.

Rollback:

- native rows remain; shadow canonical state can be rebuilt.

Legacy DB still required:

- yes.

### Phase 3: canonical annotation cutover

Scope:

- route every annotation/bookmark mutation through repositories;
- make BookNote a projection;
- automatic per-book WebDAV sync;
- projection reconciliation.

Data migration:

- use bootstrapped canonical records.

Acceptance:

- no shared mutation path directly calls BookNoteDao;
- crash-after-canonical tests pass;
- multiple-device conformance passes;
- renderer limitations do not delete canonical records.

Rollback:

- remote sync can be disabled while canonical state continues projecting
  locally.

Legacy DB still required:

- yes, for other domains.

### Phase 4: reading continuity

Scope:

- reading-state protocol;
- meaningful-write lifecycle;
- position projection to tb_books;
- legacy position bridge.

Data migration:

- import one current position per fingerprint.

Acceptance:

- normal multiple-device examples converge;
- book open alone does not overwrite progress;
- explicit note/search opens preserve normal position;
- TXT/rendition fallback tests pass.

Rollback:

- canonical position can continue projecting locally even if remote sync is
  disabled.

Legacy DB still required:

- yes, for library/history/organization.

### Phase 5: library catalog and assets

Scope:

- shared library membership/catalog;
- metadata/rating;
- content-addressed book and cover assets;
- local registry mapping;
- fresh-device discovery.

Data migration:

- transform tb_books rows into catalog entries and local bindings;
- retain legacy randomized assets through compatibility window.

Acceptance:

- a fresh device sees the bookshelf without downloading a database;
- different local paths/IDs correlate correctly;
- release-local-space does not remove shared membership;
- remote asset GC is safe.

Rollback:

- retain legacy assets and reproject catalog to tb_books.

Legacy DB still required:

- only for remaining user domains and compatibility.

### Phase 6: remaining user-important domains

Scope:

- reading activity/history;
- derived statistics projection;
- folders/groups;
- tags and book-tag relations;
- custom reading themes if shared.

Data migration:

- stable UUIDs for groups/tags/themes;
- deterministic reading-time baseline events;
- projection mappings.

Acceptance:

- offline concurrent organization and activity merges;
- no daily total duplication;
- statistics reproduce canonical events;
- legacy replacement rebuilds all projections.

Rollback:

- retain legacy tables as projections.

Legacy DB still required:

- compatibility only.

### Phase 7: disable legacy sync by default

Scope:

- remove automatic direction determination and modal choice from normal UX;
- retain explicit read-only legacy import/advanced backup for a release window.

Acceptance:

- new installs and migrated accounts perform all normal synchronization without
  database transfer;
- remote-only books are discoverable;
- all dirty state is domain-scoped.

Rollback:

- feature flag may restore advanced import, never canonical database authority.

Legacy DB still required:

- no, not for correctness.

### Phase 8: remove legacy implementation

Scope:

- delete database upload/download;
- delete replacement manager;
- delete direction enum/dialog and DB mtime heuristics;
- retain or archive remote database files without interpreting them.

Acceptance:

- all legacy removal criteria remain green on supported platforms;
- fresh-device and recovery tests use only domain documents and assets.

Rollback:

- domain backups and prior release are the recovery route.

Legacy DB still required:

- no.

## O. Legacy removal criteria

### O.1 Criteria to disable by default

- Canonical annotations, personal notes, edits, deletions, and bookmarks exist
  outside app_database.db.
- Reading position has meaningful-write domain sync.
- A new device discovers the shared library and asset references without
  receiving tb_books.
- No remote protocol uses Book.id, BookNote.id, group/tag/theme integer IDs, or
  device paths.
- Legacy DB replacement tests prove canonical state survives and projections
  rebuild.
- Conditional PUT and 412 retry are implemented and tested.
- Offline mutation, restart, background failure, malformed file, missing
  projection, and unsupported annotation tests pass.
- Legacy import is idempotent and tombstoned notes do not resurrect.
- Manual backup includes shared_state.db and pending outbox.
- Product decisions for reading history, organization, and custom themes are
  documented.

### O.2 Criteria to delete implementation

- Reading activity/statistics, folders, tags, metadata/rating, and any promised
  theme synchronization have migrated.
- Old-client compatibility has a documented support cutoff.
- Lost-local-store recovery works from domain documents and asset storage.
- No production path reads or writes databaseN.db.
- Legacy remote database files are retained or archived without automatic
  deletion.
- At least one release has shipped with legacy synchronization disabled by
  default and migration/recovery metrics are acceptable.

## P. Revised roadmap

Recommend a broader synchronization roadmap rather than expanding one
Milestone 4 implementation into every domain.

Milestone 4 should remain annotation-focused but create only the reusable
infrastructure that is already justified:

- shared_state.db;
- canonical transaction and outbox;
- portable book identity service;
- conditional object transport;
- scheduler and status primitives;
- projection reconciliation framework.

Do not generalize merge semantics.

Recommended slices:

- M4A: annotation protocol v2 and cross-client conformance.
- M4B: shared_state.db, conditional transport, outbox, identity aliases.
- M4C: legacy annotation bootstrap and shared_annotation_id.
- M4D: canonical-first annotation/bookmark writes and automatic sync.
- M5: reading-state protocol and meaningful-read lifecycle.
- M6: shared library catalog, metadata, and content-addressed assets.
- M7: reading activity/statistics, folders, tags, and custom themes.
- M8: disable legacy DB sync, retain import bridge temporarily, then remove it.

This is Option C at roadmap level: Milestone 4 remains focused, while database
retirement is an explicit multi-milestone synchronization program.

## Q. Final answers

### 1. Can whole-database sync be eliminated entirely?

Yes. app_database.db may remain a local application/projection database, but
its upload, download, replacement, and direction-selection workflow can be
removed.

### 2. What prevents eliminating it immediately?

Missing domain synchronization for:

- annotations and bookmarks;
- reading position;
- library/catalog and asset association;
- metadata/rating;
- reading activity/history;
- folders and tags;
- custom themes if their present cross-device behavior is retained.

### 3. What should be canonical for annotations?

Locally durable AnnotationBookDocument state in shared_state.db, synchronized
with per-book WebDAV JSON using Lingua-compatible merge semantics.

### 4. Should BookNote be a rebuildable projection?

Yes.

### 5. Should canonical shared state live outside app_database.db?

Yes. Use shared_state.db so a legacy database download cannot destroy it.

### 6. Does tb_notes need shared_annotation_id?

Yes. It should be nullable for migration and unique when non-null.

### 7. Is a separate annotation binding table still necessary?

Not for durable identity. A sidecar remains useful for projection status,
cached native row ID, projected hashes, renderer compatibility, and legacy
import receipts.

### 8. What domains besides annotations need synchronization?

- bookmarks if separate;
- reading position;
- shared library membership/catalog;
- book metadata/rating;
- book and custom-cover asset availability;
- reading activity/history;
- folders;
- tags and relations;
- optionally custom theme definitions.

Derived statistics, local paths/IDs, file-presence state, and device
presentation settings should not be synchronized directly.

### 9. What is the minimum before the upload/download database choice can disappear?

- shared-state/outbox/conditional transport foundation;
- canonical annotations/bookmarks;
- reading-state synchronization;
- a shared library catalog capable of discovering and binding remote books
  without copying tb_books.

Other shared domains must migrate before the legacy implementation is deleted
entirely. During the interim it may remain only as an advanced import or
compatibility mechanism.

### 10. What should the revised roadmap be?

Keep Milestone 4 annotation-focused while building the small reusable sync
kernel. Follow with reading state, then library/catalog/assets, then
activity/organization/themes, and finally disable and delete legacy
whole-database synchronization.

## R. Principal source locations

- lib/dao/database.dart
- lib/dao/book.dart
- lib/dao/book_note.dart
- lib/dao/reading_time.dart
- lib/dao/tag.dart
- lib/dao/theme.dart
- lib/models/book.dart
- lib/models/book_note.dart
- lib/models/bookmark.dart
- lib/providers/sync.dart
- lib/providers/bookmark.dart
- lib/providers/book_notes.dart
- lib/providers/book_list.dart
- lib/providers/tb_groups.dart
- lib/providers/tags.dart
- lib/page/book_player/epub_player.dart
- lib/page/reading_page.dart
- lib/page/book_detail.dart
- lib/widgets/context_menu/context_menu.dart
- lib/widgets/context_menu/excerpt_menu.dart
- lib/widgets/context_menu/reader_note_menu.dart
- lib/widgets/book_notes/book_notes_list.dart
- lib/widgets/bookshelf/book_folder.dart
- lib/widgets/bookshelf/book_opened_folder.dart
- lib/service/book.dart
- lib/service/md5_service.dart
- lib/service/database_sync_manager.dart
- lib/service/sync/sync_client_base.dart
- lib/service/sync/webdav_client.dart
- lib/service/sync/translation_cache_sync_service.dart
- lib/service/translate/translation_cache_database.dart
- lib/config/shared_preference_provider.dart
- assets/foliate-js/src/book.js
- assets/foliate-js/src/view.js
