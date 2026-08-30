# M4E — Canonical Annotation UX, BookNote Removal, and Selection Workflow

This document is the durable source of truth for M4E. A new work session must
read it completely, inspect the latest 20 commits and the worktree status, then
continue from the first incomplete submilestone and the Current checkpoint.

## Goal

M4E makes canonical shared annotation state the only semantic annotation model:

```text
SharedAnnotation
    = canonical semantic annotation state

AnnotationPresentationSidecar
    = local Anx-only style/color state

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
                    │               + local presentation
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
- Presentation is client-local.
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
- Commit SHA: pending follow-up documentation checkpoint
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

- Status: NOT STARTED
- Commit SHA: —
- Important files changed: —
- Architectural decisions made: `annotationContext` is compact persisted
  sentence context; `lookupContext` may be wider, is transient, and is never
  persisted implicitly.
- Tests run: —
- Discovered limitations or follow-up work: No mass backfill of old annotations
  is in scope.
- Acceptance checklist:
  - [ ] Replace character-window persistence with robust sentence segmentation
    plus fallback.
  - [ ] Avoid duplication for full-sentence selections after whitespace and
    terminal-punctuation normalization.
  - [ ] Keep multi-sentence persisted context to the smallest meaningful span.
  - [ ] Provide wider transient provider context separately.
  - [ ] Test word, phrase, clause, sentence, punctuation omission,
    multi-sentence selection, and whitespace normalization.

### M4E.6 — Simplified transient lookup UX

- Status: NOT STARTED
- Commit SHA: —
- Important files changed: —
- Architectural decisions made: AI, Google Translate, and Dictionary are
  transient; only explicit save may create or mutate a canonical annotation.
- Tests run: —
- Discovered limitations or follow-up work: Share may remain only in secondary
  UI if useful; it is removed from primary annotation actions.
- Acceptance checklist:
  - [ ] Present AI, Translate, Dictionary, Personal note, and presentation as
    primary selection actions.
  - [ ] Keep provider results/errors transient until explicit save.
  - [ ] Store an `AnnotationRef` in the session after first save and reuse it
    for later saves in that session.
  - [ ] Never find/reuse annotations by CFI.
  - [ ] Add lookup/no-write and save/reuse tests.

### M4E.7 — Canonical enrichment mutation API

- Status: NOT STARTED
- Commit SHA: —
- Important files changed: —
- Architectural decisions made: Semantic APIs accept `AnnotationRef`; creation
  on first explicit save returns the UUID used by all subsequent session saves.
- Tests run: —
- Discovered limitations or follow-up work: Use only protocol-v2 enrichment
  kinds: translation, dictionary, ai-analysis, personal-note, and ai-thread.
- Acceptance checklist:
  - [ ] Add canonical identity APIs for create, enrich, tombstone, and local
    presentation update.
  - [ ] Commit canonical data before renderer/UI refresh.
  - [ ] Report post-commit refresh failure as renderer/presentation failure.
  - [ ] Remove native BookNote-ID semantic APIs as consumers migrate.
  - [ ] Add mutation, durability, and failure-boundary tests.

### M4E.8 — Direct Foliate annotation renderer adapter

- Status: NOT STARTED
- Commit SHA: —
- Important files changed: —
- Architectural decisions made: `FoliateAnnotationDto` is ephemeral and should
  use the canonical UUID directly when the bridge accepts string IDs.
- Tests run: —
- Discovered limitations or follow-up work: If a renderer handle is necessary,
  its UUID mapping remains ephemeral and is never domain identity.
- Acceptance checklist:
  - [ ] Render canonical annotation plus local presentation without `BookNote`.
  - [ ] Resolve renderer hit testing to `AnnotationRef`.
  - [ ] Keep rendered-annotation taps distinct from DOM Range selections.
  - [ ] Add adapter and bridge verification.

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
- Completed submilestones: 4 of 11 implementation phases
- Branch readiness: Not ready to merge

## Current checkpoint

Last completed submilestone: M4E.4 — Preserve cross-page selection
Current branch: `feature/m4e-canonical-annotation-ux`
Last implementation commit: pending M4E.4 implementation commit
Documentation checkpoint: pending follow-up commit recording the M4E.4 implementation SHA
Repository state: M4E.4 implementation and documentation complete and validated; commits pending
Next submilestone: M4E.5 — Sentence-aware annotation context
Next concrete tasks: Inventory the current persisted character-window context and transient provider-context consumers; introduce sentence-aware persisted `annotationContext` with normalization/fallback while keeping wider `lookupContext` transient; add focused word, phrase, clause, sentence, punctuation, multi-sentence, and whitespace tests
Known failing tests: None
Known limitations: Automated tests do not synthesize real Android WebView native-handle gestures. Paginated auto-page selection is supported only across visual pages within one live content `Document`/EPUB section; a spine-document replacement ends the session rather than claiming a cross-document DOM `Range`. Local `develop` tracks the upstream project and `git pull --ff-only` could not fast-forward because histories diverged; per user direction, M4E is based on the current local `develop` tip containing merged M4A–M4D work, with no `origin/develop` comparison
Important files to inspect next: `assets/foliate-js/src/book.js` and its current `buildRangeContextText`; `lib/page/book_player/selection_session_bridge.dart`; selection payload consumers in `lib/page/book_player/epub_player.dart`; canonical annotation creation/mutation paths that persist context; and focused context/protocol mutation tests

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
