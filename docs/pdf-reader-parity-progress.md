# PDF reader parity progress

Branch: `feature/pdf-reader-parity`

Goal: bring PDF reading interactions closer to the EPUB reader while keeping
PDF-native coordinates, text permissions, and annotation selectors intact.

## Work items

- [ ] Use the shared reader selection action menu for PDF text.
- [ ] Load and expose the embedded PDF outline in the contents drawer.
- [ ] Navigate to a PDF destination when an outline item is tapped.
- [ ] Re-fit the current PDF page after an orientation/viewport change.
- [ ] Persist text annotations whose selection crosses PDF page boundaries,
  excluding page-number spans from the logical quote.
- [ ] Turn PDF pages by tapping the left or right edge.

## Progress log

- 2026-09-04: Created the feature branch and recorded the implementation plan.

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
