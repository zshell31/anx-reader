# Known bugs

This document tracks reproducible or log-confirmed defects which still require
investigation. Entries remain here until a fix is implemented and validated.

## BUG-001: WebView `createTreeWalker` receives a non-Node root

- Status: open
- First observed: 2026-09-04
- Environment: Samsung SM-M315F, Android 12, Anx Reader 1.15.0 (6324)
- Area: EPUB/Foliate WebView paging
- Sync impact: none observed

### Symptom

While paging through `Dungeon Crawler Carl`, the WebView emitted:

```text
Uncaught TypeError: Failed to execute 'createTreeWalker' on 'Document':
parameter 1 is not of type 'Node'.
```

The exported device log records the error at `2026-09-04 11:35:15.406386`.
Its Dart stack only shows the WebView console-message bridge, so the originating
JavaScript file and call site are not yet known.

### Observed behavior

- The reader remained open and subsequently closed normally.
- Reading-state revision 268 converged after the error.
- Reading-state revision 269 and a new 26-second reading-activity event were
  persisted when the reader closed.
- The following full sync completed with `pending=0` and `failed=0`.

### Reproduction context

1. Open an EPUB that already has substantial reading progress.
2. Page through it several times on Samsung SM-M315F.
3. Observe WebView console output around page rendering or navigation.

The event has only been captured once, so reproducibility is not yet
established.

### Investigation notes

- Add JavaScript source URL, line, and column to WebView console diagnostics if
  the current bridge exposes them.
- Search Foliate page-navigation, selection, annotation, and translation code
  for `document.createTreeWalker(...)` calls whose root can become null or a
  non-DOM value during page replacement.
- Reproduce independently of WebDAV before changing sync code.
- Validate any fix on Samsung and Onyx while rapidly paging and changing
  chapters.
