# Selection interaction parity

Branch: `fix/unified-selection-interactions`

## Plan

1. Render PDF selections and annotations as continuous line rectangles.
2. Preserve selected text on tap, dismiss on outside tap, and reopen saved
   annotations through the shared EPUB/PDF action menu and persistence session.
3. Verify PDF behavior and existing EPUB selection regressions.

## Progress

- 2026-09-05: Created branch from clean `develop`. Confirmed PDF's default
  single-tap handler clears selected text, while saved annotation taps bypass
  the shared action menu. No shared annotation protocol changes are planned.
- 2026-09-05: Added continuous PDF line geometry for native selection painting,
  annotation painting and annotation hit testing. Covers differing glyph heights,
  line breaks, column gaps and RTL order. Geometry/selection tests: 6 passed.
