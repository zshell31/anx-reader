# Chat layout and selection gesture fixes (2026-09-11)

Local ANX presentation/gesture changes; no canonical JSON, selectors, provider
semantics, Markdown, or RFC version changes.

- Editor chat children fill the available width so role labels and messages share
  a left edge. Personal Note, AI Chat, and additional-source sections use the same
  right/collapsed and down/expanded chevrons as context and provider cards.
- Paginator touch gestures latch selection ownership at start/move/release. A
  native range temporarily disappearing cannot turn that gesture into a swipe.
  Selection-owned moves and releases do not dispatch reader pull/bookmark actions,
  and release does not snap the page.
- Device verification exposed an existing browser timer receiver error in
  AutoPageSelectionCoordinator (`TypeError: Illegal invocation`). Default timer
  wrappers now call setTimeout/clearTimeout on globalThis. A regression exercises
  advance, recheck and cancellation with browser-style receiver requirements.
  The separate selectionchange-driven coordinator advances forward at the page end. Backward automatic selection navigation
  is not implemented by that coordinator; this patch does not add it.
- Continuous native handle dragging exposed partial-column scrolling after the
  page advance. Paginator now holds the last explicit paginated offset while
  selecting, allowing its own programmatic navigation to update the offset.
  Removed book.js per-selection scroll listeners and global originalScrollLeft;
  those were sensitive to DOM start/end-node identity and handle pointerup delivery.
- The reported intermittent left-handle failure near the top of a page has not
  been reproduced. The release-to-snap conflict is a code finding, not proof of
  the original failure's sole cause. No italic-specific cause was established.

## Compatibility inspection

Read Notes RFC README, AGENTS, and editor/STUDY_NOTE_EDITOR.md. Inspected all four
applications and their repository instructions:

- ANX: Flutter annotation editor and Foliate paginator/selection handlers changed.
- Lingua Reader: src/annotation-ui.ts and annotation types/adapters use independent
  UI and canonical storage; unaffected by Flutter sizing and Android touch logic.
- Screen Translator: gnome-extension/study-editor.js uses native GNOME layout and
  gestures; unaffected.
- English Coach: src/integrations/canonical/decoder.ts consumes canonical JSON;
  no input or learning semantics changed, so unaffected.

No coordinated edits or protocol fixture changes are required for these local
implementation fixes. Automated checks and device verification are reported
separately; automated checks cannot establish native selection-handle behavior.

## Verification results

- Foliate: 89 tests passed, including browser timer receiver and native scroll
  ownership regressions. Webpack production bundle rebuilt (existing async/await
  target warnings remain).
- Flutter editor: 24 widget tests passed, including common message left edge,
  right/down arrows, collapse defaults and pending chat behavior.
- ARM64 release APK built with symbols in /tmp/anx-chat-selection-symbols;
  installed with adb install -r on A3DE65C3. Release data was retained.
- Device: existing barking-her-head-off chat inspected expanded/collapsed;
  roles/messages align left and arrows have the requested directions.
  Screenshot: /tmp/anx-chat-fixed.png.
- Device: long-pressed suddenly at the end of visual page 3, dragged the native
  end handle to the bottom, held through the automatic advance, moved it to the
  first line of page 4 and released. The page remained aligned and its handle
  stayed visible. CDP confirmed the range retained the English starting text on
  page 3 plus the selected text on page 4 (bilingual mode).
  Screenshot: /tmp/anx-selection-next-page.png.
- Device: selected italic never on page 6, moved the left handle to I'm, then
  extended the right handle to the end of I'm never going to know her story.
  The page stayed in place. Screenshot: /tmp/anx-never-selection-fixed.png.
- Ordinary forward/back swipes after clearing selection also worked on device.
  Backward automatic selection navigation and cross-spine-document selection
  remain outside this implementation; forward visual-page continuation within
  the same chapter Document is the verified scenario.
