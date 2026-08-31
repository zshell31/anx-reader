# M4E — Canonical Annotation UX, BookNote Removal, and Selection Workflow

> Follow-up work replacing fragmented enrichment actions with one draft-first
> editor is checkpointed in [UNIFIED_ANNOTATION_EDITOR.md](UNIFIED_ANNOTATION_EDITOR.md).
> That document is not a redesign of the completed M4E architecture.

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

- Status: COMPLETE
- Commit SHA: `b763440f`
- Important files changed: `lib/service/sync/annotation_catalog.dart`,
  `lib/providers/book_notes.dart`, `lib/models/book_notes_state.dart`,
  `lib/widgets/book_notes/`, `lib/page/book_notes_page.dart`,
  `lib/page/home_page/notes_page.dart`, `lib/widgets/reading_page/notes_widget.dart`,
  `lib/widgets/context_menu/`, `lib/providers/bookmark.dart`,
  `lib/service/notes/export_notes.dart`, Notes statistics/search/random-highlight
  consumers, and the corresponding provider/repository/boundary tests.
- Architectural decisions made: The inventory covered the per-book, home, and
  reading-page Notes lists; tiles/details; reader-note editor; selection and
  multiselect deletion; bookmark creation/removal; navigation; export;
  statistics/counts; search and AI Notes search; random highlights; and
  semantic/presentation filtering. All now read immutable `AnnotationUiModel`
  projections directly from canonical documents through
  `CanonicalAnnotationCatalog`. UI keys and multiselect sets use canonical
  UUIDs, while mutations use `AnnotationRef`. Personal notes are canonical
  enrichments, bookmark filtering uses canonical motivation, and style/color
  filtering uses effective synchronized Anx presentation. Same-CFI entries are
  never collapsed. Catalog refresh listens to canonical semantic/presentation
  changes. Remote-only, unbound, and unsupported-selector annotations remain
  visible and exportable; navigation alone is disabled when capability or a
  local binding is unavailable. No fake local-book binding or shared-library
  catalog was introduced.
- Tests run: Dart generation/formatting succeeded; full `flutter analyze` had
  no errors (46 existing informational lints), and targeted analysis of the
  final changed UI/catalog/export files reported no issues. The combined
  selection/provider and complete `test/service/sync` Flutter run passed 200
  tests. Focused catalog/state/mutation/navigation coverage passed 11 tests.
  Foliate `npm test` passed 40 tests and `npm run build` succeeded with the
  three previously documented top-level-await target warnings.
- Discovered limitations or follow-up work: The repository-wide post-migration
  audit found no active user-facing `BookNote`, numeric-note-ID, `readerNote`,
  `sharedAnnotationId`, or DAO semantic consumer. Remaining references are
  confined to `lib/models/book_note.dart`, `lib/dao/book_note.dart`, legacy
  bootstrap, native projection/reconciliation, compatibility sections of the
  annotation repository, projection metadata in the shared-state database, and
  their startup/sync callbacks. They are retained only so M4E.10 can replace
  legacy-installation bootstrap safely before removing the entire runtime
  projection stack. Remote shared-library/catalog discovery remains outside
  M4E; canonical documents already present locally are preserved and shown.
- Acceptance checklist:
  - [x] Migrate per-book and reading-page Notes lists, tiles, details/editing,
    personal notes, selection, deletion, navigation, export, statistics, and
    filtering.
  - [x] Distinguish bookmark motivation from local presentation filtering.
  - [x] Keep annotations visible when the renderer cannot materialize them.
  - [x] Add provider/UI tests where practical.

### M4E.10 — Remove BookNote and native projection infrastructure

- Status: COMPLETE
- Commit SHA: `e2d1e85b`
- Important files changed: removed `lib/models/book_note.dart`,
  `lib/dao/book_note.dart`, `annotation_projection_reconciler.dart`, and
  `native_annotation_projection.dart`; added the read-only
  `legacy_annotation_store.dart`; simplified `legacy_annotation_bootstrap.dart`,
  `annotation_repository.dart`, `annotation_sync_coordinator.dart`,
  `annotation_sync_runtime.dart`, `shared_state_database.dart`, startup/database
  restore hooks, and canonical statistics; replaced projection tests with
  `legacy_annotation_bootstrap_test.dart` and canonical repository/runtime
  boundary coverage.
- Architectural decisions made: `AnnotationRepository` now accepts explicit
  creation data or `AnnotationRef` and returns `AnnotationRef`; it has no app
  database, numeric annotation ID, native store, compatibility result, status,
  hash, or reconciler dependency. Canonical and presentation commits notify the
  direct UI/renderer paths only after durable writes. Sync invokes a generic
  document-change listener after a local merge and treats listener failure as
  independent from canonical/network convergence. Legacy `tb_notes` rows are
  enumerated through a read-only migration interface with no mutation methods.
  Durable receipts, a portable multi-field anchor, and an established canonical
  ID hint make import idempotent without CFI identity inference. Bootstrap never
  updates an existing canonical entity, honors canonical/receipt tombstones,
  and writes style/color only when no synchronized presentation update or reset
  already exists. Fresh shared-state schema v4 omits obsolete projection and
  sidecar tables; an upgraded database retains them physically for migration
  safety but exposes no active query/mutation API.
- Tests run: Dart formatting on all touched files; full `flutter analyze` with
  no errors and 42 pre-existing informational lints; combined complete
  `test/service/sync`, app database migration, canonical Notes/provider,
  SelectionPersistenceSession/SelectionSession, catalog, and Foliate adapter
  run (187 passed); focused post-notification bootstrap/runtime audit run (23
  passed); Foliate configured `npm test` (40 passed); and `npm run build`
  succeeded with the same three documented top-level-await warnings.
- Discovered limitations or follow-up work: Existing app databases deliberately
  retain `tb_notes` as read-only migration input, and upgraded shared-state
  databases may retain the obsolete physical projection and M4E.2 sidecar
  tables. They can be dropped in a later destructive schema cleanup after the
  legacy import horizon; no current repository, UI, renderer, or sync consumer
  depends on them.
- Pre-removal legacy-reference audit (2026-08-30):
  - REMOVE: `lib/models/book_note.dart`, `lib/dao/book_note.dart`,
    `native_annotation_projection.dart`,
    `annotation_projection_reconciler.dart`, every repository compatibility
    API/result/error that exposes a native row or numeric note ID, all startup,
    book-open, canonical-sync, and presentation-sync reconciliation callbacks,
    `AnnotationProjectionMetadata` plus its query/write APIs, projection status,
    hash, native-ID mapping, and the projection-focused tests. The remaining
    `ReadingTimeDao.selectTotalNumberOfNotes` query is also an active legacy
    annotation-table read and must move to the canonical catalog.
  - MIGRATION-ONLY: the physical app-database `tb_notes` table and its historical
    `reader_note`/`shared_annotation_id` columns; a minimal read-only row/store
    used by `LegacyAnnotationBootstrap`; durable import receipts including the
    already-deployed `anx-booknote-anchor-v1` source string; and the physical
    M4E.2 `annotation_presentations` table solely as schema-v3 migration input.
    Existing databases may retain the obsolete physical projection/sidecar
    tables for backward safety, but current-schema database creation and active
    runtime APIs must not depend on them.
  - UNRELATED / NOT AN ANNOTATION CONCERN: canonical UI names such as
    `BookNotesState`, `BookNotesList`, `BookNoteTile`, `book_notes.dart`, and the
    `book_notes_operations` hint; `ReaderNoteMenu` as the UI editor for canonical
    `personal-note`; generic `unsupported` statuses in dictionary, translation,
    file-import, PDF, and WebView code; `Set<int>` tag/group identities; and
    historical planning/issue documentation. No annotation-related
    `ValueKey(note.id)` remains.
- Acceptance checklist:
  - [x] Complete any final legacy-row bootstrap/migration.
  - [x] Remove `BookNote`, annotation DAO paths, projection reconciler/store,
    projection metadata, and native annotation identity.
  - [x] Remove dead compatibility-only APIs.
  - [x] Document anything intentionally retained.
  - [x] Run repository-wide legacy-reference audit and tests.

#### M4E.10 final legacy-reference audit

- Active exact `BookNote` model references: zero. Active legacy annotation-table
  reads outside migration: zero. Active legacy annotation-table writes: zero.
  Semantic native annotation IDs, projection reconciler/store, projection
  status/hash/error concepts, and projection metadata APIs: zero.
- Migration-only references: `legacy_annotation_store.dart` reads the physical
  `tb_notes` columns `reader_note` and `shared_annotation_id`; the latter is only
  a stable canonical-ID hint. `legacy_annotation_bootstrap.dart` retains the
  deployed receipt source strings `anx-booknote-anchor-v1` and
  `tb_notes-unsupported-v1`. `lib/dao/database.dart` retains the physical table,
  historical columns, and index; `database_migration_test.dart` verifies the v7
  to v8 migration. `shared_state_database.dart` can create
  `annotation_projections` only when tests/opening historical schema versions
  1–3 and can read `annotation_presentations` only during the v2-to-v3 schema
  migration. Schema v4 creates neither table.
- Non-runtime occurrences: boundary tests contain forbidden legacy spellings as
  negative assertions. Canonical UI names (`BookNotesState`, `BookNotesList`,
  `BookNoteTile`, and `book_notes.dart`) refer to the Notes feature/read model,
  not the removed semantic model. `ReaderNoteMenu` is the editor widget for the
  canonical `personal-note` enrichment. Historical milestone/issue documents
  remain historical.

### M4E.11 — Final regression and architecture verification

- Status: COMPLETE
- Commit SHA: `cba0b2f6`
- Important files changed:
  `test/service/sync/final_annotation_architecture_test.dart`,
  `test/service/sync/shared_state_database_test.dart`, and this document.
- Architectural decisions made: The final guard verifies the canonical Notes
  path, direct canonical renderer path, transient selection boundary,
  independent synchronized Anx presentation domain, migration-only physical
  legacy evidence, and reconciler-free document notification. Removed runtime
  types/services and physical legacy evidence are checked separately so an
  incidental import filename cannot broaden a migration allowlist. No final
  architecture redesign or protocol change was required.
- Schema-version anomaly: `currentSharedStateSchema.version` is 4. The only
  repository creator of shared-state schema v5 is the intentional
  `a newer unsupported schema fails without polluting a fresh open` test. It
  creates `newer.db` under a unique `Directory.systemTemp.createTemp` directory,
  closes the v5 handle, and asserts that opening that exact path through the v4
  production schema throws `UnsupportedError`. `sqflite_common` unconditionally
  prints `error ... during open, closing...` while closing that expected failed
  open; the message is therefore visible even when the expectation passes and
  Flutter exits zero. The strengthened test immediately opens a different fresh
  path as schema v4 in the same process, and teardown deletes the unique
  directory. Focused, focused-plus-schema, and two full-suite runs all behaved
  identically. There is no v5 production constant, stale fixture, shared test
  database, singleton/static schema state, order pollution, or persisted test
  state involved.
- Tests run:
  - Dart formatting check on both M4E.11 test files: 2 files, no changes.
  - Targeted `flutter analyze` on 24 core M4E production/test files: no issues.
  - Full `flutter analyze --no-pub`: 42 informational issues, zero errors and
    zero warnings. This is the same repository-wide count recorded at M4E.10;
    none is introduced by M4E.11. The reported lines in M4E-touched
    `reading_page.dart` and `settings_page/sync.dart` are pre-existing lines
    outside the M4E diffs.
  - Architecture plus shared-state schema tests: 25 passed.
  - Focused canonical sync/protocol/presentation/repository/catalog/bootstrap,
    Notes/provider, selection/session, Foliate adapter/bridge, and app database
    migration set: 194 passed.
  - Full `flutter test --no-pub`, twice from isolated test paths: 264 passed on
    each run.
  - Foliate configured `npm test`: 40 passed.
  - Foliate configured `npm run build`: succeeded; Webpack 5.99.7 emitted the
    same three known top-level-await target warnings (two for `src/book.js`, one
    for `src/view.js`). No JavaScript lint script exists, so none was invented.
- Discovered limitations or follow-up work: Physical legacy database tables
  remain migration-only input. Presentation ordering uses wall-clock
  timestamps, and presentation update/reset records have no compaction.
  Coincident annotation ranges have no chooser UI. External provider apps
  cannot return savable result payloads. Selection cannot span separate EPUB
  spine DOM documents. There is no automated Android native-handle gesture
  harness. These do not block M4E completion.
- Acceptance checklist:
  - [x] Selecting/changing text creates no annotation and never auto-opens
    actions; inside/outside taps and stale callbacks obey the session model.
  - [x] Transient translation/dictionary/AI create no annotation.
  - [x] First save creates exactly one UUID and later session saves reuse it.
  - [x] Personal notes and remote enrichments are canonical and visible.
  - [x] Presentation is local, defaults correctly, and never dirties canonical
    bytes.
  - [x] Same-CFI annotations remain distinct; unsupported/unbound annotations
    remain visible; tombstones remain sticky.
  - [x] Canonical mutation survives renderer refresh failure.
  - [x] Persisted and lookup sentence contexts have the required behavior.
  - [x] Paginated auto-page selection and renderer UUID hit testing work.
  - [x] Protocol-v2 conformance and existing sync/WebDAV behavior pass.
  - [x] Run applicable Dart formatting, Flutter analysis/tests, Foliate JS
    tests/lint/build, protocol/conformance tests, and sync tests using configured
    repository commands.

#### M4E.11 final architecture verification

The verified runtime flows are:

```text
AnnotationBookDocument
        ↓
SharedAnnotation
        ↓
AnnotationUiModel
        ↓
Notes / editor / export / statistics
```

```text
SharedAnnotation + AnxAnnotationPresentation
        ↓
FoliateAnnotationAdapter
        ↓
Foliate
```

```text
DOM Range
        ↓
SelectionSession
        ↓
transient lookup
        ↓ explicit persistence
SharedAnnotation
```

There is no active `SharedAnnotation -> BookNote -> runtime consumer` path and
no runtime dependency on `AnnotationProjectionReconciler` or a native
annotation projection store. Notes and renderer identity use the canonical
annotation UUID. Presentation remains an independently serialized and
synchronized Anx domain, outside protocol-v2 annotation bytes.

#### M4E.11 exact legacy-reference audit

- MIGRATION-ONLY: `lib/dao/database.dart` retains the physical `tb_notes`
  definition, historical `reader_note` and `shared_annotation_id` columns, and
  the v8 index/migration for installed databases.
- MIGRATION-ONLY: `legacy_annotation_store.dart` is the sole read-only adapter
  for those physical fields. Its API has no insert, update, delete, binding, or
  projection operation. `legacy_annotation_bootstrap.dart` retains the deployed
  `anx-booknote-anchor-v1` and `tb_notes-unsupported-v1` receipt sources and
  imports only into canonical/presentation state.
- MIGRATION-ONLY: `shared_state_database.dart` can create
  `annotation_projections` only when explicitly constructing historical schema
  versions 1–3 and reads `annotation_presentations` only while migrating schema
  v2 to the synchronized presentation document. Fresh schema v4 creates
  neither table and exposes no active API for either physical table.
- MIGRATION-ONLY TEST EVIDENCE: `database_migration_test.dart`,
  `legacy_annotation_bootstrap_test.dart`, and
  `shared_state_database_test.dart` construct historical fixtures. Boundary and
  architecture tests contain legacy spellings only as negative assertions.
- UNRELATED: `BookNotesState`, `BookNotesList`, `BookNoteTile`,
  `_editBookNote`, and `book_notes.dart` name the canonical Notes UI feature;
  `ReaderNoteMenu`/`reader_note_menu.dart` edit canonical `personal-note`;
  `Set<int>` occurrences are tag/group identities. Historical planning and
  milestone documentation describes the retired architecture.
- BUG / ACTIVE LEGACY DEPENDENCY: none. Exact searches found no active
  `BookNote`, `readerNote`, `sharedAnnotationId`, `nativeNoteId`, `bookNoteDao`,
  `AnnotationProjectionReconciler`, `NativeAnnotationProjectionStore`,
  `int noteId`, annotation-related `Set<int>`, or `ValueKey(note.id)` flow.

#### Manual Android/device verification checklist

Status: **MANUAL VERIFICATION REQUIRED**. Codex did not execute these checks.

1. Select a word; actions must stay hidden.
2. Adjust selection handles.
3. Extend selection across a visual paginated-page boundary.
4. Tap the selection to show actions.
5. Tap it again to hide actions without clearing the selection.
6. Tap outside to clear it.
7. Translate without Save; no annotation should appear.
8. Save a personal note or savable translation.
9. Change highlight/underline and color.
10. Restart the app and verify the annotation and presentation.
11. Sync to another Anx device and verify style/color.
12. Sync an annotation from Lingua Reader.
13. Verify it appears in Notes.
14. Open/tap an existing rendered annotation.
15. Edit its personal note.
16. Delete the annotation.
17. Perform an offline edit, reconnect, and sync.
18. Inspect an unbound/unsupported annotation where practical.

## Post-M4E stabilization review

- Status: COMPLETE
- Review date: 2026-08-30
- Scope: focused correctness and compatibility fixes after M4E completion. The
  canonical architecture, protocol-v2 schema version, UUID identity, merge
  rules, and presentation-domain separation remain unchanged.

### Findings addressed and commits

- `908d417a fix: align annotation enrichments across clients`
  - Anx material writes now use the shared semantic fields consumed by Lingua
    Reader. Translation writes `providerId`, `providerName`, and `translation`.
    Dictionary writes provider identity plus `markdown`, optional
    `translation`, and optional string metadata. AI analysis writes provider
    identity, optional top-level `translation`, and structured `commentary`
    (`translation`, `translationNotes`, `grammar`, and `usage` when present).
  - Legacy generic `content` remains readable/searchable for compatibility but
    is no longer the primary Anx wire payload for these three material kinds.
    `personal-note` and AI-thread message content retain their established
    protocol fields.
  - The read model exposes `content`, `translation`, `markdown`, `commentary`,
    `providerId`, and `providerName`. Search includes only known meaningful text
    fields and does not stringify arbitrary JSON. Unknown fields remain intact.
- `614d5843 fix: preserve canonical bookmark identity and progress`
  - Foliate removal is UUID-only. Flutter carries the current bookmark UUID
    from relocation state and JavaScript resolves deletion only through
    `annotationsById`; no deletion falls back to CFI. `annotationsByValue`
    remains only a rendering convenience and translation refresh now enumerates
    the UUID map so same-CFI entries are not collapsed.
  - Bookmark progress is stored as `target.progress.fraction`, validated in the
    inclusive range 0 through 1, exposed as `bookmarkPercentage`, and kept
    outside Anx presentation. Valid legacy bookmark percentages are recovered
    from the retired bookmark color column; invalid values are ignored safely.
- `9f597b24 fix: avoid transient selection persistence on delete`
  - Delete is absent for an unbound transient selection. Its defensive handler
    also closes without creating state when no `AnnotationRef` exists. Existing
    annotation deletion still writes a sticky UUID tombstone.
- `ad16be7b fix: preserve implicit annotation presentation defaults`
  - `localPresentation` remains the explicit synchronized value. One read-model
    resolver computes effective display presentation from that value or current
    Anx defaults. Renderer, filter, Notes tile, and editor use the resolver.
  - The Notes editor tracks personal-note and presentation changes separately;
    note-only edits never materialize current defaults. Explicit style/color
    changes remain stable when global defaults later change.
- `8c815b2c feat: save selection AI results to canonical annotations`
  - Only selection-originated `AiChatStream` instances receive an optional
    `SelectionAiPersistenceContext`. Their initial prompt includes selected text
    and transient `lookupContext`; opening, generation, and closing write no
    annotation.
  - Explicit Save Analysis persists `ai-analysis`; Save Conversation persists
    `ai-thread`. The first save uses the session creation gate and later saves
    reuse its exact `AnnotationRef`. Existing annotations are addressed by their
    supplied ref and same-CFI lookup is never performed. Ordinary reader AI chat
    remains a general chat without annotation persistence controls.
- `fdc4c0f6 fix: clarify canonical notes CSV export`
  - CSV now has separate `Motivation`, `Presentation`, and `Color` columns.
    It no longer silently changes the old `Type` column from
    highlight/underline/bookmark semantics to selection/bookmark semantics.
    Missing explicit presentation exports as blank rather than materializing an
    effective default.
- `6d9c6038 test: verify stabilization renderer identity`
  - Rebuilt the checked-in Foliate bundle and strengthened the architecture
    guard for UUID-only removal.

### Cross-client compatibility reference

Compatibility was verified against the current local Lingua Reader checkout at
commit `3678929d8db7eef1d0e91849ba88a59428c9ec99`, specifically
`src/annotations/types.ts`, `src/annotations/adapters.ts`, and representative
store/adapter fixtures. Its `MaterialAnnotationEnrichment` shape permits
provider identity, `content`, `translation`, `markdown`, structured
`commentary`, and string metadata. Its adapter projects translation from
`translation` or `commentary.translation`, dictionary articles from `markdown`,
and AI detail from `commentary`.

The copied minimal fixture at
`test/fixtures/lingua_annotation_book_v2.json` covers Lingua-created
translation, dictionary, and AI analysis plus unknown fields. Anx production
tests cover the inverse Anx-created payload expectations. Protocol-v2
`translation`, `dictionary`, `ai-analysis`, `personal-note`, and `ai-thread`
remain compatible; schema version remains 2. No shared-protocol ambiguity and
no Lingua Reader change were required.

### Verification

- Dart formatting was applied to every touched Dart file; final diff checks
  passed.
- Targeted Flutter analysis of each change set passed without errors. Full
  `flutter analyze --no-pub` reported the same 42 repository informational
  lints documented at M4E completion, with zero errors and zero warnings.
- Focused sync, protocol, repository, catalog, migration, selection,
  presentation, renderer, AI persistence, and stabilization coverage passed
  213 tests.
- Full `flutter test --no-pub` passed twice: 284 tests on each run.
- Foliate `npm test` passed 42 tests, including bookmark/highlight same-CFI
  removal in both directions. `npm run build` succeeded and rebuilt
  `dist/bundle.js`; Webpack emitted the same three known top-level-await target
  warnings. No JavaScript lint script exists, so none was invented.

### Remaining limitations

- Manual Android/device verification is still required; no device checks are
  claimed by this review.
- Unbound canonical documents are supported once discovered or imported.
  WebDAV listing/discovery for arbitrary remote-only books remains a later
  milestone and was intentionally not added here.
- The prior M4E limitations remain: presentation ordering uses device clocks
  and has no compaction, coincident marks have no chooser, external provider
  apps cannot return savable results, selection cannot span EPUB spine DOM
  documents, physical legacy tables remain migration-only input, and there is
  no automated Android native-handle gesture harness.

Overall milestone status: COMPLETE

Branch readiness: Ready for manual verification / merge review

## Additional stabilization: bilingual chapter-load reconciliation

- Status: AUTOMATED VERIFICATION COMPLETE; MANUAL DEVICE VERIFICATION REQUIRED
- Implementation commits:
  - `b663ea35 fix: reconcile bilingual translations on chapter load`
  - `072152c6 fix: bound translation reconciliation to visible pages`
  - `525b327e feat: prefetch translations for the next page`
  - `b5f9d1ab fix: serve foliate modules with JavaScript MIME type`
- Scope: post-review translation presentation/lifecycle and reader-bootstrap
  fixes. Translation request identity, previous-paragraph context, persistent
  cache schema, invalidation, and WebDAV synchronization semantics are
  unchanged.

### Diagnosed root cause

The failure was in current-document JavaScript presentation, not in cache
fingerprinting or synchronization:

1. `View.#onLoad` called `Translator.observeDocument(doc)`, which only walked
   the new document and registered eligible elements with the shared
   `IntersectionObserver`.
2. Forced visible-element translation ran for the transition from `OFF` to an
   enabled mode. A document loaded while `BILINGUAL` (or another enabled mode)
   was already active had no equivalent convergence pass.
3. If WebView did not deliver an initial intersecting transition for one
   already-visible element after iframe load/layout, that element could remain
   untranslated indefinitely. Remaining visible did not itself create another
   observer transition.
4. The Flutter coordinator can satisfy and persist a request before returning
   its result to JavaScript. The former JavaScript path then recorded the
   element as translated before applying its wrapper. A DOM-application failure
   at that point left successful state/cache with no wrapper, and later events
   returned early because the element was already marked translated.
5. A late chapter-A request could persist normally and finish against its old
   element after chapter B replaced the iframe. The B paragraph is a different
   element; without B reconciliation, A's success could not materialize B.
6. The global strong `observedElements` set retained every observed element
   until all translations were cleared or the view was destroyed, so replaced
   chapter documents accumulated for the lifetime of the open book.

This explains how a translation could exist in the local/synchronized cache
while the current DOM lacked `.translated-text`: cache completion precedes the
JavaScript DOM mutation, and cached request identity is independent of a
particular iframe element. WebDAV synchronization merely made the already
successful result available elsewhere; it was never a rendering repair.

### Lifecycle and convergence model

- `observeDocument(doc)` still registers eligible elements lazily with
  `IntersectionObserver`, preserving the 1280px near-viewport margin.
- It also schedules a document reconciliation after two
  `requestAnimationFrame` boundaries. The iframe load callback occurs before
  paginator rendering, so this is a deterministic post-render/layout boundary,
  not a fixed-delay heuristic. Reflowable content waits for the paginator's
  visible Range before this scheduled pass selects elements.
- `View.#onRelocate` explicitly reconciles every document currently returned by
  `renderer.getContents()` using the current visual Range plus one next-page
  prefetch Range. Relocation is the paginator's layout/anchor-complete boundary
  and also provides retry/convergence while paging within a chapter.
- Reconciliation checks relevant elements whether or not an observer callback
  was received. Existing successful JS state rematerializes or repairs the
  wrapper without calling Flutter. New state calls Flutter and then converges
  to exactly one direct `.translated-text` child with display semantics for
  `OFF`, `ORIGINAL_ONLY`, `TRANSLATION_ONLY`, or `BILINGUAL`.
- Translation input remains the frozen source text plus previous eligible
  paragraph text. No second cache key or alternate fingerprint was introduced.

### Opening-performance follow-up

Initial device feedback after `b663ea35` found that opening a book could appear
to hang. The first reconciliation implementation used iframe-local bounding
geometry to select relevant elements. In Foliate's reflowable paginator, the
iframe layout viewport spans the entire columnized chapter, while the outer
container scrolls between visual pages. Consequently, nearly every paragraph
could pass the geometry test and start a bridge request plus DOM reflow at once.

`072152c6` makes paginator DOM ranges authoritative for reflowable
reconciliation. Before the first relocation, explicit reconciliation starts no
geometry-derived bulk work; `IntersectionObserver` remains the lazy accelerator.
`525b327e` adds a bounded prefetch Range for exactly the next visual page. Each
relocation therefore reconciles the current page and one following page while
leaving the third and later pages lazy. Fixed-layout spreads continue using
geometry because their one- or two-document iframe viewport is meaningful.
This retains missed-callback convergence and smooth page turns while preventing
chapter-wide request and re-layout storms during book open.

### Repeated opening hang: strict ES-module MIME handling

A later real-device reproduction showed a separate opening failure that occurs
before EPUB parsing or translation reconciliation. Android WebView 151 loaded
`index.html` and part of the `book.js` module graph, then rejected every `.mjs`
dependency because the embedded Shelf server returned
`application/octet-stream`. The server recognized `.js`, but not `.mjs`.
WebView's strict module MIME checking rejected `auto-page-selection.mjs`,
`selection-session.mjs`, `sentence-context.mjs`, and
`annotation-renderer-identity.mjs`; the dynamically inserted `book.js` script
reported an error and never executed. Consequently `window.reader` remained
undefined, no EPUB request or translation request began, and the otherwise idle
WebView looked like a frozen book screen. There was no ANR, crash, or CPU-bound
translation loop.

`b5f9d1ab` centralizes Foliate asset MIME selection and serves both `.js` and
`.mjs` as `application/javascript`. This is a deterministic resource contract;
it adds no timeout, delay, or rendering retry. A focused Flutter test covers the
two JavaScript extensions plus the existing HTML, CSS, JSON, and binary
fallback mappings.

Device-side DevTools supplied before/after evidence on the same WebView 151:

- Before the fix, `document.readyState` was `complete`, `window.reader` was
  undefined, only the initial module subset appeared in resource timing, and
  DevTools logged four strict-MIME module failures.
- After installing the fixed release APK, all 17 JavaScript modules loaded,
  including `translator.js`; the EPUB and paginator requests completed;
  `window.reader` was an object; and the paginator owned one active content
  document. This verifies the opening-path repair, but is not the full
  bilingual navigation checklist below.

The same device session also explained one untranslated final visible
paragraph without confusing it with the DOM race: the paragraph intersected
the active paginator Range and had no wrapper, while WebView console recorded
`Failed host lookup: api.openai.com`. Wi-Fi was off. The network error remained
retryable and was not cached; after connectivity was restored and the book was
reopened, the user confirmed that the translation appeared. That successful
result is persisted under the existing text/context/book/provider/language
fingerprint, so later identical requests are local cache hits. This was a
focused failure/recovery observation, not completion of the navigation
checklist.

### In-flight, stale completion, cleanup, and retry strategy

- A `WeakMap<Element, Promise>` owns element-scoped in-flight work. Observer,
  load reconciliation, relocation reconciliation, and explicit mode enable all
  join the same operation, so one logical element has at most one concurrent
  bridge request. Dart's complete-request in-flight map remains a separate
  lower-level guarantee.
- Each observed document owns a strong set only of its current elements;
  element-to-document ownership is weak. On every renderer load, documents not
  present in `renderer.getContents()` are retired, their elements are
  unobserved, their strong set is cleared, and their document entry is removed.
  Fixed-layout spreads retain every document still owned by the renderer.
- A completion captures its starting document owner. If that owner was retired
  or the element was reassigned, the completion is discarded before changing
  JS success state or DOM. The underlying Flutter future is not cancellable,
  but chapter A cannot satisfy, block, or modify chapter B.
- Bridge throws, empty results, and error-shaped results do not become
  translated state. Transient failures can retry at a later lifecycle
  reconciliation. Authentication/configuration failures are quiescent for the
  current document so relocation cannot produce a tight retry loop; explicitly
  disabling/re-enabling translation or loading a new document permits retry
  after settings change.

### Never-settling provider streams and bounded translation scheduling

A later device reproduction isolated a second translation-specific liveness
failure after the MIME opening fix. One visible paragraph and one offscreen
paragraph were ordinary registered elements intersecting the correct paginator
Ranges, but both remained in JavaScript's private `#inFlightElements` map with
Promises that never settled. They were absent from success and failure state.
Repeated relocation and an `off -> bilingual` mode cycle therefore joined the
same Promises instead of starting replacement work.

The underlying Dart request chain first exposed that it had no liveness bound.
The global `FullTextTranslationCacheService._inFlight` correctly removed
requests in `finally`, but `TranslateServiceProvider.translateTextOnly` could
wait forever when a provider stream neither emitted, failed, nor closed.
Because the cache service and coordinator are process-wide singletons,
reopening the WebView could join the same never-completing request. This located
the defect below the bridge and ruled out a missed Range, stale DOM ownership,
cached error, or permanent-failure suppression; later live verification found
the final runner ownership cause described below.

`af60c5db` adds a 30-second per-attempt stream-inactivity contract. Timeout is
applied to the stream subscription, so leaving the `await for` cancels the
underlying subscription and reaches `CancelableLangchainRunner.onCancel`.
Existing retry behavior remains three attempts with 100/200 ms backoff; after
the final failure, the cache service's existing `finally` removes the complete
request from `_inFlight`. Timeout output is never persisted. A later identical
request can run normally and, when successful, persists under the unchanged
book/provider/language/prompt/source/context fingerprint.

`4c57d7b7` bounds JavaScript bridge work to three concurrent translations.
Element-scoped Promise joining remains intact for queued and running work.
Current-page Range work has priority over observer work and next-page prefetch;
an already queued element is promoted when a new relocation makes it current.
Queued work rechecks mode and document ownership before calling Flutter, so a
retired chapter cannot consume a bridge/provider slot. Running stale
completions remain harmless under the existing owner check. A browser `online`
event reconciles stored current/prefetch Ranges, allowing settled transient
network failures to retry without reopening the book, while permanent
authentication/configuration failures remain quiescent.

Live verification of those two commits exposed the final ownership defect.
The visible italic paragraph beginning `Reward: You can now gain experience`
intersected the current Range and had valid frozen text/context, no wrapper,
no failure, no queued entry, and a running Promise. The queue itself was empty
with two active slots. `CancelableLangchainRunner`, however, was a global
singleton with one `_subscription` field. Each of the up to three legitimate
concurrent AI streams overwrote that field. Cancelling or timing out one stream
could therefore cancel another stream and await the wrong subscription while
leaving its own provider subscription alive. The stream-level inactivity
contract could not provide reliable liveness with incorrect transport
ownership.

`33de3e13` gives every normal and agent runner invocation its own local model
subscription. The runner separately tracks all active subscriptions only for
the explicit global-cancel operation. Per-stream timeout/cancel now removes and
cancels exactly that stream; completion also removes exactly its own entry.
The regression starts two controlled model streams and proves that cancelling
the first increments only the first model's cancellation count, then cancelling
the second independently increments the second.

### Automated verification

- Added `assets/foliate-js/test/translator.test.mjs` with deterministic
  cases: already-enabled bilingual mode across new chapters, missed observer
  callback, element in-flight deduplication, immediate cached result, slow
  result, wrapper repair without a provider call, retired-chapter completion,
  transient retry, permanent-error quiescence, all four display modes, and
  renderer-driven cleanup. A dedicated opening-performance regression verifies
  that reconciliation translates the current and next paginator Ranges, then
  advances the prefetch window without translating the third page prematurely.
  The chapter test also verifies that previous-paragraph context resets per
  document and is preserved within it.
- Configured `npm test` passed all five test files. Running the same suite with
  Node's process isolation disabled exposed the individual count: 54 of 54
  tests passed, including all 12 translator cases.
- `npm run build` succeeded and regenerated `assets/foliate-js/dist/bundle.js`.
  Webpack emitted the same three known top-level-await target warnings.
- The focused cache and WebDAV merge run passed 22 tests. It reconfirmed cache
  hits bypass providers, successful results persist, non-cacheable failures do
  not persist, identical Dart requests share one computation, and book/global
  invalidation and merge semantics are unchanged. No Dart cache code or tests
  required modification because no cache-layer defect was found.
- Full `flutter test --no-pub` passed 284 tests. Full
  `flutter analyze --no-pub` reported zero errors and zero warnings plus the
  same 42 repository informational lints documented above.
- Final staged and worktree diff checks passed.
- After the MIME fix, its focused Flutter test passed 2 of 2 cases and the full
  suite passed 286 of 286 tests. Targeted analysis of the server and test
  reported no issues. A release APK built successfully and was installed for
  the device-side DevTools smoke verification described above.
- The provider-liveness regression proves that concurrent identical callers
  share one three-attempt sequence, every silent stream subscription is
  cancelled, the failed result is absent from SQLite, Dart `_inFlight` is
  released, and a later retry succeeds and persists. The focused cache suite
  passed 12 of 12 tests.
- Foliate now has 16 translator regressions, including online recovery,
  max-three concurrency, current-before-prefetch ordering, queued-operation
  promotion, and retired-chapter queue cleanup. The configured Foliate suite
  passed 58 of 58 tests. Webpack regenerated `dist/bundle.js` successfully with
  the same three known top-level-await warnings.
- Full `flutter test --no-pub` passed 287 of 287 tests. Targeted analysis
  reported no issues. Full analysis reported zero errors and zero warnings plus
  the same 42 informational lints (and therefore its normal nonzero exit).
  The release APK built successfully at 76.7 MB, installed over the existing
  app with data retained, and launched on `A3DE65C3`; PID 8230 was alive with
  `MainActivity` resumed, visible, and drawn, with no crash or ANR in the
  process smoke log. This launch smoke check is not the bilingual checklist.
- After `33de3e13`, the focused runner test passed, targeted analysis reported
  no issues, and the full Flutter suite passed 288 of 288 tests. Full analysis
  again reported no errors or warnings and the same 42 informational lints.
  The 76.7 MB release APK rebuilt and installed with app data retained.
- Device/WebView before/after validation used the exact reported paragraph.
  Before the runner fix, `Reward: You can now gain experience...` intersected
  the current Range but remained in `#inFlightElements` with no translated or
  failed state, no queue entry, and no wrapper. After installing and reopening
  the same saved CFI, it had left in-flight state, had successful translated
  state, and contained exactly one wrapper: `Награда: теперь вы можете получать
  опыт. Наберите достаточно, и, возможно, даже повысите уровень.` Active slots
  and the queue were both zero. This confirms the concrete reported paragraph;
  it still does not replace the 5–10 chapter checklist.

### Bilingual translation Android/device checklist

Status: **MANUAL VERIFICATION REQUIRED**. Codex performed only the opening-path
DevTools smoke check described above, not the following bilingual checklist.

1. Enable bilingual mode.
2. Open a chapter and wait for visible translations.
3. Navigate forward through at least 5–10 chapter transitions.
4. On every newly opened chapter, verify every visible translatable paragraph
   receives its translation.
5. Page forward several visual pages without changing chapters.
6. Navigate chapter A to B to A.
7. Test with translations already in local cache.
8. Test with translations not yet cached.
9. Navigate to the next chapter while translations are still arriving.
10. Verify no duplicate translated paragraphs appear.
11. Verify no paragraph requires leaving/reopening the book to display its
    already-successful translation.

### Remaining limitations

- Real Android WebView/paginator timing, cached and uncached providers, and
  rapid chapter navigation still require the checklist above. The strict-MIME
  repair and the exact reported pending paragraph received device-side
  before/after confirmation, but the full navigation matrix remains manual.
- Retiring a document does not actively cancel an already-dispatched Flutter
  bridge request. Its completion is ignored by presentation state. A silent
  provider attempt is now subscription-cancelled by the inactivity contract;
  responsive requests may still finish normally.
- JavaScript transient retries are lifecycle-triggered rather than timer-driven.
  Connectivity restoration now supplies an `online` lifecycle trigger.
  Permanent authentication/configuration output intentionally waits for an
  explicit mode cycle, corrected settings plus a new document, or book reopen.
- IntersectionObserver remains the lazy-loading accelerator. Explicit
  reconciliation is the correctness mechanism for currently relevant elements;
  offscreen content converges as it enters the near viewport or relocation
  makes it relevant.

Branch readiness: Ready for manual verification / merge review

## Overall milestone status

- Status: COMPLETE
- Completed submilestones: 12 of 12 implementation phases
- Branch readiness: Ready for manual verification / merge review

## Current checkpoint

Last completed work: Selection-owned tap suppression, awaited external-action
preparation, and redundant manual Translate action removal
Current branch: `feature/m4e-canonical-annotation-ux`
Last implementation commit:
`8389675c fix: harden selection tap and external action lifecycle`
Documentation checkpoint: This section and the regression record below cover
the Android Range-collapse/click race, one-shot gesture ownership, awaited
external-provider handoff, resume reconciliation, and toolbar cleanup. The
bilingual/full-text translation pipeline remains unchanged.
Repository state: Clean after the selection stabilization documentation commit
Next submilestone: Manual selection/external-action and bilingual/device
verification, then merge review
Next concrete tasks: Execute both manual Android/device checklists, then
continue merge review. Do not claim device verification until those checks are
run.
Known failing tests: None
Known limitations: Presentation LWW uses wall-clock timestamps; presentation
document/reset records have no compaction; coincident annotation ranges have no
chooser UI; external provider apps cannot return savable result payloads;
selection cannot span separate EPUB spine DOM documents; there is no automated
Android native-handle gesture harness; physical legacy tables may remain as
migration-only input; and remote-only WebDAV book discovery remains out of
scope. Local `develop` still has the previously documented divergence from
`origin/develop`.
Important files for review: final architecture coverage under
`test/service/sync/final_annotation_architecture_test.dart`, the acceptance
coverage under `test/service/sync/` and `test/page/book_player/`, the Foliate
tests under `assets/foliate-js/test/`, and the runtime paths in
`annotation_catalog.dart`, `annotation_repository.dart`,
`annotation_sync_runtime.dart`, `foliate_annotation_adapter.dart`, and
`epub_player.dart`.

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

## Post-M4E selection device-regression stabilization

- Status: IMPLEMENTED; MANUAL VERIFICATION REQUIRED
- Implementation commit:
  `8389675c fix: harden selection tap and external action lifecycle`
- Scope: transient selection gesture ownership, external selection-action
  lifecycle, and removal of the redundant manual selection Translate action.
  Canonical persistence, annotation identity, protocol v2, bilingual/full-text
  translation, `translator.js`, persistent translation cache, and translation
  WebDAV synchronization are unchanged.

### Page-turn double handling: exact cause and correction

`book.js` correctly captured the active Range and SelectionSession generation
on capture-phase `pointerdown`. The normal reader click path in `view.js`,
however, later decided whether to emit `click-view` solely from the live DOM
selection. Android can collapse the Range after `pointerdown` and before
`pointerup`/`click`. The selection lifecycle then cleared generation N, while
the later click saw no Range and was independently emitted as a page-turn/menu
tap. One physical gesture therefore entered both lifecycles.

`SelectionGestureOwnership` now records only the owning content `Document`,
pointer ID, current SelectionSession generation, and terminal pointer
coordinates. It is not a second selection session or generation counter. A
capture-phase document click listener consumes exactly the matching click once,
even when `selectionchange` already cleared `pendingPointer` before
`pointerup`. A new independent `pointerdown`, `pointercancel`, `pagehide`, or
content-document replacement invalidates stale ownership. There is no timer,
delay, or debounce window. Flutter's page-turn handler also refuses a click
while its generation bridge still knows a transient selection is active; JS
remains the primary ordering boundary.

### External selection action: exact stale-overlay path and correction

Google Translate and External Dictionary previously called synchronous
`onClose()` and immediately invoked the Android PROCESS_TEXT gateway.
`onClose()` removed the Flutter entry and changed the Flutter bridge, but its
generation-scoped JavaScript `hideSelectionActions` evaluation was
fire-and-forget. Android `startActivity` could therefore suspend the app before
the cross-layer transition completed, leaving Flutter and the WebView disagreeing
about whether generation N was `ACTIONS_VISIBLE`. There was no explicit resume
reconciliation for an interrupted handoff.

`prepareSelectionForExternalAction(generation)` is now the completed boundary
before any external launcher. It synchronously claims only a matching
`ACTIONS_VISIBLE` request, transitions Flutter to `SELECTED`, and removes the
generation-tagged `OverlayEntry` and both overlay references. It then awaits
the JS `hideSelectionActions(generation)` call. A false result or exception is
safe when the JS session/document already ended, and late generation-N cleanup
cannot remove or hide N+1. On resume, the player only removes an overlay that
has no matching valid actions-visible bridge request; it never reconstructs or
automatically opens actions.

The common boundary is used for Google Translate, External Dictionary, web
search, and Share. AI remains an internal workflow with its existing
selection-persistence ownership. If the DOM Range survives an external action,
the session remains `SELECTED` and a deliberate later tap can request actions
again. If Android collapses it, the normal generation-scoped clear converges to
`IDLE`. Launch failure leaves the overlay closed and the bridge coherent.

The manual selection action labelled `Translate` with `Icons.translate` was
removed. The visible Google Translate action remains. Existing
`autoTranslateSelection` behavior and the underlying internal translation
service remain present; no bilingual/full-text translation code was modified.

### Automated verification

- Configured Foliate `npm test`: 67 of 67 passed, including nine new
  deterministic gesture tests for outside/inside taps, visible-action hiding,
  native Range collapse, one-shot next-tap behavior, cancellation, identity
  mismatch, and document replacement.
- Configured Foliate `npm run build`: succeeded and regenerated
  `assets/foliate-js/dist/bundle.js`; Webpack emitted the same three known
  top-level-await target warnings.
- Focused Flutter selection bridge, canonical mutation boundary, Google
  Translate PROCESS_TEXT, and External Dictionary run: 39 of 39 passed.
- Full `flutter test --no-pub`: 294 of 294 passed.
- Targeted Flutter analysis: no new production issue; the two reported
  `reading_page.dart` informational lints predate this change.
- Full `flutter analyze --no-pub`: zero errors, zero warnings, and the same 42
  repository informational lints documented by earlier stabilization work.

### Selection and external-action Android/device checklist

Status: **MANUAL VERIFICATION REQUIRED**. Codex did not execute these checks.

1. Select text.
2. Tap previous-page zone outside selection.
   Expected: selection clears, page does NOT turn.
3. Tap previous-page zone again.
   Expected: page turns normally.
4. Select text and tap next-page zone outside selection.
   Expected: selection clears, page does NOT turn.
5. Tap selected text.
   Expected: actions open, page does NOT turn.
6. Tap selected text again.
   Expected: actions hide, selection remains.
7. With actions visible, tap outside.
   Expected: actions and selection disappear, page does NOT turn.
8. Open actions -> Google Translate.
9. Verify Anx action overlay is gone before/while Translate opens.
10. Close Google Translate.
11. Verify no stuck Anx action buttons.
12. If selection survives, tap it to reopen actions normally.
13. Repeat Google Translate launch/return several times.
14. Repeat with external Dictionary.
15. Repeat near left/right page-turn zones.
16. Verify normal page turning still works when there is no active selection.
17. Verify the manual Translate button is no longer present.
18. Verify bilingual mode still works unchanged.
