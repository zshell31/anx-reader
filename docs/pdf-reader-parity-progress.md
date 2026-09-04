# PDF reader parity progress

Branch: `feature/pdf-reader-parity`

Goal: bring PDF reading interactions closer to the EPUB reader while keeping
PDF-native coordinates, text permissions, and annotation selectors intact.

## Work items

- [x] Use the shared reader selection action menu for PDF text.
- [x] Load and expose the embedded PDF outline in the contents drawer.
- [x] Navigate to a PDF destination when an outline item is tapped.
- [x] Re-fit the current PDF page after an orientation/viewport change.
- [x] Persist text annotations whose selection crosses PDF page boundaries,
  excluding page-number spans from the logical quote.
- [ ] Select the touched PDF word instead of the extractor's whole paragraph
  fragment on long press.
- [ ] Turn PDF pages by tapping the left or right edge.

## Progress log

- 2026-09-04: Created the feature branch and recorded the implementation plan.
- 2026-09-04: Made `ExcerptMenu` format-neutral and connected PDF selections
  to the same annotation, AI, dictionary, translation, copy, search, and share
  actions used by EPUB. PDF TTS stays hidden because it has no continuation
  implementation yet. Targeted editor/selection/PDF tests and analyzer pass.
- 2026-09-04: Added the tested PDF outline-to-TOC adapter and load the embedded
  outline when `pdfrx` opens a document. Drawer wiring/navigation is the next
  commit; the outline foundation is intentionally committed separately.
- 2026-09-04: Enabled the contents drawer for PDF, generalized `BookToc` around
  navigation callbacks, and route outline taps through `PdfViewerController`
  `goToDest` (or the matching reflow page). Analyzer passes; outline and reading
  position tests pass (6/6).
- 2026-09-04: Re-fit the current native PDF page to the new viewport width after
  rotation or another material width change. Stale post-frame refits are
  generation-guarded. Added a focused viewport decision test.
- 2026-09-04: Enabled cross-page PDF selections in the shared action menu and
  persistence layer. The standard start-page/text-quote selectors remain, while
  `anx-pdf-page-range` stores page-local quotes so every fragment can be restored
  and painted. Centered edge page-number fragments are excluded using the same
  conservative rule as Lingua Reader. Analyzer passes; selection, selector,
  rendering, and canonical protocol tests pass (22/22).

## Notes and constraints

- `pdfrx` 2.2.24 already models a text selection as two points that may belong
  to different pages. The current app rejects such selections in
  `PdfPlayer._openSelectionEditor`; the viewer itself is not the limiting part.
- Lingua Reader's equivalent PDF fix is in `src/pdf-selection.ts`. It filters a
  span only when its trimmed text equals the page number and it is centered near
  a page edge; Anx Reader should preserve that conservative behavior instead of
  deleting arbitrary numbers from selected prose.
- PDF outline entries use native PDF destinations, not EPUB hrefs. The drawer
  must therefore dispatch navigation through a format-neutral callback.
- The progress file is updated in every substage commit so work can resume from
  the last commit after context compaction.
