# Unified Annotation Editor

## Status checkpoint

Status: **IMPLEMENTATION CHECKPOINT — CONTINUE IN A NEW SESSION**

Branch: `feature/m4e-canonical-annotation-ux`

Implemented commits:

- `2ba36157 feat: add unified annotation editor draft model`
- `f0943b49 feat: add internal annotation enrichment providers`
- `773f7e2d feat: persist unified annotation editor state`
- `01da9917 feat: add unified annotation editor and AI chat`
- `eed0fb69 feat: route selection enrichments through annotation editor`

This checkpoint is intentionally not a completion claim. The core feature is
implemented and focused tests pass, but the complete verification and remaining
compatibility hardening listed below still need to be finished.

## Goal and reference behavior

The feature ports the product behavior of Lingua Reader's `AnnotationModal`
into Flutter. One editor owns Google Translate, LDOCE, structured AI analysis,
AI follow-up history, and a personal note. Provider exploration remains draft
state until explicit Save. Existing annotations open by exact `AnnotationRef`
and hydrate saved material without automatically rerunning a provider.

This work does not redesign canonical annotations. Protocol version 2,
`SharedAnnotation`, `AnnotationRef`, material enrichments, `personal-note`,
`ai-analysis`, `ai-thread`, Anx presentation, and `SelectionSessionMachine`
remain authoritative. No `BookNote`, native annotation ID, CFI identity, or
projection reconciliation was introduced.

## Editor state model

`AnnotationEditorDraft` owns:

- the immutable `SelectionSnapshot` and optional existing `AnnotationRef`;
- personal-note text;
- one draft result for each built-in slot: Google Translate, LDOCE, and AI;
- canonical enrichment/thread/message IDs and creation times when hydrated;
- AI conversation messages;
- dirty state;
- independent provider loading/error/generation state;
- a closed lifetime that rejects late async completions.

`AnnotationEditorController` runs providers, AI follow-ups, Save, and whole
annotation deletion. Provider calls update only the draft. Closing the
controller invalidates provider and chat completions. A second refresh has a
new generation, so an older completion cannot overwrite it.

## Draft and persistence boundary

For a new selection, provider calls, follow-up calls, provider removal, and
personal-note editing invoke no repository mutation. Cancel/Discard closes the
draft and creates no annotation or outbox entry.

`AnnotationRepository.saveAnnotationEditorDraft` is the single persistence
boundary. One editor Save invokes one serialized repository operation and one
`putAnnotationDocument` commit when canonical state changes.

For a new annotation it creates one UUID, target, all material enrichments,
personal note, and AI thread before committing once. For an existing annotation
it resolves only the supplied `AnnotationRef`, preserves the target and unknown
fields, reconciles the three built-in material slots, personal note, and the
effective AI thread, then commits once. It never searches by CFI or text.

Existing enrichment/thread/message IDs and `createdAt` values are retained when
updated. Genuinely new entities receive UUIDs. Removed material is tombstoned.
A tombstoned entity is never resurrected; a later intentional result gets a new
ID. Unknown annotation, enrichment, thread, message, selector, and context
fields are retained. Existing messages not present in a stale editor snapshot
are retained rather than overwritten. The editor also carries the material and
thread IDs observed when it opened, so a stale Save tombstones only entities it
actually saw and preserves concurrently introduced material or threads.

Editing only the personal note does not write Anx presentation state.

## Provider architecture

Providers are isolated under `lib/service/annotation_enrichment/` and do not
depend on the editor widget or repository.

### Google Translate

`GoogleAnnotationTranslateService` calls the isolated unofficial endpoint:

`https://translate.googleapis.com/translate_a/single`

It uses `client=gtx`, `sl=auto`, the configured `Prefs().translateTo` target,
`dt=t`, normalized whitespace, URL query encoding, a finite 15-second timeout,
and structured JSON parsing. Multiple segments are joined and detected language
is saved in string metadata. Parser/HTTP tests use fixtures/mocks, not live
Google.

The endpoint is unofficial and may change. Failure is draft-local and does not
block other sources or Save. `GoogleTranslateAppService` remains in the codebase
and is exposed as an optional card action; it is not the persisted result
source. ML Kit remains unchanged and separate.

### LDOCE

`LdoceAnnotationDictionaryService` fetches the normalized LDOCE dictionary URL
with a finite 15-second timeout. Its isolated HTML parser extracts headword,
part of speech, pronunciation, senses, labels, definitions, and examples. The
short first definition maps to canonical `translation`; the formatted complete
article maps to canonical `markdown`; source URL maps to string metadata.

Fixture tests do not use live LDOCE. HTML structure is external and may change;
failure is draft-local. `ExternalDictionaryService` has not been deleted.

### AI analysis and language

`AnnotationAiService` reuses `resolveEffectiveAiRouteFromPrefs` and
`aiGenerateStreamWithRoute`; it introduces no second provider configuration.
The configured route ID/title becomes canonical provider identity. Analysis is
parsed into semantic `translation`, `translationNotes`, `grammar`, and `usage`
fields, stored as top-level translation plus structured commentary rather than
generic content.

Prompts explicitly use the configured translation target language name/code.
They do not force English or hardcode Russian. A regression test covers a
Ukrainian target.

## AI follow-up context and persistence

Each follow-up receives selected text, transient lookup context, book/chapter,
personal-note draft, every current provider result, prior AI messages, and the
new question. Input is bounded to compact annotation/lookup material; no whole
book is sent.

Conversation is represented as canonical `ai-thread` messages. Reopening an
annotation selects the deterministic current non-tombstoned thread and restores
message order. Opening does not trigger analysis or a follow-up. Continuing a
thread retains its thread/message identities and appends only new messages.

## Canonical and Lingua mapping

- Google: `kind=translation`, `providerId=google-translate`, provider name,
  top-level `translation`, detected-language metadata.
- LDOCE: `kind=dictionary`, `providerId=ldoce`, provider name, short
  `translation`, full `markdown`, source URL metadata.
- AI: `kind=ai-analysis`, actual route/provider identity, top-level
  `translation`, structured `commentary`.
- Chat: `kind=ai-thread`, compact `contextSnapshot`, ordered canonical messages.
- Note: `kind=personal-note` with established deterministic/tombstone behavior.

These are the protocol-v2 fields used by the inspected Lingua Reader adapter.
Bidirectional fixtures cover Lingua-created and Anx-created Google, LDOCE, AI
analysis, and AI-thread payloads. A Lingua fixture is hydrated through the
editor and saved back through its single repository boundary while preserving
unknown document, annotation, target, selector, material, commentary,
metadata, thread-context, and message fields.

## UI and selection lifecycle

The Flutter dialog is constrained for large screens and nearly full-screen on
mobile, scrollable, keyboard-inset aware, and has sticky Cancel/Save actions.
Google, LDOCE, and AI render as independent expandable cards with independent
loading, error, Refresh, and Remove actions. Personal note and AI chat are in
the same modal. Dirty dismissal offers Save, Discard, and Cancel. Existing
annotations expose confirmed whole-annotation deletion.

Google, Dictionary, AI, and Note toolbar entries now open this same editor.
Provider entries pass an `initialProvider`, which runs only after the dialog's
first frame and only when that provider is absent. Existing highlight taps pass
their exact canonical UUID and hydrate without network calls.

Opening the modal first uses the awaited selection-action preparation boundary,
which hides the action overlay while preserving a surviving DOM Range. After a
new annotation Save, canonical annotations refresh first and then
`clearSelection()` ends the transient DOM selection. Cancel leaves actions
hidden and may leave the native selection available for a later deliberate tap.

## Focused automated evidence completed

Completed during this checkpoint:

- editor draft/controller/provider focused run: 23 tests passed;
- repository plus protocol/fixture focused run: 59 tests passed;
- final selection/editor/read-model/repository integration run: 72 tests passed;
- targeted analysis of editor, read model, repository, context menu, player,
  and focused tests: no issues;
- `dart format` on every touched Dart file;
- `git diff --check` before each phase commit.

Widget hardening completed after the checkpoint adds 5 tests covering all
three source cards at phone and desktop widths, sticky actions while the editor
body scrolls, dirty dismissal choices, post-frame initial-provider startup, and
existing-source open without a provider call. The combined editor
widget/controller/draft run passes 17 tests.

Cross-client hardening adds explicit Lingua-to-Anx and Anx-to-Lingua fixtures
for all editor sources and AI messages. The focused cross-client, editor draft,
controller, and repository run passes 35 tests. This work also fixed nested
unknown commentary retention: the editor now owns the four known commentary
keys while carrying any future keys transparently through Save.

Repository hardening adds explicit editor-Save coverage for personal-note
clearing, independent AI and Google removal, true no-op saves, and concurrent
unseen material/thread/message preservation. The combined repository,
cross-client, widget, controller, and draft run passes 44 tests. Draft baseline
IDs ensure that stale removal intent cannot tombstone entities introduced after
the editor opened.

The modal no longer contains user-facing English literals. It uses existing
common actions plus dedicated annotation-editor localization keys, with English
template text and Russian translations. Other locales use the repository's
established generated English fallback and are listed in the generated
untranslated-message report. A sixth focused test verifies the Russian editor
strings through the generated localization class.

The repository test proves that a first editor Save containing Google, LDOCE,
AI, two follow-up exchanges, and personal note creates one annotation and local
canonical revision 1. Existing edit tests prove the same UUID is reused and one
Save advances the canonical revision exactly once. Removal, Cancel/no-write,
unknown-field retention, stable IDs/creation times, and tombstone
non-resurrection are covered.

## Remaining automated work

Continue with these tasks in order:

1. Audit/remove now-obsolete fragmented selection-only persistence UI where it
   is genuinely unused, while retaining external Google/Dictionary services.
2. Run the complete `test/service/sync` suite, then full Flutter and Foliate
   verification below.
3. Fix any regression without changing protocol version 2 or bilingual files.
4. Finish this document's test evidence/limitations and update the M4E current
   checkpoint only after all suites pass.

Required final commands not yet run for this feature:

```bash
dart format .
flutter test --no-pub
flutter analyze --no-pub
cd assets/foliate-js
npm test
npm run build
```

Do not hand-edit `assets/foliate-js/dist/bundle.js`. The current implementation
did not modify bilingual translator/cache/fingerprint/WebDAV code or Foliate
source/bundle.

## Known limitations at this checkpoint

- Complete Flutter and Foliate suites have not yet been run after this feature.
- Real network behavior is intentionally untested; Google/LDOCE automated tests
  use mocks/fixtures.
- The Google endpoint is unofficial and LDOCE HTML can evolve.
- No Android WebView/native-handle automation exists; device verification is
  required.
- This checkpoint has not been pushed or merged into `develop`.

## MANUAL VERIFICATION REQUIRED

Codex did not perform these device checks:

1. Select phrase.
2. Tap it to open actions.
3. Choose Google.
4. Unified editor opens and Google result appears.
5. Without saving, add Dictionary.
6. Dictionary appears next to Google.
7. Add AI analysis.
8. AI result appears without removing other cards.
9. Ask two AI follow-up questions.
10. Add personal note.
11. Press Cancel.
12. Verify no highlight/annotation was created.
13. Repeat and press Save.
14. Verify one highlight appears.
15. Tap saved highlight.
16. Open editor without invoking a provider.
17. Verify Google/Dictionary/AI/personal note/chat are already present.
18. Verify no automatic network or AI request occurs.
19. Ask another AI follow-up.
20. Save.
21. Reopen and verify full conversation remains.
22. Remove only Dictionary and Save.
23. Verify annotation/Google/AI remain.
24. Refresh Google and Save.
25. Verify no duplicate Google card.
26. Delete whole annotation.
27. Verify highlight disappears.
28. Sync to another Anx device.
29. Verify all saved enrichments/chat appear.
30. Open the same annotation in Lingua Reader.
31. Verify cross-client material remains meaningful.
32. Create/enrich an annotation in Lingua Reader.
33. Sync to Anx.
34. Verify unified editor displays it without rerunning providers.
35. Verify normal selection/page-turn behavior still passes.
36. Verify Google Translate external-app action still does not leave a stuck
    overlay.
37. Verify bilingual mode still works.

Branch readiness at this checkpoint: **ready for continued automated
hardening, not yet ready for final manual verification sign-off**.
