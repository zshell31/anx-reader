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

- Status: NOT STARTED
- Commit SHA: —
- Important files changed: —
- Architectural decisions made: The explicit states are `IDLE`, `SELECTED`, and
  `ACTIONS_VISIBLE`; session/generation identity invalidates stale callbacks.
- Tests run: —
- Discovered limitations or follow-up work: Preserve Android native selection
  handles and avoid blanket pointer/touch `preventDefault()` behavior.
- Acceptance checklist:
  - [ ] New/changed selections leave actions hidden.
  - [ ] Tapping inside the selection toggles actions.
  - [ ] Tapping outside clears selection and ends the session.
  - [ ] Hiding actions does not clear selection.
  - [ ] No Flutter overlay or timer can outlive its session.
  - [ ] Remove obsolete selection clear lock/pending mechanisms.
  - [ ] Add practical state-machine and bridge tests.

### M4E.4 — Preserve cross-page selection

- Status: NOT STARTED
- Commit SHA: —
- Important files changed: —
- Architectural decisions made: Auto-page callbacks belong to a selection
  generation and are cancelled/ignored when that generation ends.
- Tests run: —
- Discovered limitations or follow-up work: Do not claim DOM selection across
  separate EPUB spine documents unless verified by Foliate.
- Acceptance checklist:
  - [ ] Preserve boundary-triggered page advancement in paginated mode.
  - [ ] Keep actions hidden during drag/selection changes.
  - [ ] Scope pending page work to the active session.
  - [ ] Cover stale timer/new-selection/clear-selection races.

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
- Completed submilestones: 2 of 11 implementation phases
- Branch readiness: Not ready to merge

## Current checkpoint

Last completed submilestone: M4E.2 — Local annotation presentation sidecar
Current branch: `feature/m4e-canonical-annotation-ux`
Last commit: `45a4255b feat: add local annotation presentation sidecar`
Repository state: Clean at the completed M4E.2 boundary; this documentation-only SHA checkpoint is the sole pending change
Next submilestone: M4E.3 — Explicit SelectionSession state machine
Next concrete tasks: Map every selection event/message and overlay lifecycle transition in `assets/foliate-js/src/book.js`, `assets/foliate-js/src/view.js`, `lib/page/book_player/epub_player.dart`, and the context-menu widgets; identify configured Foliate JS test commands; introduce generation-scoped IDLE/SELECTED/ACTIONS_VISIBLE transitions without disrupting Android native handles
Known failing tests: None
Known limitations: Local `develop` tracks the upstream project and `git pull --ff-only` could not fast-forward because histories diverged; per user direction, M4E is based on the current local `develop` tip containing merged M4A–M4D work, with no `origin/develop` comparison
Important files to inspect next: `assets/foliate-js/src/book.js`, `assets/foliate-js/src/view.js`, `assets/foliate-js/package.json`, `lib/page/book_player/epub_player.dart`, `lib/widgets/context_menu/context_menu.dart`, `lib/widgets/context_menu/excerpt_menu.dart`, and any existing reader bridge/selection tests
