# M4E — Canonical Annotation UX, BookNote Removal, and Selection Workflow

This document is the durable source of truth for M4E. A new work session must
read it completely, inspect the latest 20 commits and the worktree status, then
continue from the first incomplete submilestone and the Current checkpoint.

## Goal

M4E makes canonical shared annotation state the only semantic annotation model:

```text
SharedAnnotation
    = canonical semantic annotation state

AnxAnnotationPresentation
    = Anx-specific style/color state synchronized between Anx installations

SelectionSession
    = transient current-selection interaction state

FoliateAnnotationDto
    = ephemeral renderer payload
```

`BookNote` and the persistent native annotation projection are being removed as
annotation domain concepts. Protocol v2 remains the canonical serialization and
merge boundary. Typed UI/read adapters must not round-trip or rewrite protocol
maps in ways that could discard unknown fields or selectors.

The final data flow is:

```text
                         shared_state
                              │
                              ▼
                    AnnotationBookDocument
                              │
                    canonical SharedAnnotation
                      /                 \
                     /                   \
                    ▼                     ▼
           Annotation UI           Renderer Adapter
                    │                     │
                    │               + effective Anx presentation
                    │                     │
                    ▼                     ▼
             Notes / Editor             Foliate


Text selection
      │
      ▼
SelectionSession
      │
      ├── AI ───────────── transient
      ├── Translate ────── transient
      ├── Dictionary ───── transient
      │
      └── explicit Save
               │
               ▼
        SharedAnnotation
```

## Invariants

- UI annotation identity == `SharedAnnotation.id`.
- Semantic reads come from canonical shared annotation state.
- Semantic mutations go through canonical repository APIs.
- Selection != annotation creation.
- Lookup != annotation creation.
- Presentation is client-specific and synchronizable between Anx Reader
  installations, but remains outside protocol-v2 annotation bytes.
- Presentation mutation does not dirty canonical state.
- Same CFI != same annotation.
- Missing renderer representation != missing annotation.
- The action menu cannot outlive its `SelectionSession`.
- Selection changes never automatically open actions.
- Persisted annotation context != provider lookup context.
- Protocol v2 wire shape, deterministic merge behavior, MD5 book identity,
  WebDAV transport behavior, and annotation UUID identity stay frozen unless a
  separately documented correctness bug requires a change.
- Canonical semantic state is durable before renderer/UI refresh; refresh
  failure is not reported as semantic save failure.
- Bookmark motivation is semantic and is not a presentation style.

## Session protocol

At the start of every M4E session:

1. Check out `feature/m4e-canonical-annotation-ux`.
2. Read this document completely.
3. Inspect `git log --oneline --decorate -20`.
4. Inspect `git status`.
5. Continue with the first incomplete submilestone.

At the end of every M4E session:

1. Prefer finishing and testing the current coherent submilestone.
2. Commit each completed submilestone independently.
3. Update its record and the Current checkpoint below.
4. Leave a clean worktree, or explicitly document unavoidable unfinished work.
5. State the exact next task.

## Initial architecture inventory

- `lib/service/sync/annotation_protocol.dart` owns protocol-v2 validation,
  normalization, canonical serialization, and deterministic merge behavior.
- `lib/service/sync/shared_state_database.dart` owns canonical shared documents,
  sync outbox state, legacy-import receipts, and the projection metadata that
  M4E will eventually remove.
- `lib/service/sync/annotation_repository.dart` is canonical-first for semantic
  writes, but its public identities and results still depend on native
  `BookNote` records and projection reconciliation.
- `lib/service/sync/annotation_projection_reconciler.dart`,
  `native_annotation_projection.dart`, and
  `legacy_annotation_bootstrap.dart` form the current canonical-to-native
  compatibility path.
- `lib/models/book_note.dart`, `lib/dao/book_note.dart`, Notes providers/widgets,
  export/statistics code, and reader integration remain native-note consumers.
- `lib/page/book_player/epub_player.dart` and
  `assets/foliate-js/src/book.js` currently couple selection changes, popup
  lifetime, clear locks, timers, and Android selection behavior.
- Existing synchronization and protocol tests under `test/service/sync/` are
  mandatory regression coverage throughout M4E.

## Submilestone checklist

### M4E.1 — Canonical annotation read model and semantic helpers

- Status: COMPLETE
- Commit SHA: `ff25b491`
- Important files changed: `lib/service/sync/annotation_read_model.dart`,
  `lib/service/sync/annotation_projection_reconciler.dart`,
  `lib/service/sync/annotation_repository.dart`,
  `lib/service/sync/legacy_annotation_bootstrap.dart`, and
  `test/service/sync/annotation_read_model_test.dart`
- Architectural decisions made: `CanonicalAnnotationReadAdapter` is a one-way
  typed view with no reverse serialization API. `AnnotationRef` combines the
  canonical MD5 book fingerprint and annotation UUID. Enrichment payloads are
  recursively read-only so future protocol fields remain inspectable without
  becoming a second serializer. Tombstones participate in the effective
  personal-note winner before an active value is selected. Navigation and
  rendering capabilities are separate and never control annotation visibility.
  Local presentation is an optional injected value until M4E.2 persists it.
- Tests run: `dart format` on all touched Dart files; `flutter analyze` on all
  touched production/test Dart files (no issues); `flutter test` for
  `annotation_read_model_test.dart`, `annotation_protocol_test.dart`,
  `annotation_projection_reconciliation_test.dart`, and
  `annotation_repository_test.dart` (44 passed); `flutter test` for
  `annotation_protocol_fixture_test.dart` and
  `annotation_mutation_boundary_test.dart` (34 passed); final focused
  `annotation_read_model_test.dart` run after tie-break coverage (8 passed).
- Discovered limitations or follow-up work: Book availability is supplied by
  the caller because the canonical document deliberately has no local catalog
  binding. The adapter currently carries an optional presentation value; M4E.2
  must supply effective defaults and durable sidecar reads. The existing native
  projection remains in place until later phases.
- Acceptance checklist:
  - [x] Add `AnnotationRef` and a typed UI/read model.
  - [x] Centralize tombstone, active enrichment, effective personal-note,
    supported EPUB CFI selector, and capability semantics.
  - [x] Include local presentation through an injected/read-only boundary.
  - [x] Preserve unknown protocol fields and selectors.
  - [x] Add focused tests.

### M4E.2 — Local annotation presentation sidecar

- Status: COMPLETE
- Commit SHA: `45a4255b`
- Important files changed: `lib/service/sync/shared_state_database.dart`,
  `lib/service/sync/annotation_repository.dart`,
  `lib/service/sync/annotation_projection_reconciler.dart`,
  `test/service/sync/shared_state_database_test.dart`,
  `test/service/sync/annotation_repository_test.dart`, and
  `test/service/sync/annotation_projection_reconciliation_test.dart`
- Architectural decisions made: Shared-state schema v2 adds the local-only
  `annotation_presentations` table keyed solely by canonical annotation UUID.
  The table stores only highlight/underline style and color, has no canonical
  document foreign key or outbox path, and stores no semantic timestamp. New
  selections write canonical state first and then their sidecar. Presentation
  edits update the sidecar and native compatibility projection without touching
  canonical bytes. Reconciliation treats the sidecar as authoritative, performs
  a one-time migration from an existing bound `BookNote` when the sidecar is
  absent, and otherwise applies current Anx preferences without persisting a
  default. Tombstones remove their orphaned local presentation.
- Tests run: `dart format` on all touched Dart files; targeted `flutter analyze`
  on all touched production/test files (no issues); focused `flutter test` for
  `shared_state_database_test.dart`, `annotation_repository_test.dart`,
  `annotation_projection_reconciliation_test.dart`, and
  `annotation_read_model_test.dart` (53 passed); full `flutter test
  test/service/sync` including protocol conformance, repository, synchronization,
  runtime, renderer refresh, and WebDAV transport coverage (161 passed).
- Discovered limitations or follow-up work: Native `BookNote.type/color` remains
  a compatibility mirror until the direct renderer and legacy-removal phases.
  Bookmark percentage remains in that compatibility row and is intentionally
  not modeled as highlight presentation; its final navigation representation
  must be resolved during M4E.8/M4E.10. Existing presentation migration occurs
  when a bound representable annotation is reconciled, because the physically
  separate shared-state schema migration cannot directly read the app database.
- Acceptance checklist:
  - [x] Persist highlight/underline and color locally by annotation UUID.
  - [x] Apply current Anx preferences when no sidecar exists.
  - [x] Ensure presentation writes do not alter canonical bytes, revisions, or
    semantic timestamps.
  - [x] Migrate relevant existing local presentation.
  - [x] Add migration and repository tests.

### M4E.3 — Explicit SelectionSession state machine

- Status: COMPLETE
- Commit SHA: `16108268`
- Important files changed: `assets/foliate-js/src/selection-session.mjs`,
  `assets/foliate-js/src/book.js`, `assets/foliate-js/dist/bundle.js`,
  `assets/foliate-js/test/selection-session.test.mjs`,
  `assets/foliate-js/package.json`,
  `lib/page/book_player/selection_session_bridge.dart`,
  `lib/page/book_player/epub_player.dart`,
  `lib/widgets/context_menu/context_menu.dart`,
  `lib/widgets/context_menu/excerpt_menu.dart`,
  `test/page/book_player/selection_session_bridge_test.dart`, and
  `test/service/sync/annotation_mutation_boundary_test.dart`.
- Architectural decisions made: JavaScript owns one reader-wide
  `SelectionSessionMachine` with explicit `IDLE`, `SELECTED`, and
  `ACTIONS_VISIBLE` states, a monotonic generation, content-document ownership,
  and a stable DOM Range key. `selectionchange` only creates or updates the
  session and sends `onSelectionChanged`; it never requests actions. A
  capture-phase `pointerdown` records generation, Range, and client-rect hit
  testing before native selection processing, while an unchanged matching
  `pointerup` toggles actions. Flutter mirrors only the current generation to
  reject stale bridge work and tags each transient `OverlayEntry` with its
  generation. Selection overlays and rendered-annotation overlays therefore
  use separate lifetimes. Menu dismissal sends `hideSelectionActions` and does
  not clear the DOM Range. `autoMarkSelection` no longer creates an annotation
  merely by opening transient actions; annotation creation remains behind an
  explicit menu mutation. Existing paginated auto-page behavior remains in
  place; stopping a selection now minimally increments its existing auto-page
  session counter so an already-running continuation is invalidated.
- Tests run: `npm test` in `assets/foliate-js` (7 passed); configured `npm run
  build` (Webpack succeeded and rebuilt `dist/bundle.js`, with the same three
  top-level-await target warnings); Dart formatting on all touched Dart files;
  targeted `flutter analyze` on the player, menu, bridge, and tests (no issues);
  `flutter test test/page/book_player/selection_session_bridge_test.dart
  test/service/sync` (168 passed). `package.json` has no configured lint script,
  so no unconfigured JS lint command was invented.
- Discovered limitations or follow-up work: The repository has no DOM/WebView
  integration-test harness, so Android pointer ordering is covered by the pure
  state-machine/bridge tests plus the built integration, not an automated
  device gesture test. Capture-phase hit testing is deliberately narrow and no
  pointer/touch event is blanket-prevented; if an inside tap collapses the Range
  before `pointerup`, only that saved matching Range is restored. Full
  cross-page auto-page timer/race regression remains M4E.4.
- Acceptance checklist:
  - [x] New/changed selections leave actions hidden.
  - [x] Tapping inside the selection toggles actions.
  - [x] Tapping outside clears selection and ends the session.
  - [x] Hiding actions does not clear selection.
  - [x] No Flutter overlay or timer can outlive its session.
  - [x] Remove obsolete selection clear lock/pending mechanisms.
  - [x] Add practical state-machine and bridge tests.

### M4E.4 — Preserve cross-page selection

- Status: COMPLETE
- Commit SHA: `df3bf5c5`
- Important files changed: `assets/foliate-js/src/auto-page-selection.mjs`,
  `assets/foliate-js/src/selection-session.mjs`,
  `assets/foliate-js/src/book.js`, `assets/foliate-js/dist/bundle.js`, and
  `assets/foliate-js/test/auto-page-selection.test.mjs`.
- Architectural decisions made: `SelectionSessionMachine` remains the only
  monotonic selection-lifetime authority. A per-view
  `AutoPageSelectionCoordinator` captures the active content `Document` and
  SelectionSession generation for the boundary-delay timer, `view.next()`, its
  guarded completion work, and every post-next selection recheck. It has no
  independent session counter. Cancellation removes scheduled work, while
  captured work identity plus owner/generation validation makes an uncancellable
  stale callback harmless. Page-key replacement cancels an advance that has not
  begun and cancels obsolete rechecks; relocation emitted while `view.next()` is
  already running may finish only for its still-active generation. Explicit
  clear invalidates the session before DOM deselection, `pagehide` invalidates
  the owning document, and loading a replacement content document ends the old
  session. Starting range adjustment immediately hides actions and resets
  pending auto-page work without preventing native pointer behavior.
- Tests run: configured `npm test` in `assets/foliate-js` passed both test files
  (19 focused subtests when run directly: 12 auto-page and 7 normal
  SelectionSession tests); configured `npm run build` succeeded and rebuilt
  `dist/bundle.js` with the same three top-level-await target warnings; targeted
  `flutter analyze` on `selection_session_bridge.dart`, `epub_player.dart`, and
  the bridge test found no issues; focused `flutter test` for
  `selection_session_bridge_test.dart` passed all 5 tests. `package.json` has no
  lint script, so no unconfigured lint command was invented.
- Discovered limitations or follow-up work: Automatic selection advancement is
  supported across visual pages in paginated mode only while the selection is
  backed by one live content `Document`/EPUB section. A DOM `Range` is not
  preserved across separate EPUB spine documents; loading the replacement
  document explicitly ends the session. Automated tests exercise the pure
  coordinator rather than real Android WebView native-handle gestures.
- Acceptance checklist:
  - [x] Preserve boundary-triggered page advancement in paginated mode.
  - [x] Keep actions hidden during drag/selection changes.
  - [x] Scope pending page work to the active session.
  - [x] Cover stale timer/new-selection/clear-selection races.

### M4E.5 — Sentence-aware annotation context

- Status: COMPLETE
- Commit SHA: `247ee365`
- Important files changed: `assets/foliate-js/src/sentence-context.mjs`,
  `assets/foliate-js/src/book.js`, `assets/foliate-js/dist/bundle.js`,
  `assets/foliate-js/test/sentence-context.test.mjs`,
  `lib/page/book_player/epub_player.dart`, the selection context-menu widgets,
  `test/page/book_player/selection_session_bridge_test.dart`,
  `test/service/sync/annotation_mutation_boundary_test.dart`, and
  `test/service/sync/annotation_repository_test.dart`.
- Architectural decisions made: A pure sentence-context module reconstructs
  the live content-document text around a DOM Range and uses
  `Intl.Segmenter` with sentence granularity and the document language when
  available. A deterministic local punctuation scanner handles `.`, `?`, `!`,
  `…`, punctuation runs, closing quotes, and closing brackets when
  `Intl.Segmenter` is unavailable or fails; Intl output is narrowly refined for
  the single ellipsis glyph because some implementations do not end a sentence
  there. Whitespace is collapsed without case-folding or otherwise rewriting
  lexical content. `annotationContext` is the normalized smallest complete
  sentence span containing the selection and is passed only to explicit
  annotation creation. `lookupContext` is the normalized previous sentence,
  containing span, and next sentence when available; it remains in the
  generation-bound SelectionSession/menu/provider path and translation now
  consumes it. The stable payload also carries selected text, chapter, CFI,
  and geometry. Protocol v2 and existing annotation bytes are unchanged.
- Tests run: configured `npm test` in `assets/foliate-js` passed all three test
  files (19 focused sentence-context subtests plus the existing 12 auto-page
  and 7 SelectionSession subtests); configured `npm run build` succeeded and
  rebuilt `dist/bundle.js` with the same three top-level-await target warnings;
  Dart formatting covered all touched Dart files; targeted `flutter analyze`
  on the player, menus, and touched tests found no issues; focused `flutter
  test` for the bridge, mutation boundary, and repository passed 23 tests; and
  `flutter test test/page/book_player/selection_session_bridge_test.dart
  test/service/sync` passed 171 tests. `package.json` has no lint script, so no
  unconfigured lint command was invented.
- Discovered limitations or follow-up work: The fallback is intentionally a
  punctuation heuristic rather than a linguistic parser and may split unusual
  abbreviations differently from `Intl.Segmenter`. Context is limited to the
  current live content document; it does not claim sentence neighbors across
  EPUB spine documents. The repository has no DOM/WebView integration harness,
  so Range-to-document reconstruction is covered through the pure module,
  bridge tests, and built integration. Existing annotations without context
  are deliberately not backfilled or rewritten. There is no intentional
  semantic difference from Lingua Reader's compact persisted versus wider
  provider-context split.
- Acceptance checklist:
  - [x] Replace character-window persistence with robust sentence segmentation
    plus fallback.
  - [x] Avoid duplication for full-sentence selections after whitespace and
    terminal-punctuation normalization.
  - [x] Keep multi-sentence persisted context to the smallest meaningful span.
  - [x] Provide wider transient provider context separately.
  - [x] Test word, phrase, clause, sentence, punctuation omission,
    multi-sentence selection, and whitespace normalization.

### M4E.6 — Simplified transient lookup UX

- Status: COMPLETE
- Commit SHA: `d32f6afd`
- Important files changed: `lib/page/book_player/selection_persistence_session.dart`,
  the context/excerpt/translation/personal-note menu widgets,
  `lib/service/sync/annotation_repository.dart`,
  `test/page/book_player/selection_persistence_session_test.dart`,
  `test/service/sync/annotation_repository_test.dart`, and
  `test/service/sync/annotation_mutation_boundary_test.dart`.
- Architectural decisions made: One `SelectionPersistenceSession` owns the
  immutable selection snapshot, transient translation/dictionary/AI state,
  and a nullable canonical `AnnotationRef`. Its serialized `ensureAnnotation`
  gate creates at most once, including concurrent explicit actions, and never
  searches by CFI. Existing rendered annotations resolve their temporary
  native compatibility handle to their exact canonical identity. AI, the
  official Google Translate app, external Dictionary, and internal translation
  are primary transient actions; internal translation renders an explicit Save
  affordance. Personal-note editor opening is read-only and only its Save
  callback creates/updates canonical state. Explicit highlight/underline/color
  remains persistent intent. Copy, web search, narration, and Share moved to a
  compact overflow. Semantic first saves do not persist effective presentation
  defaults. `lookupContext` is passed to translation only; annotation creation
  receives the compact `annotationContext`.
- Tests run: Dart formatting on all touched Dart files; targeted `flutter
  analyze` on all touched production/test files (no issues); focused selection
  persistence/session/repository/mutation-boundary tests; full `flutter test
  test/service/sync` (167 passed), including protocol conformance, deterministic
  merge, synchronization, runtime, renderer-refresh, and WebDAV coverage.
- Discovered limitations or follow-up work: External Android Dictionary and
  Google Translate app integrations cannot return provider payloads to Anx, so
  they remain transient launch actions without an in-app Save result. AI chat
  remains transient from the annotation repository's perspective; canonical
  AI analysis/thread Save APIs are introduced in M4E.7. The live menu retains a
  native BookNote ID only as a documented compatibility handle until M4E.7.
- Acceptance checklist:
  - [x] Present AI, Translate, Dictionary, Personal note, and presentation as
    primary selection actions.
  - [x] Keep provider results/errors transient until explicit save.
  - [x] Store an `AnnotationRef` in the session after first save and reuse it
    for later saves in that session.
  - [x] Never find/reuse annotations by CFI.
  - [x] Add lookup/no-write and save/reuse tests.

### M4E.7 — Canonical enrichment mutation API

- Status: COMPLETE
- Commit SHA: `486c62f0`
- Important files changed: `lib/service/sync/annotation_repository.dart`,
  `lib/service/sync/annotation_projection_reconciler.dart`,
  `lib/page/book_player/selection_persistence_session.dart`, context-menu
  persistence consumers, the bookmark compatibility consumer, and focused
  repository/mutation/renderer-refresh tests.
- Architectural decisions made: `createAnnotation` returns a canonical
  `AnnotationRef`; translation, dictionary, AI analysis, AI thread,
  personal-note, tombstone, and presentation mutations take `AnnotationRef`.
  `createAnnotationWithTranslation` and
  `createAnnotationWithPersonalNote` commit the new selection and first
  enrichment in one canonical revision. `SelectionPersistenceSession` owns no
  native identity and its first-save gate serializes creation while ensuring a
  concurrent later action targets the resulting ref. Material enrichments use
  UUID identities; the owned personal note retains its deterministic
  annotation-derived identity and tombstone semantics; AI threads/messages use
  UUID identities and protocol-v2 fields. Repository mutations patch the
  protocol-owned document in place, preserving unknown fields/selectors.
  `AnnotationMutationResult` separates canonical success from the following
  compatibility renderer/projection refresh and returns any refresh failure
  without throwing or rolling back canonical data. Reconciliation invoked by
  the canonical API suppresses legacy presentation migration so effective
  defaults are not misclassified as explicit style. Presentation writes use
  the sidecar only and preserve canonical bytes, revision, and semantic time.
  Native-ID/BookNote mutation entrypoints are explicitly named/documented as
  compatibility APIs; the active selection save workflow no longer uses them.
- Tests run: Dart formatting on all touched Dart files; targeted `flutter
  analyze` on 12 production/test files (no issues); focused canonical API,
  selection-persistence, and mutation-boundary tests; final combined `flutter
  test --no-pub test/page/book_player/selection_persistence_session_test.dart
  test/page/book_player/selection_session_bridge_test.dart test/service/sync`
  (190 passed). This includes protocol fixtures/conformance, deterministic
  merge, unknown-field retention, synchronization/runtime, canonical-before-
  refresh ordering, refresh failure durability, and WebDAV transport coverage.
- Discovered limitations or follow-up work: BookNote projection remains the
  temporary renderer payload until M4E.8, so resolving a tap on an existing
  rendered annotation still performs a compatibility native-ID-to-ref read.
  Bookmark and Notes-page consumers retain clearly named compatibility
  deletion/edit APIs for M4E.9/M4E.10. Renderer refresh failure is returned and
  logged; the current compact menu has no dedicated localized refresh-warning
  banner. Only the established protocol-v2 enrichment kinds are used.
- Acceptance checklist:
  - [x] Add canonical identity APIs for create, enrich, tombstone, and Anx
    presentation update.
  - [x] Commit canonical data before renderer/UI refresh.
  - [x] Report post-commit refresh failure as renderer/presentation failure.
  - [x] Remove native BookNote-ID semantic APIs as consumers migrate.
  - [x] Add mutation, durability, and failure-boundary tests.

### M4E.7a — Cross-device Anx presentation sync

- Status: COMPLETE
- Commit SHA: `5301d438`
- Important files changed: `lib/service/sync/annotation_presentation_protocol.dart`,
  `lib/service/sync/shared_state_database.dart`,
  `lib/service/sync/annotation_sync_coordinator.dart`,
  `lib/service/sync/annotation_sync_runtime.dart`,
  `lib/service/sync/annotation_repository.dart`, and focused presentation,
  database, coordinator, and repository tests under `test/service/sync/`.
- Architectural decisions made: Anx owns one separately serialized version-1
  presentation document at `anx/annotation-presentations.json`, stored under
  the independent `anx-annotation-presentations` shared-state domain. Entries
  are keyed only by canonical annotation UUID. Each explicit style/color update
  or reset carries an operation timestamp; the newer operation wins,
  canonical-JSON ordering resolves equal update/update values, and reset wins
  an exact update/reset tie. Reset records are retained even when this device
  has not seen an explicit value, preventing a stale remote value from being
  resurrected; a strictly later explicit update intentionally restores it.
  Missing/reset presentation means current Anx defaults and rendering never
  persists those defaults. Schema v3 migrates M4E.2 rows into this document and
  marks only its own durable revision dirty. The conditional WebDAV coordinator
  is domain/codec/path configurable, giving both domains the same single-flight,
  compare-and-set, ETag, first-create LOCK fallback, offline retry, and restart
  behavior without sharing bytes or outbox rows. Runtime status and lifecycle
  cover both coordinators, and remote presentation merges reconcile/refresh the
  current temporary native renderer projection.
- Tests run: Dart formatting on all touched Dart files; targeted `flutter
  analyze` on the nine touched production/test files (no issues); focused
  presentation protocol, shared-state, coordinator, and repository tests (81
  passed); full `flutter test --no-pub test/service/sync` (183 passed), including
  protocol fixtures/conformance, restart, two-device update/reset convergence,
  offline durability, conditional WebDAV behavior, and canonical protocol
  isolation.
- Discovered limitations or follow-up work: Merge order uses device wall-clock
  timestamps because the M4E.2 sidecar had no logical clock; badly skewed clocks
  can delay a later real-world operation until its timestamp is exceeded. The
  one-time sidecar migration necessarily uses migration time for previously
  timestamp-free values. Reset records and the single global document have no
  compaction policy yet. The legacy physical `annotation_presentations` table
  remains only as a schema-migration source until M4E.10. Lingua Reader is not
  required to understand or mutate this Anx-only domain.
- Acceptance checklist:
  - [x] Migrate the M4E.2 local sidecar into a synchronizable Anx domain.
  - [x] Add deterministic update/reset convergence and tombstone safety.
  - [x] Keep presentation dirty/outbox state independent from canonical state.
  - [x] Cover restart, two-device, offline, convergence, and protocol isolation.

### M4E.8 — Direct Foliate annotation renderer adapter

- Status: COMPLETE
- Commit SHA: `30121b6e`
- Important files changed:
  `lib/page/book_player/foliate_annotation_adapter.dart`,
  `lib/page/book_player/epub_player.dart`, the context-menu bridge and refresh
  callers, `assets/foliate-js/src/annotation-renderer-identity.mjs`,
  `assets/foliate-js/src/view.js`, `assets/foliate-js/src/book.js`, rebuilt
  `assets/foliate-js/dist/bundle.js`, and focused Dart/JavaScript bridge tests.
- Architectural decisions made: `EpubPlayer` now reads the canonical book
  document and synchronized Anx presentations, creates one-way
  `AnnotationUiModel` values, and maps only render-capable active annotations
  through ephemeral `FoliateAnnotationDto`. The DTO uses
  `SharedAnnotation.id` as both its string `id` and independent `renderKey`;
  EPUB CFI remains navigation/range data and is never identity. Foliate's
  overlayer now adds, removes, and hit-tests by `renderKey`, while its reader
  resolves that key through the UUID map. Same-CFI annotations therefore remain
  separately indexed instead of overwriting the overlayer solely by CFI.
  Selection annotations combine explicit Anx presentation with current defaults
  at adaptation time without persisting defaults; bookmark motivation maps to
  Foliate's bookmark rendering separately. Renderer taps return the canonical
  UUID, Flutter constructs `AnnotationRef` directly, and the context menu seeds
  `SelectionPersistenceSession` with that ref. It never resolves a native ID or
  searches by CFI. Rendered taps continue through `onAnnotationClick`, wholly
  separate from DOM selection and `onSelectionActionsRequested`. Incremental
  native payload writes/removes were replaced with a canonical snapshot refresh.
- Tests run: Dart formatting on all touched Dart files; targeted `flutter
  analyze` on the nine touched production/test files (no issues); combined
  adapter, selection-session, bridge, and complete sync regression run via
  `flutter test --no-pub ... test/service/sync` (201 passed); configured Foliate
  `npm test` (40 passed, including same-CFI UUID render-key coverage); configured
  `npm run build` succeeded and rebuilt `dist/bundle.js` with the same three
  top-level-await target warnings. `package.json` still has no lint script, so
  no unconfigured JavaScript lint command was invented.
- Discovered limitations or follow-up work: Two annotations with identical
  ranges are independently represented and never identity-collapsed, but their
  visual geometry overlaps and Foliate hit testing returns the overlay entry at
  the tapped paint position; there is not yet a chooser for coincident marks.
  Unsupported selectors remain canonical and visible to future canonical Notes
  UI but are intentionally absent from Foliate. Bookmark and existing personal-
  note/editor UI still use named native compatibility paths until M4E.9/M4E.10,
  though the renderer and renderer-tap identity no longer do. There is no
  automated Android WebView gesture harness for a real overlay tap.
- Acceptance checklist:
  - [x] Render canonical annotation plus effective Anx presentation without
    `BookNote`.
  - [x] Resolve renderer hit testing to `AnnotationRef`.
  - [x] Keep rendered-annotation taps distinct from DOM Range selections.
  - [x] Add adapter and bridge verification.

### M4E.9 — Migrate Notes UI to canonical state

- Status: NOT STARTED
- Commit SHA: —
- Important files changed: —
- Architectural decisions made: UI keys/multiselect use canonical UUIDs;
  semantic fields are canonical and style/color comes from the sidecar.
- Tests run: —
- Discovered limitations or follow-up work: Remote book catalog work is not in
  scope. Unsupported/unbound annotations remain visible with capability-aware
  navigation.
- Acceptance checklist:
  - [ ] Migrate per-book and reading-page Notes lists, tiles, details/editing,
    personal notes, selection, deletion, navigation, export, statistics, and
    filtering.
  - [ ] Distinguish bookmark motivation from local presentation filtering.
  - [ ] Keep annotations visible when the renderer cannot materialize them.
  - [ ] Add provider/UI tests where practical.

### M4E.10 — Remove BookNote and native projection infrastructure

- Status: NOT STARTED
- Commit SHA: —
- Important files changed: —
- Architectural decisions made: Retain only the migration/read compatibility
  required to bootstrap existing installations into canonical state plus the
  local sidecar; stop all legacy writes afterward.
- Tests run: —
- Discovered limitations or follow-up work: Audit every `BookNote`, numeric note
  ID, `readerNote`, `sharedAnnotationId`, projection table/hash/status, and DAO
  reference before removal.
- Acceptance checklist:
  - [ ] Complete any final legacy-row bootstrap/migration.
  - [ ] Remove `BookNote`, annotation DAO paths, projection reconciler/store,
    projection metadata, and native annotation identity.
  - [ ] Remove dead compatibility-only APIs.
  - [ ] Document anything intentionally retained.
  - [ ] Run repository-wide legacy-reference audit and tests.

### M4E.11 — Final regression and architecture verification

- Status: NOT STARTED
- Commit SHA: —
- Important files changed: —
- Architectural decisions made: M4E is COMPLETE only when all earlier phases
  and the complete cross-cutting verification matrix pass.
- Tests run: —
- Discovered limitations or follow-up work: —
- Acceptance checklist:
  - [ ] Selecting/changing text creates no annotation and never auto-opens
    actions; inside/outside taps and stale callbacks obey the session model.
  - [ ] Transient translation/dictionary/AI create no annotation.
  - [ ] First save creates exactly one UUID and later session saves reuse it.
  - [ ] Personal notes and remote enrichments are canonical and visible.
  - [ ] Presentation is local, defaults correctly, and never dirties canonical
    bytes.
  - [ ] Same-CFI annotations remain distinct; unsupported/unbound annotations
    remain visible; tombstones remain sticky.
  - [ ] Canonical mutation survives renderer refresh failure.
  - [ ] Persisted and lookup sentence contexts have the required behavior.
  - [ ] Paginated auto-page selection and renderer UUID hit testing work.
  - [ ] Protocol-v2 conformance and existing sync/WebDAV behavior pass.
  - [ ] Run applicable Dart formatting, Flutter analysis/tests, Foliate JS
    tests/lint/build, protocol/conformance tests, and sync tests using configured
    repository commands.

## Overall milestone status

- Status: IN PROGRESS
- Completed submilestones: 9 of 12 implementation phases
- Branch readiness: Not ready to merge

## Current checkpoint

Last completed submilestone: M4E.8 — Direct Foliate annotation renderer adapter
Current branch: `feature/m4e-canonical-annotation-ux`
Last implementation commit: `30121b6e refactor: render canonical annotations in Foliate`
Documentation checkpoint: The current commit records the completed M4E.8
implementation SHA and handoff
Repository state: Clean at the completed M4E.8 documentation checkpoint
Next submilestone: M4E.9 — Migrate Notes UI to canonical state
Next concrete tasks: Inventory every Notes/bookmark provider, list/tile/detail,
editor, multiselect, delete, navigation, export, statistics, and filtering
consumer; replace `BookNote`/numeric identity with `AnnotationUiModel` and
`AnnotationRef`; keep unsupported/unbound annotations visible with explicit
capabilities; distinguish bookmark motivation from presentation filters; move
personal-note reads/edits and reader-note opening to canonical enrichments; add
provider/UI coverage before removing compatibility infrastructure in M4E.10.
Known failing tests: None
Known limitations: Presentation LWW uses wall-clock timestamps and retains
reset records without compaction. Coincident renderer ranges have distinct UUID
identity but no visual chooser. Notes/bookmark/editor callers retain named
native compatibility APIs for M4E.9/M4E.10. External provider apps do not return
a savable result. Automated tests do not synthesize real Android WebView native-
handle or overlay-tap gestures. Local `develop` still has the previously
documented divergence from `origin/develop`.
Important files to inspect next: `lib/providers/book_notes.dart`,
`lib/providers/bookmark.dart`, `lib/widgets/book_notes/`, reader-note/context
menu widgets, export/statistics code, `lib/dao/book_note.dart`, and every
remaining `BookNote`, numeric note ID, or compatibility repository API caller.

### M4E.3 discovered pre-implementation lifecycle

- Every loaded Foliate content document installs independent selection listeners.
  `selectionchange`, platform-specific `pointerup`/`pointercancel`, and
  `contextmenu` debounce paths eventually call `handleSelection`, which builds
  the Range/CFI/text payload and sends `onSelectionEnd`.
- Flutter treats every `onSelectionEnd` as a menu request: it removes the
  current `OverlayEntry` and immediately calls `showContextMenu`. On Android,
  the native context-menu callback additionally invokes `window.showContextMenu`
  immediately and once more after 250 ms.
- A collapsed DOM selection sends unscoped `onSelectionCleared`. Flutter may
  defer it behind `_selectionClearLocked`/`_selectionClearPending`; overlay
  disposal, reader-note visibility, and excerpt editing manipulate that lock.
  Closing the overlay calls `clearSelection()`, so hiding actions and clearing
  selection are currently the same operation.
- Android intentionally relies on native selection handles: `pointercancel`
  marks entry into native selection mode, `selectionchange` is debounced because
  native handles may swallow terminal pointer events, and `contextmenu` is
  narrowly prevented to suppress the WebView menu. Paginated auto-page
  selection has a separate numeric session and several timers.
- Rendered annotation interaction is distinct: overlayer capture-phase hit
  testing emits `show-annotation`, then `onAnnotationClick`; it does not use the
  transient DOM-selection bridge.
- `showContextMenu` can currently auto-create a canonical annotation when
  `autoMarkSelection` is enabled, meaning merely opening transient selection UI
  can mutate the annotation repository.
