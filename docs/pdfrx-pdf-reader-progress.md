# pdfrx PDF Reader Progress

## Goal

Replace normal PDF reading through Foliate/WebView/PDF.js with a dedicated,
minimal `pdfrx` reader that supports lazy page reading, zoom, canonical text
annotations, and a derived bilingual reflow presentation without changing the
EPUB renderer or annotation protocol v2.

## Baseline

- Source branch / commit used for analysis:
  `feature/automatic-shared-state-sync` at
  `749e7ce077ce59d84efff079c9f6efa55cde6424` (matched
  `origin/feature/automatic-shared-state-sync` after `git fetch origin`).
- Implementation branch / current commit: `feature/pdfrx-pdf-reader`.
  Milestone 1 is `43eb56c2 feat(pdf): add dedicated pdfrx reader`; Milestone 2
  is `8524e0cc feat(pdf): add zoom controls`.
- Toolchain: Flutter 3.35.3, Dart 3.9.2.
- Compatible current package selected: `pdfrx 2.2.24` with
  `pdfrx_engine 0.3.9`. This is the newest `pdfrx` release whose declared
  minimums (Flutter 3.35.1 / Dart 3.9.0) fit the repository toolchain. Newer
  `pdfrx` 2.3+ releases require newer Flutter/Dart.

## Architecture discovered

- Current reader routing: `pushToReadingPage` always opens `ReadingPage`, and
  `ReadingPage` unconditionally builds `EpubPlayer`. `EpubPlayer` hosts
  Foliate in `flutter_inappwebview`; Foliate's `book.js` detects PDF and loads
  `assets/foliate-js/src/pdf.js` plus bundled PDF.js. The smallest dedicated
  routing seam is the player child in `ReadingPage`: route `.pdf` to a new
  `PdfPlayer`, leave all other formats on `EpubPlayer`.
- Reading position: EPUB relocation updates `Book.lastReadPosition` and
  `Book.readingPercentage`, persists through `bookDao.updateBook`, then calls
  `annotationSyncRuntime.recordReadingProgress(book)`. PDF should encode a
  portable page-based position string in the existing `lastReadPosition`
  column and use the same write/sync path.
- Current EPUB annotation flow: Foliate selection events create a
  `SelectionPersistenceSession`; `ExcerptMenu` / the unified annotation editor
  create `CanonicalSelectionCreation`; `AnnotationRepository` commits the
  canonical protocol-v2 document to `SharedStateDatabase` before renderer
  refresh. `BookNote` and local database IDs are not authoritative.
- Annotation protocol: protocol v2 already preserves an array of arbitrary
  selector maps. The read adapter currently exposes only one valid
  `epub-cfi`, and `AnnotationRepository._fingerprint` rejects non-EPUB books.
  PDF therefore needs a minimal repository/input/read-model extension using
  existing selector extensibility: one `pdf-page` selector plus one
  `text-quote` selector (`exact`, `prefix`, `suffix`). No schema-version change
  is needed. Unsupported selectors remain canonical and must not be deleted.
- PDF annotation restoration: restrict lookup to the stored page; match
  `exact`; use `prefix` and `suffix` to resolve repeated occurrences; render
  only a unique safe match. Character bounds may be used for rendering after
  semantic resolution, but are not canonical identity.
- Lingua Reader comparison: its current `applyTextHighlights` builds phrases
  from entry text and `createHighlightRanges` walks all occurrences. Its PDF
  overlay then paints every produced range, without using `pdf-page` plus
  quote prefix/suffix. This implementation must not copy that behavior.
- Translation/bilingual flow: Foliate calls Flutter's `translateText` handler.
  Flutter uses `FullTextTranslationCoordinator`, configured by
  `Prefs().fullTextTranslateService`, `fullTextTranslateFrom`, and
  `fullTextTranslateTo`. The coordinator creates the existing fingerprinted
  `FullTextTranslationRequest` and uses
  `FullTextTranslationCacheService`/`TranslationCacheDatabase`. PDF reflow
  will call this same coordinator lazily per extracted block.
- `pdfrx` API verified from the official 2.2.24 source: `PdfViewer.file` uses
  progressive loading; `PdfViewerParams` supplies loading/error builders,
  page-change callbacks, selection/context-menu hooks, and per-page overlays;
  `PdfViewerController` supplies page navigation and zoom controls; selected
  `PdfPageTextRange` values include page, character indices, text, and bounds;
  `PdfPage.loadStructuredText()` is supplied by `pdfrx_engine` and preserves
  ordered text/fragments with character rectangles.

## Milestones

- [x] Milestone 1: dedicated minimal `pdfrx` local PDF reader, normal lazy page
  navigation, loading/error UI, and persisted/restored page position; verify
  EPUB routing remains unchanged; commit separately.
- [x] Milestone 2: verify native pinch/pan zoom and add minimal explicit zoom
  in/out controls backed by `PdfViewerController`; validate rebuild/rotation;
  commit separately.
- [x] Milestone 3: canonical PDF selection/annotation creation, quote-context
  restoration, unique repeated-text resolution, persistent overlays, and
  focused protocol/repository tests; commit separately.
- [ ] Milestone 4: independent ordered PDF text-block extraction with lazy
  per-page loading and pure tests; commit separately.
- [ ] Milestone 5: original/reflow mode switch, lazy source-plus-translation
  blocks using the existing translation coordinator/cache, and semantic page
  anchoring in both directions; commit separately.
- [ ] Final validation: formatting, static analysis, all relevant Flutter/Dart
  tests, clean worktree, and documented MVP limitations.

## Completed work

- Verified and updated the requested source branch against its remote.
- Inspected reader routing, Foliate/PDF.js loading, EPUB selection/editor flow,
  canonical annotation repository/read model/protocol, shared reading-progress
  writes, full-text translation cache/coordinator, existing sync architecture
  documentation/tests, and Lingua Reader's PDF highlight implementation.
- Verified exact supported `pdfrx 2.2.24` and `pdfrx_engine 0.3.9` APIs from
  official package source archives rather than copying newer or obsolete
  examples.
- Created `feature/pdfrx-pdf-reader` from the verified baseline.
- Added pinned `pdfrx 2.2.24` and made the required `archive ^4.0.7`
  compatibility update. Archive 4 renamed the one used decoder API from
  `decodeBuffer` to `decodeStream`; the existing backup restore call was
  updated accordingly.
- Added `PdfPlayer` using `PdfViewer.file` with progressive loading, bounded
  render caching defaults, Anx-themed loading/error states, continuous native
  page navigation, keyboard page movement, and tap access to the existing
  reader chrome.
- Routed only `.pdf` books to `PdfPlayer`; EPUB and all other existing formats
  still instantiate `EpubPlayer`. Foliate-only drawer/actions are hidden for
  PDF so they cannot dereference a missing WebView player.
- Added a portable `pdf-page:<one-based-page>` reading-position codec. PDF page
  changes update current-reading state and debounce persistence through
  `bookDao` plus `annotationSyncRuntime.recordReadingProgress`; reopening uses
  the stored page. An explicit navigation position follows the existing EPUB
  rule and does not overwrite durable reading progress.
- Explicitly enabled pdfrx's built-in scale and pan gestures and added minimal
  zoom-out/zoom-in reader-chrome controls that delegate to
  `PdfViewerController.zoomDown` / `zoomUp`. Zoom remains ephemeral
  presentation state and is not written to shared reading state.
- Added protocol-v2-compatible `pdf-page` and contextual `text-quote`
  selectors, pure unique quote restoration, PDF repository creation support,
  read-model capabilities, pdfrx single-page selection integration, and
  persistent highlight/underline painting from canonical annotations.

## Current state

Milestones 1 through 3 are implemented; Milestone 3 is ready to commit. Native
pdfrx gesture/rendering and selection-overlay validation on representative
files remains a manual device check because no Flutter device is attached in
this environment.

## Next exact step

Commit Milestone 3, then implement independent ordered PDF text-block
extraction with page-lazy loading and pure tests.

## Important decisions

- Use an implementation branch forked directly from the requested source
  branch so the shared-state architecture remains the baseline.
- Pin `pdfrx` to 2.2.24 because it is the newest release compatible with the
  repository's pinned Flutter/Dart SDK.
- Keep `ReadingPage` as shared reader-level infrastructure and split only the
  rendering/player child by file extension.
- Reuse `Book.lastReadPosition`, `Book.readingPercentage`, `bookDao`, and
  `annotationSyncRuntime.recordReadingProgress`; do not add PDF position
  storage.
- Keep protocol v2 frozen. Its arbitrary selector array can already carry
  `pdf-page` and `text-quote`, so only repository/read-model capabilities need
  a backward-compatible extension.
- Resolve annotations semantically from page plus exact/prefix/suffix. If that
  does not identify one occurrence, leave the canonical annotation unresolved
  and unrendered.
- Keep extraction page-lazy and translation block-lazy. Do not eagerly render,
  extract, or translate the full document.

## Known limitations / blockers

- Device-level validation needs representative local PDFs and a Flutter target;
  automated/pure coverage will be added in-repository, but physical gesture and
  rendering checks may remain a documented manual validation item if no device
  is attached.
- Scanned/image-only PDFs will remain readable in fixed layout but will report
  unavailable selectable text in reflow. OCR is intentionally out of scope.
- Password-protected PDF UX is not part of the requested MVP unless an existing
  Anx convention is discovered to require it.

## Validation performed

- `git fetch origin`; verified source HEAD equals remote at `749e7ce0`.
- Read repository Flutter version metadata: Flutter 3.35.3 / Dart 3.9.2.
- Queried official pub.dev metadata for `pdfrx 2.2.24` and inspected official
  `pdfrx`/`pdfrx_engine` 2.2.24/0.3.9 source archives in `/tmp`.
- Baseline source inspection completed before runtime implementation.
- Dependency resolution succeeded with `pdfrx 2.2.24`,
  `pdfrx_engine 0.3.9`, and `archive 4.2.0` selected by the lockfile.
- `flutter analyze`: no errors; 43 pre-existing informational lints remain.
- Focused tests: 17 passed across PDF position, reading-state/library protocol,
  and final annotation architecture suites.
- EPUB/Foliate regression subset: 5 passed across Foliate server asset MIME
  handling and canonical annotation renderer adaptation.
- Automated coverage validates small/multi-page position arithmetic and reopen
  serialization. Actual small/multi-page PDF rendering, scrolling, and reopen
  behavior still require an attached Flutter device and representative files;
  this environment has neither, so that limitation is explicitly carried
  forward rather than claimed as performed.
- Milestone 2 targeted analysis of `reading_page.dart` and `pdf_player.dart`:
  compiled with only two pre-existing async-context informational lints.
- Milestone 2 PDF position tests: 4 passed. Pinch, pan, zoom-button interaction,
  consecutive pages, and orientation rebuild remain manual device checks; the
  code uses pdfrx's supported native gesture/controller implementation without
  a custom transform layer.
- Milestone 3 selector/read-model/repository tests: 39 passed. Annotation editor
  session/controller/draft/widget regression tests: 37 passed. Targeted
  analysis compiles all changed production files with only the same two
  pre-existing async-context informational lints in `reading_page.dart`.
